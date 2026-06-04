#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Removes the existing NinjaRMM agent and installs the new MSP's NinjaRMM agent.

.DESCRIPTION
    Designed for MSP-to-MSP customer fleet transfers. Fully removes the incumbent
    NinjaOne agent and all associated components (services, Ninja Remote, registry
    entries, drivers), then silently installs the new MSP's NinjaOne agent from
    the provided MSI installer URL.

    Installer URL precedence (highest to lowest):
      1. Ninja script variable "installerUrl"  ($env:installerUrl)
      2. -InstallerURL parameter
      3. $NewMSPInstallerURL hardcoded in this script

.PARAMETER InstallerURL
    Full HTTPS URL to the new MSP's NinjaOne MSI installer for the target organization.
    Obtain from: New MSP NinjaOne > Administration > Installer > Windows Agent > Generate Installer.
    Select the correct customer organization before generating.

.EXAMPLE
    .\Reinstall NinjaRMM Agent.ps1

    Runs using the URL set in $NewMSPInstallerURL or the Ninja script variable.

.EXAMPLE
    .\Reinstall NinjaRMM Agent.ps1 -InstallerURL 'https://app.ninjarmm.com/agent/installer/...'

.NOTES
    --- OPTION 1: Direct execution (simplest for a single transfer) ---
    Fill in $NewMSPInstallerURL below with the MSI URL and deploy the script as-is.
    The partner MSP can run it directly or add it to their NinjaOne without any
    additional configuration.

    --- OPTION 2: Ninja Script Variable (flexible, reusable across orgs) ---
    1. Add this script in the partner NinjaOne: Scripting > Scripts > Add Script.
    2. In the script editor, add a Script Variable:
         - Type:  String
         - Name:  installerUrl
         - Label: NinjaRMM Installer URL
    3. When running or scheduling the script, paste the MSI URL into the variable field.

    The installer URL is available from:
      New MSP NinjaOne > Administration > Installer > Windows Agent > Generate Installer
    Be sure to select the correct customer organization before generating the URL.

    --- CANCELING THE INSTALL TASK ---
    The script registers a Scheduled Task named 'NinjaRMM-NewAgentInstall' that fires
    5 minutes after the script runs. The task removes itself after completing.
    If you need to cancel the installation before the task fires, run:
      Unregister-ScheduledTask -TaskName 'NinjaRMM-NewAgentInstall' -Confirm:$false
    Or open Task Scheduler and delete the task from the Task Scheduler Library.
#>

param (
    [string]$InstallerURL
)

# ==============================================================================
# CONFIGURATION - Paste the new MSP's NinjaOne agent installer URL here.
# See .NOTES above for how to obtain the URL and Ninja script variable setup.
# ==============================================================================
$NewMSPInstallerURL = ''
# ==============================================================================

$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

# --- Ninja script variable override (highest precedence) ---
if ($env:installerUrl) { $InstallerURL = $env:installerUrl }

# --- Fall back to hardcoded URL if no parameter or env var was supplied ---
if (-not $InstallerURL -and $NewMSPInstallerURL) { $InstallerURL = $NewMSPInstallerURL }

if (-not $InstallerURL) {
    Write-Error 'No installer URL provided. Set $NewMSPInstallerURL in the script, pass -InstallerURL, or configure the "installerUrl" Ninja script variable.'
    exit 1
}

# Writes a timestamped, leveled log line to stdout. NinjaOne captures stdout as the
# script activity log, so everything written here is visible in the device timeline.
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$timestamp] [$Level] $Message"
}

# Runs the NinjaRMM MSI uninstaller silently, following Ninja's documented method for
# handling Uninstall Prevention (ref: NinjaOne KB - Windows Agent Manual Removal).
#
# Ninja's documented steps when Uninstall Prevention is active:
#   1. Ensure the NinjaRMMAgent service is running.
#   2. Run: NinjaRMMAgent.exe -disableUninstallPrevention
#   3. Run: uninstall.exe --mode unattended
#
# This function performs all three steps. For step 3, we invoke msiexec /x instead of
# uninstall.exe directly. The NinjaOne MSI is wrapped by EXEMSI, and WRAPPED_ARGUMENTS
# passes "--mode unattended" through the wrapper to the inner uninstaller - functionally
# equivalent to calling uninstall.exe --mode unattended.
#
# Calling -disableUninstallPrevention is safe regardless of whether Uninstall Prevention
# is actually enabled on the device - it is a no-op if prevention was never activated.
# NOUI suppresses any dialog the agent might otherwise show during the flag removal.
# The 10-second sleep gives the agent time to fully release its protection lock before
# msiexec attempts to remove the package.
# The 30-second sleep after msiexec allows background agent processes to fully terminate
# before we attempt file and registry cleanup.
function Uninstall-NinjaMSI {
    $Arguments = @(
        "/x$UninstallString"
        '/quiet'
        '/L*V'
        'C:\Windows\Temp\NinjaRMMAgent_uninstall.log'
        "WRAPPED_ARGUMENTS=`"--mode unattended`""
    )
    # Step 1: Ensure the NinjaRMMAgent service is running before lifting uninstall prevention.
    # The service must be active for -disableUninstallPrevention to communicate with the agent.
    $svc = Get-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Log 'Starting NinjaRMMAgent service before disabling uninstall prevention...'
        Start-Service 'NinjaRMMAgent' -ErrorAction SilentlyContinue
        Start-Sleep 5
    }
    # Step 2: Lift uninstall prevention so msiexec is allowed to remove the package.
    Start-Process "$NinjaInstallLocation\NinjaRMMAgent.exe" -ArgumentList '-disableUninstallPrevention NOUI' -ErrorAction SilentlyContinue
    Start-Sleep 10
    # Step 3: Run the MSI uninstaller in silent/unattended mode.
    Start-Process 'msiexec.exe' -ArgumentList $Arguments -Wait -NoNewWindow
    Write-Log 'Finished running uninstaller. Continuing cleanup...'
    Start-Sleep 30
}

# Registers a one-time Scheduled Task to install the new agent under SYSTEM.
# The task is the sole install path - it runs outside this script's process tree,
# so it survives even if the MSI uninstaller terminates this process. (NinjaOne's
# scripting engine runs inside the Ninja process tree; the entire tree is torn down
# when the agent is removed.) The task removes itself after running.
function Register-InstallTask {
    param ([string]$URL)
    $TaskName      = 'NinjaRMM-NewAgentInstall'
    $InstallerPath = "$env:windir\Temp\NinjaAgentInstall.msi"
    # The task runs PowerShell to download the MSI first, then installs from a local path.
    # msiexec as SYSTEM cannot reliably fetch URLs directly - the SYSTEM account uses
    # WinHTTP, which does not inherit user-context proxy or authentication settings.
    # .NET's WebClient resolves this correctly.
    $Script = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$f = '$InstallerPath'
(New-Object Net.WebClient).DownloadFile('$URL', `$f)
Start-Process msiexec.exe -ArgumentList @('/i', `$f, '/quiet', '/norestart') -Wait -NoNewWindow
Remove-Item `$f -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false -ErrorAction SilentlyContinue
"@
    $Encoded   = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
    $Action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -NonInteractive -EncodedCommand $Encoded"
    $Trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $Settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force -ErrorAction Stop | Out-Null
    Write-Log "Install task registered - the new agent will be installed at approximately $((Get-Date).AddMinutes(5).ToString('HH:mm:ss')).  To cancel, run: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
}

# Removes Ninja Remote (ncstreamer) registry entries from a specific user profile hive.
# Ninja Remote writes autostart entries to the user's Run key and stores settings under
# "NinjaRMM LLC". This must be cleaned from every user profile - both currently loaded
# ones (mounted hives) and profiles that are not currently logged in (unmounted hives).
# Called once per profile; the caller is responsible for loading/unloading unmounted hives.
function Remove-NRRegistryItems {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SID
    )
    $NRRunReg      = "Registry::\HKEY_USERS\$SID\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    $NRRegLocation = "Registry::\HKEY_USERS\$SID\Software\NinjaRMM LLC"
    if (Test-Path $NRRunReg) {
        $RunRegValues  = Get-ItemProperty -Path $NRRunReg -ErrorAction SilentlyContinue
        $PropertyNames = $RunRegValues.PSObject.Properties | Where-Object { $_.Name -match 'NinjaRMM|NinjaOne' }
        foreach ($PName in $PropertyNames) {
            Write-Log "Removing Run entry: $($PName.Name): $($PName.Value)"
            Remove-ItemProperty $NRRunReg -Name $PName.Name -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path $NRRegLocation) {
        Write-Log "Removing: $NRRegLocation"
        Remove-Item $NRRegLocation -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Log 'Registry removal complete for profile.'
}

$Now     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogPath = "$env:windir\Temp\ReinstallNinjaRMM_$Now.log"
Start-Transcript -Path $LogPath -Force | Out-Null

try {
    # --- Locate existing installation ---
    # Ninja stores its registry data under WOW6432Node on 64-bit Windows (32-bit app registry view).
    # On 32-bit systems the WOW6432Node layer does not exist, so we use the native path.
    $NinjaRegPath     = 'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC\NinjaRMMAgent'
    $NinjaDataDir     = "$env:ProgramData\NinjaRMMAgent"
    $UninstallRegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'

    if (-not [System.Environment]::Is64BitOperatingSystem) {
        $NinjaRegPath     = 'HKLM:\SOFTWARE\NinjaRMM LLC\NinjaRMMAgent'
        $UninstallRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    }

    # Register the install task before touching the agent so it fires even if
    # the uninstaller kills this process.
    Register-InstallTask -URL $InstallerURL

    Write-Log 'Beginning NinjaRMM agent removal...'

    # Try to resolve the install directory from the Ninja registry key first.
    # The Location value may use forward slashes, so normalize to backslashes.
    # If the registry key is missing or the path is stale (e.g. partial uninstall),
    # fall back to reading the service binary path instead.
    $NinjaInstallLocation = $null
    $LocationRaw = Get-ItemPropertyValue $NinjaRegPath -Name Location -ErrorAction SilentlyContinue
    if ($LocationRaw) { $NinjaInstallLocation = $LocationRaw.Replace('/', '\') }

    if (-not (Test-Path "$NinjaInstallLocation\NinjaRMMAgent.exe")) {
        $NinjaSvc = Get-CimInstance Win32_Service -Filter "Name='NinjaRMMAgent'" -ErrorAction SilentlyContinue
        if ($NinjaSvc -and $NinjaSvc.PathName) {
            $NinjaInstallLocation = Split-Path $NinjaSvc.PathName.Trim('"')
        } else {
            Write-Log 'Unable to locate Ninja installation path. Continuing with cleanup...' -Level Warning
        }
    }

    # --- Run MSI uninstaller ---
    # Read the uninstall command from the standard Windows Uninstall registry hive.
    # The raw value looks like: MsiExec.exe /X{GUID} - we split on 'X' to extract just
    # the product GUID portion ({GUID}), which msiexec accepts with the /x flag.
    $UninstallString = (Get-ItemProperty $UninstallRegPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'NinjaRMMAgent' -and $_.UninstallString -match 'msiexec' }).UninstallString

    if (-not $UninstallString) {
        Write-Log 'Unable to determine uninstall string. Continuing with cleanup...' -Level Warning
    } else {
        $UninstallString = $UninstallString.Split('X')[1]
        Uninstall-NinjaMSI
    }

    # --- Stop processes and services ---
    # Kill any Ninja-related processes that may still be running after the MSI uninstall.
    # These can hold file or registry locks that prevent directory and key removal.
    $NinjaProcesses = @('NinjaRMMAgent', 'NinjaRMMAgentPatcher', 'njbar', 'NinjaRMMProxyProcess64')

    # 'lockhart' is the Ninja Backup service and is only present on some installations.
    # Skip it if its binary does not exist so we do not log spurious warnings.
    $NinjaServices  = @('NinjaRMMAgent', 'nmsmanager', 'lockhart')

    foreach ($Process in $NinjaProcesses) {
        Get-Process $Process -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Use sc.exe DELETE rather than Remove-Service (PS 6+) for broad OS compatibility.
    foreach ($NS in $NinjaServices) {
        if ($NS -eq 'lockhart' -and -not (Test-Path "$NinjaInstallLocation\lockhart\bin\lockhart.exe")) {
            continue
        }
        if (Get-Service $NS -ErrorAction SilentlyContinue) {
            & sc.exe DELETE $NS | Out-Null
            Start-Sleep 2
            if (Get-Service $NS -ErrorAction SilentlyContinue) {
                Write-Log "Failed to remove service: $NS. Continuing..." -Level Warning
            }
        }
    }

    # --- Remove installation directories ---
    if ($NinjaInstallLocation -and (Test-Path $NinjaInstallLocation)) {
        Remove-Item $NinjaInstallLocation -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $NinjaInstallLocation) {
            Write-Log "Failed to remove install directory: $NinjaInstallLocation" -Level Warning
        }
    }

    if (Test-Path $NinjaDataDir) {
        Remove-Item $NinjaDataDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $NinjaDataDir) {
            Write-Log "Failed to remove data directory: $NinjaDataDir" -Level Warning
        }
    }

    # --- Remove registry entries ---
    # Ninja leaves traces across several registry locations. We collect all matching keys
    # into a list first, then delete them in one pass.
    #
    # MSIWrapperReg       - EXEMSI wrapper entries created when the MSI was installed
    # ProductInstallerReg - Windows Installer product records stored under the SYSTEM SID
    # HKCRInstallerReg    - HKCR Installer\Products entries (Windows Installer product cache)
    # UninstallRegPath    - Standard Add/Remove Programs entries
    $MSIWrapperReg       = 'HKLM:\SOFTWARE\WOW6432Node\EXEMSI.COM\MSI Wrapper\Installed'
    $ProductInstallerReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    $HKCRInstallerReg    = 'Registry::\HKEY_CLASSES_ROOT\Installer\Products'

    $RegKeysToRemove = [System.Collections.Generic.List[object]]::new()

    # Add/Remove Programs entry
    (Get-ItemProperty $UninstallRegPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'NinjaRMMAgent' }).PSPath |
        ForEach-Object { $RegKeysToRemove.Add($_) }

    # Windows Installer product records (SYSTEM SID)
    (Get-ItemProperty $ProductInstallerReg -ErrorAction SilentlyContinue |
        Where-Object { $_.ProductName -eq 'NinjaRMMAgent' }).PSPath |
        ForEach-Object { $RegKeysToRemove.Add($_) }

    # EXEMSI wrapper registry entries
    (Get-ChildItem $MSIWrapperReg -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'NinjaRMMAgent' }).PSPath |
        ForEach-Object { $RegKeysToRemove.Add($_) }

    # HKCR Installer\Products cache (keyed by packed GUID, so we check the ProductName value)
    Get-ChildItem $HKCRInstallerReg -ErrorAction SilentlyContinue | ForEach-Object {
        if ((Get-ItemPropertyValue $_.PSPath -Name 'ProductName' -ErrorAction SilentlyContinue) -eq 'NinjaRMMAgent') {
            $RegKeysToRemove.Add($_.PSPath)
        }
    }

    # Some installs also write an InstallProperties subkey under the SYSTEM SID product tree.
    # Check each product key's InstallProperties to catch these.
    $ProductInstallerKeys = Get-ChildItem $ProductInstallerReg -ErrorAction SilentlyContinue | Select-Object *
    foreach ($Key in $ProductInstallerKeys) {
        $KeyName = $Key.Name.Replace('HKEY_LOCAL_MACHINE', 'HKLM:') + '\InstallProperties'
        if (Get-ItemProperty $KeyName -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'NinjaRMMAgent' }) {
            $RegKeysToRemove.Add($Key.PSPath)
        }
    }

    Write-Log 'Removing registry entries...'
    foreach ($RegKey in $RegKeysToRemove) {
        if (-not [string]::IsNullOrEmpty($RegKey)) {
            Write-Log "Removing: $RegKey"
            Remove-Item $RegKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $NinjaRegPath) {
        Remove-Item (Split-Path $NinjaRegPath) -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removing: $NinjaRegPath"
    }

    foreach ($RegKey in $RegKeysToRemove) {
        if (-not [string]::IsNullOrEmpty($RegKey) -and (Test-Path $RegKey)) {
            Write-Log "Failed to remove registry key: $RegKey" -Level Warning
        }
    }

    if (Test-Path $NinjaRegPath) {
        Write-Log "Failed to remove registry key: $NinjaRegPath" -Level Warning
    }

    # --- Check for orphaned installer keys ---
    # A valid Windows Installer product key always has a ProductName value.
    # Keys missing ProductName can indicate a corrupt or partial Ninja installation
    # that the MSI uninstaller may not have cleaned up. We flag them for manual review
    # rather than deleting blindly, since other products could theoretically have the
    # same issue and we do not want to damage unrelated software.
    # The hardcoded GUID (99E80CA9...) is a known Windows common component that
    # legitimately has no ProductName and must be excluded to avoid a false positive.
    # This check is purely informational - failures here must not abort the install.
    try {
        $Child      = Get-ChildItem 'HKLM:\Software\Classes\Installer\Products' -ErrorAction SilentlyContinue
        $MissingPNs = [System.Collections.Generic.List[object]]::new()

        foreach ($C in $Child) {
            if ($C.PSChildName -match '99E80CA9B0328e74791254777B1F42AE') { continue }
            $ProductName = Get-ItemPropertyValue $C.PSPath -Name 'ProductName' -ErrorAction SilentlyContinue
            if ($null -eq $ProductName) {
                $MissingPNs.Add($C.PSChildName)
            }
        }

        if ($MissingPNs) {
            Write-Log 'Some installer registry keys are missing a ProductName - possible corrupt Ninja install entry.' -Level Warning
            Write-Log 'Back up and manually review these keys if the agent install fails:' -Level Warning
            $MissingPNs | ForEach-Object { Write-Log "  $_" -Level Warning }
        }
    } catch {
        Write-Log "Orphaned key check failed (non-fatal): $($_.Exception.Message)" -Level Warning
    }

    # --- Remove Ninja Remote ---
    Write-Log 'Beginning Ninja Remote removal...'
    $NR = 'ncstreamer'

    if (Get-Process $NR -ErrorAction SilentlyContinue) {
        Write-Log 'Stopping Ninja Remote process...'
        try {
            Get-Process $NR | Stop-Process -Force
        } catch {
            Write-Log "Unable to stop Ninja Remote process: $($_.Exception.Message)" -Level Warning
        }
    }

    if (Get-Service $NR -ErrorAction SilentlyContinue) {
        try {
            Stop-Service $NR -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Unable to stop Ninja Remote service: $($_.Exception.Message)" -Level Warning
        }
        & sc.exe DELETE $NR | Out-Null
        Start-Sleep 5
        if (Get-Service $NR -ErrorAction SilentlyContinue) {
            Write-Log 'Failed to remove Ninja Remote service. Continuing...' -Level Warning
        }
    }

    # Ninja Remote installs a virtual display driver (nrvirtualdisplay.inf) used for
    # screen sharing. pnputil does not expose a simple name-based removal command,
    # so we parse its output into objects to find the driver's Published Name (the
    # oemNN.inf filename Windows assigns when a driver is staged into the driver store).
    # We then delete it by that Published Name, which is what pnputil /delete-driver requires.
    $NRDriver    = 'nrvirtualdisplay.inf'
    $DriverCheck = pnputil /enum-drivers | Where-Object { $_ -match $NRDriver }
    if ($DriverCheck) {
        Write-Log 'Ninja Remote virtual display driver found. Removing...'
        $DriverBreakdown = pnputil /enum-drivers | Where-Object { $_ -ne 'Microsoft PnP Utility' }
        $DriversArray    = [System.Collections.Generic.List[object]]::new()
        $CurrentDriver   = @{}
        foreach ($Line in $DriverBreakdown) {
            if ($Line -ne '') {
                $CurrentDriver[$Line.Split(':').Trim()[0]] = $Line.Split(':').Trim()[1]
            } else {
                if ($CurrentDriver.Count -gt 0) {
                    $DriversArray.Add([PSCustomObject]$CurrentDriver)
                    $CurrentDriver = @{}
                }
            }
        }
        $DriverToRemove = ($DriversArray | Where-Object { $_.'Provider Name' -eq 'NinjaOne' }).'Published Name'
        pnputil /delete-driver "$DriverToRemove" /force | Out-Null
    }

    $NRDirectory = "$env:ProgramFiles\NinjaRemote"
    if (Test-Path $NRDirectory) {
        Write-Log "Removing Ninja Remote directory: $NRDirectory"
        Remove-Item $NRDirectory -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $NRDirectory) {
            Write-Log "Failed to remove Ninja Remote directory: $NRDirectory" -Level Warning
        }
    }

    # S-1-5-18 is the SYSTEM account SID. Ninja Remote can leave a registry key there
    # in addition to the per-user keys below.
    $NRHKUReg = 'Registry::\HKEY_USERS\S-1-5-18\Software\NinjaRMM LLC'
    if (Test-Path $NRHKUReg) {
        Remove-Item $NRHKUReg -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Enumerate all real user profiles (S-1-5-21-* excludes built-in accounts like SYSTEM).
    # Profiles that are currently logged in have their hive already loaded in HKU.
    # Profiles that are not logged in need their NTUSER.DAT loaded temporarily.
    $AllProfiles = Get-CimInstance Win32_UserProfile |
        Select-Object LocalPath, SID, Loaded, Special |
        Where-Object { $_.SID -like 'S-1-5-21-*' }
    $Mounted   = $AllProfiles | Where-Object { $_.Loaded -eq $true }
    $Unmounted = $AllProfiles | Where-Object { $_.Loaded -eq $false }

    $Mounted | ForEach-Object {
        Write-Log "Removing Ninja Remote registry items for: $($_.LocalPath)"
        Remove-NRRegistryItems -SID $_.SID
    }

    $Unmounted | ForEach-Object {
        $Hive = "$($_.LocalPath)\NTUSER.DAT"
        if (Test-Path $Hive) {
            Write-Log "Loading hive for: $($_.LocalPath)"
            REG LOAD "HKU\$($_.SID)" $Hive 2>&1 | Out-Null
            Remove-NRRegistryItems -SID $_.SID
            # Force .NET garbage collection before unloading the hive.
            # PowerShell may hold COM/registry handles that prevent REG UNLOAD from
            # succeeding until all managed objects referencing the hive are released.
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            REG UNLOAD "HKU\$($_.SID)" 2>&1 | Out-Null
        }
    }

    $NRPrinter = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'NinjaRemote' }
    if ($NRPrinter) {
        Write-Log 'Removing Ninja Remote printer...'
        Remove-Printer -InputObject $NRPrinter -ErrorAction SilentlyContinue
    }

    $NRPrintDriverPath = "$env:SystemDrive\Users\Public\Documents\NrSpool\NrPdfPrint"
    if (Test-Path $NRPrintDriverPath) {
        Write-Log 'Removing Ninja Remote print driver spool...'
        Remove-Item $NRPrintDriverPath -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Ninja Remote removal complete.'
    Write-Log 'NinjaRMM agent removal complete. The install task will fire shortly - check the Ninja device timeline once the new agent checks in.' -Level Success
    Stop-Transcript | Out-Null
    exit 0
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level Error
    Stop-Transcript | Out-Null
    exit 1
}


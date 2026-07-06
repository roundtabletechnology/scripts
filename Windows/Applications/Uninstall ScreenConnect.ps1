#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Silently removes all installed ScreenConnect (ConnectWise Control) Client instances from a Windows machine.

.DESCRIPTION
    ScreenConnect Client installs are uniquely identified by a "thumbprint" in their display name, e.g.
    "ScreenConnect Client (8f53c95c9d2e1234)". A machine can have more than one instance installed at once
    (for example, one legitimate MSP instance and one dropped by an attacker via phishing/social engineering),
    each with its own service, process, and MSI product code.

    For every instance found in the Windows Uninstall registry, this script:
      1. Stops the matching Windows service(s) and sets their startup type to Disabled, so a pending start
         request or delayed auto-start cannot relaunch the client mid-cleanup.
      2. Kills any running ScreenConnect processes so the uninstaller and cleanup are not blocked by files
         or registry keys still held open.
      3. Reads the instance's MSI product code from its UninstallString and runs msiexec silently
         (/qn /norestart) - no dialogs and no reboot, so end users actively on the machine are not interrupted.
      4. Cleans up any service, install directory, or registry entry the MSI uninstaller leaves behind.

    Safe to run on a machine with zero, one, or several ScreenConnect Client instances - it is a no-op
    (exit 0) if none are found, and processes every matching instance it does find in a single run.

.PARAMETER NameFilter
    Wildcard used to match ScreenConnect Client display names, services, and processes.
    Defaults to 'ScreenConnect*', which matches every ScreenConnect Client instance on the machine.
    Narrow it to a specific instance (e.g. 'ScreenConnect Client (8f53c95c9d2e1234)') to remove only
    that one and leave other instances in place.

.EXAMPLE
    .\Uninstall ScreenConnect.ps1

    Removes every ScreenConnect Client instance found on the machine.

.EXAMPLE
    .\Uninstall ScreenConnect.ps1 -NameFilter 'ScreenConnect Client (8f53c95c9d2e1234)'

    Removes only the specified instance, leaving any other ScreenConnect Client installs untouched.

.NOTES
    Does not reboot and does not schedule a restart - safe to run while end users are actively working.
    Deploy via NinjaRMM as a scheduled/on-demand script run as SYSTEM.
#>

param (
    [string]$NameFilter = 'ScreenConnect*'
)

$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

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

# Stops and disables every service matching $Filter, then kills any still-running
# ScreenConnect processes. Run before touching the MSI and again after, since the
# uninstaller/registry cleanup will fail to fully release files and keys that a
# live process still has open.
function Stop-ScreenConnect {
    param ([string]$Filter)

    Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Filter -or $_.DisplayName -like $Filter } | ForEach-Object {
        if ($_.Status -ne 'Stopped') {
            Write-Log "Stopping service: $($_.Name)"
            Stop-Service -InputObject $_ -Force -ErrorAction SilentlyContinue
        }
        try {
            Set-Service -InputObject $_ -StartupType Disabled -ErrorAction Stop
        } catch {
            Write-Log "Could not set startup type to Disabled for service '$($_.Name)': $($_.Exception.Message)" -Level Warning
        }
    }

    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like $Filter } | ForEach-Object {
        Write-Log "Stopping process: $($_.ProcessName) (PID $($_.Id))"
        Stop-Process -InputObject $_ -Force -ErrorAction SilentlyContinue
    }
}

# Runs the MSI uninstaller for one ScreenConnect Client instance silently, with no
# reboot. Returns the msiexec exit code (0 or 3010 both indicate success - 3010 means
# a reboot would finish cleanup but /norestart suppresses it from actually happening).
function Uninstall-ScreenConnectInstance {
    param (
        [Parameter(Mandatory = $true)] [string]$DisplayName,
        [Parameter(Mandatory = $true)] [string]$ProductCode
    )
    $LogFile   = "$env:windir\Temp\ScreenConnectUninstall_$($ProductCode.Trim('{}'))_$Now.log"
    $Arguments = @('/x', $ProductCode, '/qn', '/norestart', '/L*V', $LogFile)

    Write-Log "Uninstalling '$DisplayName' ($ProductCode)..."
    $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
    Write-Log "msiexec exited with code $($Process.ExitCode) for '$DisplayName'. Log: $LogFile"
    return $Process.ExitCode
}

# Finds every ScreenConnect Client entry in the Uninstall registry matching $Filter.
# Checked both under the native 64-bit view and WOW6432Node, since the ScreenConnect
# Client MSI is a 32-bit package and registers under WOW6432Node on 64-bit Windows.
function Get-ScreenConnectInstances {
    param ([string]$Filter)

    $UninstallPaths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    if ([System.Environment]::Is64BitOperatingSystem) {
        $UninstallPaths += 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    }

    Get-ItemProperty -Path $UninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $Filter -and $_.UninstallString -match 'msiexec' }
}

$Now     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogPath = "$env:windir\Temp\UninstallScreenConnect_$Now.log"
Start-Transcript -Path $LogPath -Force | Out-Null

try {
    Write-Log "Searching for ScreenConnect Client installs matching '$NameFilter'..."
    $Instances = @(Get-ScreenConnectInstances -Filter $NameFilter)

    if ($Instances.Count -eq 0) {
        Write-Log 'No matching ScreenConnect Client installs found. Nothing to do.' -Level Success
        Stop-Transcript | Out-Null
        exit 0
    }

    Write-Log "Found $($Instances.Count) matching instance(s):"
    $Instances | ForEach-Object { Write-Log "  $($_.DisplayName)" }

    # Stop services and kill processes for every matching instance up front, before
    # any uninstaller runs, so file/registry locks cannot interfere with removal.
    Stop-ScreenConnect -Filter $NameFilter

    foreach ($Instance in $Instances) {
        if ($Instance.UninstallString -notmatch '(\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\})') {
            Write-Log "Could not extract an MSI product code from UninstallString for '$($Instance.DisplayName)': $($Instance.UninstallString)" -Level Warning
            continue
        }
        $ProductCode = $Matches[1]
        # Uninstall-ScreenConnectInstance's Write-Log calls also land on the pipeline, so the raw
        # call returns [logline, logline, exitcode] - filter to the one [int] to get the real code.
        $ExitCode = (Uninstall-ScreenConnectInstance -DisplayName $Instance.DisplayName -ProductCode $ProductCode) |
            Where-Object { $_ -is [int] }
        if ($ExitCode -ne 0 -and $ExitCode -ne 3010) {
            Write-Log "Uninstall of '$($Instance.DisplayName)' returned a non-success exit code ($ExitCode). Continuing with cleanup..." -Level Warning
        }
    }

    # Kill anything the uninstaller may have relaunched or left behind before cleanup.
    Stop-ScreenConnect -Filter $NameFilter
    Start-Sleep -Seconds 5

    # --- Leftover cleanup ---
    # The MSI uninstaller does not always fully clean up its own service registration,
    # install directory, or registry entries - especially if a file handle was briefly
    # held open. Sweep for anything still matching $NameFilter and remove it directly.
    Write-Log 'Sweeping for leftover services, folders, and registry entries...'

    Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $NameFilter } | ForEach-Object {
        Write-Log "Removing leftover service: $($_.Name)" -Level Warning
        & sc.exe DELETE $_.Name | Out-Null
    }

    # Filter is "ScreenConnect Client*" (not $NameFilter) so a broad default run never touches an
    # on-prem ScreenConnect Server's install folder (named "ScreenConnect", no "Client" suffix) - then
    # narrowed further by $NameFilter so a caller-scoped single-instance run does not delete sibling
    # instances' folders.
    foreach ($Root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if (-not $Root) { continue }
        Get-ChildItem -Path $Root -Directory -Filter 'ScreenConnect Client*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $NameFilter } |
            ForEach-Object {
                Write-Log "Removing leftover install directory: $($_.FullName)" -Level Warning
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
    }

    $Remaining = @(Get-ScreenConnectInstances -Filter $NameFilter)
    foreach ($Leftover in $Remaining) {
        Write-Log "Removing leftover registry entry: $($Leftover.PSPath)" -Level Warning
        Remove-Item -Path $Leftover.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Final verification ---
    $StillInstalled = @(Get-ScreenConnectInstances -Filter $NameFilter)
    $StillRunning   = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $NameFilter -or $_.DisplayName -like $NameFilter })

    if ($StillInstalled.Count -eq 0 -and $StillRunning.Count -eq 0) {
        Write-Log 'All matching ScreenConnect Client instances were removed successfully.' -Level Success
        Stop-Transcript | Out-Null
        exit 0
    } else {
        $StillInstalled | ForEach-Object { Write-Log "Still present in Uninstall registry: $($_.DisplayName)" -Level Error }
        $StillRunning   | ForEach-Object { Write-Log "Still present as a service: $($_.Name)" -Level Error }
        Write-Log 'One or more ScreenConnect Client instances could not be fully removed. Manual review required.' -Level Error
        Stop-Transcript | Out-Null
        exit 1
    }
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level Error
    Stop-Transcript | Out-Null
    exit 1
}

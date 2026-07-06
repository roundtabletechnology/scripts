<#
.SYNOPSIS
    Installs WireGuard VPN client on a Windows endpoint and configures it for
    limited non-admin use.

.DESCRIPTION
    Installs WireGuard via winget (WireGuard.WireGuard). If winget is unavailable or
    fails, falls back to downloading and silently installing the latest architecture-
    appropriate MSI from https://download.wireguard.com/windows-client/.

    After installation, the script:
    - Sets HKLM\Software\WireGuard\LimitedOperatorUI = 1, which causes WireGuard to
      display its tray UI to members of the "Network Configuration Operators" group.
      Those users can start and stop tunnels but cannot view private/public/preshared
      keys, add, edit, remove, import, or export configurations, or quit the manager.
    - Adds a specific user (or the "Authenticated Users" group if left blank) to the
      "Network Configuration Operators" group, granting access to manage WireGuard tunnels.
    - Optionally reads a WireGuard tunnel config from a NinjaOne organization custom
      field, writes it securely using the file-drop method, and registers it.

    WARNING: Installation and tunnel registration install a kernel-level network
    driver and briefly reset the network stack. Expect a short interruption to
    network connectivity (typically a few seconds). Schedule this deployment
    outside business hours or during a maintenance window when possible.

.PARAMETER WireGuardConfig
    Full contents of a WireGuard tunnel config file (INI/conf format). When provided,
    the config is saved and registered as the 'wg0' tunnel. The script automatically
    reads this from the 'wireguardConfig' NinjaOne organization custom field via
    Ninja-Property-Get (no script-variable mapping needed). If the parameter is passed
    directly or the env var is set, those take precedence.

.PARAMETER TargetUser
    The username of a specific user to grant access to start/stop the WireGuard tunnel
    (e.g., 'JohnDoe', 'DOMAIN\JohnDoe', or 'AzureAD\user@domain.com'). If left blank,
    the script falls back to granting access to all users (by adding the 'Authenticated
    Users' group to 'Network Configuration Operators'). Can also be set via the
    'targetUser' Ninja environment variable.

.EXAMPLE
    .\Install WireGuard.ps1

.EXAMPLE
    $env:wireguardConfig = (Get-Content .\office.conf -Raw)
    .\Install WireGuard.ps1

.NOTES
    Deployed via NinjaOne RMM. Runs at SYSTEM level with no interactive UI.
    Can also be run manually on a workstation for testing.

    WireGuard installs to:  C:\Program Files\WireGuard\
    Tunnel configs live in: C:\Program Files\WireGuard\Data\Configurations\

    NinjaOne setup for tunnel config deployment:
      1. Create a "Multi-line Text" organization custom field named "WireGuard Config"
         (field name: wireguardConfig). Paste the full .conf file content there.
         Enable inheritance so devices inherit the value from their organization.
      2. The script will automatically read the field via Ninja-Property-Get, so no
         script-variable mapping is required in the automation. If you do map it as a
         script variable ($env:wireguardConfig) that still works and takes precedence.
      3. Optionally map 'targetUser' as a script variable in the automation, set to
         the local username of the intended user (e.g. 'JohnDoe'). This is a runtime
         script variable (env var), not a custom field. If left blank, access is
         granted to all users on the machine.

    Without LimitedOperatorUI = 1 the WireGuard UI does not appear for non-admin
    users at all. Note: WireGuard's own documentation flags this key as an
    advanced/unsupported knob that may be removed in a future release.
#>

#Requires -RunAsAdministrator

param(
    [string]$WireGuardConfig = "",
    [string]$TargetUser = ""
)

$ProgressPreference = "SilentlyContinue"

# Ninja property helper: checks $env:<name> first (script-variable mapping),
# then falls back to Ninja-Property-Get (org/device custom fields via NinjaRMM CLI).
function Get-NinjaProperty {
    param([string]$Name)
    # 1. Prefer an explicit script-variable mapping if one was configured
    $envVal = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }
    # 2. Fall back to the NinjaRMM commandlet (reads org/device custom fields directly)
    try {
        # 2>$null suppresses the non-terminating error stream that Ninja-Property-Get
        # writes when a field doesn't exist; without it the error leaks to the caller
        # even though we have a try/catch for the terminating exception.
        $val = Ninja-Property-Get $Name -ErrorAction Stop 2>$null
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
    }
    catch {
        # Ninja-Property-Get is not available outside the NinjaRMM agent - ignore
    }
    return $null
}

$_wgConfig = Get-NinjaProperty "wireguardConfig"
if (-not [string]::IsNullOrWhiteSpace($_wgConfig)) { $WireGuardConfig = $_wgConfig }

# targetUser is a script variable mapped in the automation - read it as a plain env var.
# It is not an org/device custom field, so Ninja-Property-Get is not appropriate here.
if ($env:targetUser) { $TargetUser = $env:targetUser }

#region Functions

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$ts] [$Level] $Message"
}

function Test-WireGuardInstalled {
    return (Test-Path "C:\Program Files\WireGuard\wireguard.exe")
}

function Get-WingetPath {
    # winget lives inside a versioned WindowsApps folder. Check common patterns
    # for x64 and ARM64. Running as SYSTEM has full filesystem access here.
    $patterns = @(
        "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe",
        "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_arm64__8wekyb3d8bbwe\winget.exe"
    )
    foreach ($pattern in $patterns) {
        $match = Resolve-Path $pattern -ErrorAction SilentlyContinue |
        Sort-Object Path -Descending |
        Select-Object -First 1
        if ($match) { return $match.Path }
    }
    return $null
}

function Install-ViaWinget {
    $winget = Get-WingetPath
    if (-not $winget) {
        Write-Log "winget not found on this system." "Warning"
        return $false
    }

    Write-Log "Found winget at: $winget"
    Write-Log "Attempting install via winget (WireGuard.WireGuard)..."

    $output = & $winget install --id WireGuard.WireGuard --silent --scope machine `
        --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
    Write-Log "winget output: $($output.Trim())"

    if ($LASTEXITCODE -eq 0) {
        Write-Log "WireGuard installed successfully via winget."
        return $true
    }

    Write-Log "winget exited with code $LASTEXITCODE." "Warning"
    return $false
}

function Get-OSArchitecture {
    # PROCESSOR_ARCHITEW6432 is set when a 32-bit process runs on a 64-bit OS
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } `
        else { $env:PROCESSOR_ARCHITECTURE }
    switch ($native) {
        "ARM64" { return "arm64" }
        "AMD64" { return "amd64" }
        default { return "x86" }
    }
}

function Install-ViaDirectDownload {
    $arch = Get-OSArchitecture
    $downloadBase = "https://download.wireguard.com/windows-client"
    $useMsi = $false
    $installer = $null

    Write-Log "Fetching WireGuard MSI list for architecture: $arch"

    try {
        $listing = Invoke-WebRequest -Uri "$downloadBase/" -UseBasicParsing

        # Parse links for versioned MSIs matching our architecture
        $msiFile = $listing.Links |
        Where-Object { $_.href -match "^wireguard-$arch-[\d\.]+\.msi$" } |
        ForEach-Object {
            $verStr = $_.href -replace "^wireguard-$arch-", "" -replace "\.msi$", ""
            try { [PSCustomObject]@{ href = $_.href; Ver = [version]$verStr } }
            catch { $null }
        } |
        Where-Object { $_ } |
        Sort-Object Ver -Descending |
        Select-Object -First 1 -ExpandProperty href

        if (-not $msiFile) {
            throw "No MSI found for architecture '$arch' in directory listing."
        }

        $url = "$downloadBase/$msiFile"
        $installer = Join-Path $env:TEMP $msiFile
        Write-Log "Downloading: $url"
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
        $useMsi = $true

    }
    catch {
        Write-Log "MSI discovery/download failed: $($_.Exception.Message)" "Warning"
        Write-Log "Falling back to wireguard-installer.exe..."
        $installer = Join-Path $env:TEMP "wireguard-installer.exe"
        Invoke-WebRequest -Uri "$downloadBase/wireguard-installer.exe" -OutFile $installer -UseBasicParsing
        $useMsi = $false
    }

    Write-Log "Running installer silently..."
    if ($useMsi) {
        $proc = Start-Process msiexec.exe `
            -ArgumentList "/i `"$installer`" /quiet /norestart" `
            -Wait -PassThru -NoNewWindow
    }
    else {
        # wireguard-installer.exe is NSIS-based; /S = silent
        $proc = Start-Process $installer -ArgumentList "/S" -Wait -PassThru -NoNewWindow
    }

    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    # 0 = success, 3010 = success (reboot required)
    if ($proc.ExitCode -in @(0, 3010)) {
        Write-Log "WireGuard installed via direct download (exit code $($proc.ExitCode))."
        return $true
    }

    Write-Log "Installer exited with code $($proc.ExitCode)." "Error"
    return $false
}

function Set-LimitedOperatorUI {
    Write-Log "Applying LimitedOperatorUI registry key..."
    # Use the Win32 API directly to target the native 64-bit registry hive.
    # Set-ItemProperty / New-Item use the PowerShell provider which is subject to
    # WOW64 redirection when the host process is 32-bit (common with RMM agents),
    # silently writing to WOW6432Node instead of the hive WireGuard actually reads.
    try {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $key = $hklm.CreateSubKey("Software\WireGuard", $true)
        $key.SetValue("LimitedOperatorUI", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Flush()
        $key.Close()
        $hklm.Close()

        # Verify the write by reading back through the same 64-bit view.
        # Uses explicit null checks instead of ?. (null-conditional) which requires PS 7+.
        $hklm2 = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $verify = $hklm2.OpenSubKey("Software\WireGuard")
        $written = if ($verify) { $verify.GetValue("LimitedOperatorUI") } else { $null }
        if ($verify) { $verify.Close() }
        $hklm2.Close()

        if ($written -eq 1) {
            Write-Log "Verified: HKLM\SOFTWARE\WireGuard\LimitedOperatorUI = 1 (64-bit hive)"
        }
        else {
            Write-Log "Warning: LimitedOperatorUI readback returned '$written' - key may not have been written correctly." "Warning"
        }
    }
    catch {
        Write-Log "Failed to set LimitedOperatorUI registry key: $($_.Exception.Message)" "Error"
    }
}

function Test-UserExists {
    param([string]$Username)
    if (-not $Username) { return $false }
    try {
        # This handles local, domain, and Azure AD accounts
        $principal = New-Object System.Security.Principal.NTAccount($Username)
        $null = $principal.Translate([System.Security.Principal.SecurityIdentifier])
        return $true
    }
    catch {
        return $false
    }
}

function Show-LocalUsersList {
    Write-Log "Listing local users on this system to assist with troubleshooting:"
    try {
        $localUsers = Get-LocalUser | Select-Object Name, Enabled, Description
        foreach ($u in $localUsers) {
            $status = if ($u.Enabled) { "Enabled" } else { "Disabled" }
            Write-Log "  - Name: $($u.Name) ($status) | $($u.Description)"
        }
    }
    catch {
        Write-Log "Could not retrieve local users list: $($_.Exception.Message)" "Warning"
    }
}

function Add-AllUsersToNetworkConfigOperators {
    # Network Configuration Operators SID is S-1-5-32-556
    # Authenticated Users SID is S-1-5-11
    Write-Log "No TargetUser specified. Adding 'Authenticated Users' to 'Network Configuration Operators' to allow all users access..."
    try {
        # Resolve localized names from well-known SIDs to support non-English Windows editions
        $groupSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-556")
        $targetGroup = $groupSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]

        $memberSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
        $memberName = $memberSid.Translate([System.Security.Principal.NTAccount]).Value

        # Check if already a member
        $existing = Get-LocalGroupMember -Group $targetGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.SID.Value -eq "S-1-5-11" }

        if ($existing) {
            Write-Log "'Authenticated Users' is already a member of '$targetGroup'."
            return
        }

        Add-LocalGroupMember -Group $targetGroup -Member $memberName -ErrorAction Stop
        Write-Log "Successfully added '$memberName' to '$targetGroup'."
    }
    catch {
        Write-Log "Could not add 'Authenticated Users' to Network Configuration Operators: $($_.Exception.Message)" "Warning"
    }
}

function Add-TargetUserToNetworkConfigOperators {
    param([string]$Username)

    # Resolve localized name for Network Configuration Operators (S-1-5-32-556)
    try {
        $groupSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-556")
        $targetGroup = $groupSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    }
    catch {
        $targetGroup = "Network Configuration Operators"
    }

    # 1. Remove broad 'Authenticated Users' or 'Users' groups to secure the system
    try {
        $existingMembers = Get-LocalGroupMember -Group $targetGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.SID.Value -eq "S-1-5-11" -or $_.Name -like '*\Users' -or $_.Name -eq 'Users' }
        foreach ($m in $existingMembers) {
            Write-Log "Removing '$($m.Name)' from '$targetGroup' to restrict access to specific users..."
            Remove-LocalGroupMember -Group $targetGroup -Member $m.Name -ErrorAction Stop
            Write-Log "Removed '$($m.Name)' from '$targetGroup'."
        }
    }
    catch {
        Write-Log "Could not clean up group '$targetGroup': $($_.Exception.Message)" "Warning"
    }

    # 2. Add the specific target user
    Write-Log "Adding user '$Username' to '$targetGroup'..."
    try {
        # Check if already a member
        $member = Get-LocalGroupMember -Group $targetGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $Username -or $_.Name -like "*\$Username" }
        
        if ($member) {
            Write-Log "User '$Username' is already a member of '$targetGroup'."
            return $true
        }

        Add-LocalGroupMember -Group $targetGroup -Member $Username -ErrorAction Stop
        Write-Log "Successfully added '$Username' to '$targetGroup'."
        return $true
    }
    catch {
        Write-Log "Failed to add '$Username' to '$targetGroup': $($_.Exception.Message)" "Error"
        return $false
    }
}

function Install-WireGuardTunnel {
    param([string]$Config)

    $wgExe = "C:\Program Files\WireGuard\wireguard.exe"
    $wgDir = Split-Path $wgExe -Parent
    $confDir = Join-Path $wgDir "Data\Configurations"
    $confPath = Join-Path $confDir "wg0.conf"

    if (-not (Test-Path $wgExe)) {
        Write-Log "wireguard.exe not found - cannot import tunnel config." "Warning"
        return
    }

    # 1. Ensure configurations directory exists
    if (-not (Test-Path $confDir)) {
        Write-Log "Creating configurations directory: $confDir"
        New-Item -Path $confDir -ItemType Directory -Force | Out-Null
    }

    # 2. Write the plain text config file to a temporary location first.
    #    This prevents WireGuard's FileSystemWatcher from detecting a 0-byte file
    #    during the writing process and ignoring it.
    $tempConfPath = Join-Path $env:TEMP "wg0.conf"
    Write-Log "Writing config to temporary file: $tempConfPath"
    Set-Content -Path $tempConfPath -Value $Config -Encoding UTF8

    # 3. Copy the fully populated config file to the Configurations folder.
    #    We let it inherit the default secure permissions of the Configurations folder
    #    so that WireGuard's watcher/GUI has the necessary access to read and encrypt it.
    Write-Log "Copying fully populated config to configurations folder: $confPath"
    Copy-Item -Path $tempConfPath -Destination $confPath -Force
    Remove-Item -Path $tempConfPath -Force -ErrorAction SilentlyContinue

    # 4. Ensure the WireGuard Manager service is running if it is installed,
    #    so it can detect, encrypt, and process the dropped file.
    #    We do not install the manager service if it is missing, as per environment constraints.
    $managerSvcName = "WireGuardManager"
    $managerSvc = Get-Service -Name $managerSvcName -ErrorAction SilentlyContinue
    if ($managerSvc) {
        if ($managerSvc.Status -ne "Running") {
            Write-Log "Starting WireGuard Manager service ($managerSvcName)..."
            try {
                Start-Service -Name $managerSvcName -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "Failed to start WireGuard Manager service: $($_.Exception.Message)" "Warning"
            }
        }
    }
    else {
        Write-Log "WireGuard Manager service ($managerSvcName) not found." "Warning"
    }

    # 5. Wait a few seconds for the WireGuard Manager service to detect and encrypt the file
    Write-Log "Waiting for WireGuard service to detect, encrypt, and import the configuration..."
    $timeout = 15
    $elapsed = 0
    $encryptedPath = Join-Path $confDir "wg0.conf.dpapi"
    
    while ($elapsed -lt $timeout) {
        if (Test-Path $encryptedPath) {
            Write-Log "WireGuard successfully detected and encrypted the configuration into: wg0.conf.dpapi"
            break
        }
        Start-Sleep -Seconds 1
        $elapsed++
    }

    if (-not (Test-Path $encryptedPath)) {
        Write-Log "Warning: WireGuard did not encrypt wg0.conf within $timeout seconds. The tunnel config will remain as plain text unless processed later." "Warning"
    }
}

#endregion

try {
    Write-Log "=== WireGuard Installation Start ==="

    # Validate TargetUser parameter if one was specified
    if ($TargetUser) {
        if (-not (Test-UserExists -Username $TargetUser)) {
            Write-Log "Error: The specified user '$TargetUser' could not be found or resolved on this system." "Error"
            Show-LocalUsersList
            exit 1
        }
        Write-Log "Validated target user: $TargetUser"
    }
    else {
        Write-Log "No TargetUser specified. Access will be granted to all users."
    }

    # Install WireGuard if not already present
    if (Test-WireGuardInstalled) {
        Write-Log "WireGuard is already installed - skipping install step."
    }
    else {
        # Primary: winget
        $success = Install-ViaWinget

        # Fallback: direct download from wireguard.com
        if (-not $success -or -not (Test-WireGuardInstalled)) {
            Write-Log "Trying direct download fallback..."
            $success = Install-ViaDirectDownload
        }

        if (-not (Test-WireGuardInstalled)) {
            Write-Log "WireGuard installation could not be verified after all attempts." "Error"
            exit 1
        }

        Write-Log "WireGuard installation verified."
    }

    # Registry key: enable limited operator UI for non-admin tunnel management
    Set-LimitedOperatorUI

    # Add target user or all users to Network Configuration Operators
    if ($TargetUser) {
        Add-TargetUserToNetworkConfigOperators -Username $TargetUser
    }
    else {
        Add-AllUsersToNetworkConfigOperators
    }

    # Install tunnel config if one was provided
    if ($WireGuardConfig -ne "") {
        Write-Log "Installing tunnel config as 'wg0'..."
        Install-WireGuardTunnel -Config $WireGuardConfig
    }
    else {
        Write-Log "No tunnel config provided (wireguardConfig not set) - skipping tunnel registration."
    }

    Write-Log "=== WireGuard setup complete ===" "Success"
    exit 0

}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "Error"
    exit 1
}

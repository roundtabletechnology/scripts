<#
.SYNOPSIS
    Installs Claude Desktop machine-wide on Windows so it's available to every
    user on the device, including standard (non-admin) users.

.DESCRIPTION
    Claude Desktop for Windows ships as an MSIX package rather than a traditional
    per-machine MSI. Anthropic's own installer (ClaudeSetup.exe) runs a per-user
    Squirrel install into %LocalAppData%\AnthropicClaude - it's invisible to RMM/MDM
    inventory, doesn't provision the app for other users on the same device, and
    silently self-updates outside of change control.

    This script instead downloads the official MSIX package and provisions it at
    the machine level with Add-AppxProvisionedPackage, which:
    - Registers the app for any user profile that exists now or is created later,
      including standard users with no admin rights.
    - Requires no per-user installer run - provisioning happens once for the
      whole machine.

    Users who are already signed in when this runs may need to sign out and back
    in once before the Start Menu shortcut appears; new profiles get it
    automatically at first sign-in. This mirrors how built-in provisioned Windows
    apps behave.

    The script is idempotent - if Claude is already provisioned, it skips the
    install. It also scans local user profiles for a pre-existing per-user Squirrel
    install (from someone having run ClaudeSetup.exe manually) and logs a warning,
    since Anthropic provides no automatic Squirrel-to-MSIX upgrade path; those
    profiles need manual cleanup to avoid duplicate Start Menu entries and update
    conflicts.

.PARAMETER DisableAutoUpdates
    When set, writes HKLM:\SOFTWARE\Policies\Claude\disableAutoUpdates = 1 so
    Claude's built-in updater (which checks roughly every 4 hours) doesn't change
    the installed version outside of change control. Leave unset to allow Claude
    to self-update as usual. Can also be set via the 'disableAutoUpdates' Ninja
    script variable (env var), which accepts '1' or 'true' as truthy.

.EXAMPLE
    .\Install Claude Desktop.ps1

.EXAMPLE
    .\Install Claude Desktop.ps1 -DisableAutoUpdates

.NOTES
    Deployed via NinjaOne RMM. Runs at SYSTEM level with no interactive UI.
    Can also be run manually on a workstation for testing.

    Official MSIX download endpoints (per Anthropic's enterprise deployment docs):
      x64:   https://claude.ai/api/desktop/win32/x64/msix/latest/redirect
      arm64: https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect

    Reference: https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows
#>

#Requires -RunAsAdministrator

param(
    [switch]$DisableAutoUpdates
)

$ProgressPreference = "SilentlyContinue"

if ($env:disableAutoUpdates -match '^(1|true)$') { $DisableAutoUpdates = $true }

#region Functions

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$ts] [$Level] $Message"
}

function Get-OSArchitecture {
    # PROCESSOR_ARCHITEW6432 is set when a 32-bit process runs on a 64-bit OS
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } `
        else { $env:PROCESSOR_ARCHITECTURE }
    switch ($native) {
        "ARM64" { return "arm64" }
        "AMD64" { return "x64" }
        default { return $native }
    }
}

function Test-ClaudeProvisioned {
    $pkg = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*Claude*" }
    return [bool]$pkg
}

function Find-SquirrelClaudeInstalls {
    # Anthropic's standard installer runs a per-user Squirrel install into
    # %LocalAppData%\AnthropicClaude. Scan all local profiles for it so we can
    # warn the tech - there's no automatic Squirrel-to-MSIX upgrade path.
    $found = @()
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $path = Join-Path $_.FullName "AppData\Local\AnthropicClaude"
        if (Test-Path $path) { $found += $_.Name }
    }
    return $found
}

function Install-ClaudeMsix {
    param([string]$Arch)

    $url = "https://claude.ai/api/desktop/win32/$Arch/msix/latest/redirect"
    $msixPath = Join-Path $env:TEMP "ClaudeDesktop-$Arch.msix"

    Write-Log "Downloading Claude Desktop MSIX ($Arch) from: $url"
    Invoke-WebRequest -Uri $url -OutFile $msixPath -UseBasicParsing

    Write-Log "Provisioning package machine-wide via Add-AppxProvisionedPackage..."
    try {
        Add-AppxProvisionedPackage -Online -PackagePath $msixPath -SkipLicense -Regions "all" -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Log "Add-AppxProvisionedPackage failed: $($_.Exception.Message)" "Error"
        return $false
    }
    finally {
        Remove-Item $msixPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-ClaudeAutoUpdatePolicy {
    param([bool]$Disable)

    # Use the Win32 API directly to target the native 64-bit registry hive.
    # Set-ItemProperty / New-Item use the PowerShell provider which is subject to
    # WOW64 redirection when the host process is 32-bit (common with RMM agents),
    # silently writing to WOW6432Node instead of the hive Claude actually reads.
    Write-Log "Setting disableAutoUpdates policy to $([int]$Disable)..."
    try {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $key = $hklm.CreateSubKey("Software\Policies\Claude", $true)
        $key.SetValue("disableAutoUpdates", [int]$Disable, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Flush()
        $key.Close()
        $hklm.Close()
        Write-Log "disableAutoUpdates policy set."
    }
    catch {
        Write-Log "Failed to set disableAutoUpdates policy: $($_.Exception.Message)" "Warning"
    }
}

#endregion

try {
    Write-Log "=== Claude Desktop Installation Start ==="

    $squirrelProfiles = Find-SquirrelClaudeInstalls
    if ($squirrelProfiles.Count -gt 0) {
        Write-Log "Found a pre-existing per-user Claude install (Squirrel) for profile(s): $($squirrelProfiles -join ', ')" "Warning"
        Write-Log "There is no automatic upgrade path from the Squirrel installer to MSIX. These profiles may end up with duplicate Start Menu entries or update conflicts until manually cleaned up (remove %LocalAppData%\AnthropicClaude for that profile)." "Warning"
    }

    if (Test-ClaudeProvisioned) {
        Write-Log "Claude Desktop is already provisioned machine-wide - skipping install."
    }
    else {
        $arch = Get-OSArchitecture
        if ($arch -notin @("x64", "arm64")) {
            Write-Log "Unsupported or unrecognized architecture '$arch' - Claude Desktop only ships x64 and arm64 MSIX packages." "Error"
            exit 1
        }

        $success = Install-ClaudeMsix -Arch $arch
        if (-not $success -or -not (Test-ClaudeProvisioned)) {
            Write-Log "Claude Desktop provisioning could not be verified after install attempt." "Error"
            exit 1
        }

        Write-Log "Claude Desktop provisioned successfully. Users already signed in may need to sign out/in once to see the Start Menu shortcut; new profiles get it automatically at first sign-in."
    }

    if ($DisableAutoUpdates) {
        Set-ClaudeAutoUpdatePolicy -Disable $true
    }

    Write-Log "=== Claude Desktop setup complete ===" "Success"
    exit 0

}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "Error"
    exit 1
}

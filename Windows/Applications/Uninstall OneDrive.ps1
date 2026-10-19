<#
.SYNOPSIS
    Silently removes the OneDrive sync app for every user on a Windows machine and blocks it from coming back,
    with no prompts and no reboot.

.DESCRIPTION
    OneDrive can be present at two levels, and comes back through several channels:

      Per-user install (the default)  %LOCALAPPDATA%\Microsoft\OneDrive, registered under each user's HKCU. Its
                                      uninstaller only works in that user's own context (as SYSTEM it uninstalls
                                      for SYSTEM), and run as the user it can raise a prompt - so it is not used.
      Per-machine install             Program Files\Microsoft OneDrive, installed with /allusers and registered
                                      under HKLM.
      New-profile bootstrap           Windows writes an "OneDriveSetup" Run value into the Default user hive, so
                                      every new profile installs OneDrive at first sign-in. Feature updates can
                                      put it back.
      Microsoft 365 Apps              Click-to-Run installs OneDrive alongside Office unless the deployment config
                                      excludes it (<ExcludeApp ID="OneDrive" />).
      Self-update                     Per-user scheduled tasks keep each install current.

    This script deals with all of them:
      1. Surveys every user profile (local, domain and Entra ID), loading the registry hive of anyone not signed in.
      2. For each profile with OneDrive, removes it directly from SYSTEM, signed in or not: processes, Run values,
         uninstall entry, scheduled tasks, shell extension and protocol registrations, File Explorer navigation pane
         entries, sync root registrations, the Microsoft.OneDriveSync package, Start menu shortcut and finally the
         program folder.
      3. Removes a per-machine install, if present.
      4. Removes the OneDriveSetup bootstrap from the Default user hive and from any existing profile that has not
         run it yet.
      5. Sets the "Prevent the usage of OneDrive for file storage" policy (DisableFileSyncNGSC = 1). This is what
         makes the removal stick: whatever reinstalls OneDrive later - an Office install or repair, a feature
         update, a user - the sync app will not run.
      6. Reports, but does not change, a Microsoft 365 Apps install that is not configured to exclude OneDrive.

    DATA SAFETY - Known Folder Move. If a user's Desktop, Documents, Pictures etc. are redirected into their OneDrive
    folder, removing OneDrive leaves those folders pointing at a folder that no longer syncs, and any file that was
    online-only (Files On-Demand) disappears from them. Nothing is lost - it is all still in OneDrive online - but to
    the user it looks like their desktop emptied. So by default such a profile is SKIPPED and reported, and because
    the policy in step 5 would stop OneDrive for that user too, the policy and the per-machine removal are also held
    back on that machine. The script exits 1 so the device stands out in NinjaOne. Move those users' folders back to
    local paths first, or pass -IncludeKnownFolderMoveUsers to remove OneDrive regardless.

    USER FILES ARE NEVER DELETED. The only folders removed are OneDrive's program folders
    (%LOCALAPPDATA%\Microsoft\OneDrive - binaries, logs and sync settings - and Program Files\Microsoft OneDrive), and
    the delete routine refuses any other path. Each user's synced folder (C:\Users\<name>\OneDrive...) is left exactly
    where it is, with everything that was stored locally still in it; anything that was online-only remains in
    OneDrive online. Files that were edited but not yet uploaded stay local and are simply no longer synced.

.PARAMETER IncludeKnownFolderMoveUsers
    Remove OneDrive from profiles whose known folders are redirected into OneDrive as well, and apply the policy even
    when such profiles exist. Their Desktop/Documents keep pointing at the OneDrive folder, showing only the files
    that were stored locally. NinjaOne script variable: includeKnownFolderMoveUsers (checkbox).

.PARAMETER SkipPolicy
    Do not set DisableFileSyncNGSC. OneDrive is still removed, but nothing stops it from running if it is reinstalled.
    NinjaOne script variable: skipPolicy (checkbox).

.PARAMETER DryRun
    Survey and report what would be done, without changing anything. Useful for finding Known Folder Move users
    across a fleet before the real run. NinjaOne script variable: dryRun (checkbox).

.PARAMETER UninstallTimeoutSeconds
    How long to wait for the per-machine OneDrive uninstaller (run as SYSTEM) before moving on to the direct
    cleanup. Default 300.

.EXAMPLE
    .\Uninstall OneDrive.ps1 -DryRun

    Reports every profile's OneDrive state, Known Folder Move redirections and what would be removed.

.EXAMPLE
    .\Uninstall OneDrive.ps1

    Removes OneDrive everywhere it is safe to, and sets the policy unless a Known Folder Move user was skipped.

.EXAMPLE
    .\Uninstall OneDrive.ps1 -IncludeKnownFolderMoveUsers

    Removes OneDrive from every profile, Known Folder Move or not, and sets the policy.

.NOTES
    Exit codes: 0 = OneDrive removed (or was not present) and the policy is in place.
                1 = a profile was skipped for Known Folder Move, something could not be removed, or a fatal error.

    Never reboots, never restarts Explorer and never shows anything to the user. The only visible effects are the
    OneDrive tray icon disappearing and, for signed-in users, the OneDrive entry in File Explorer's navigation pane,
    which can linger until they next sign in. Files that Explorer still has loaded (OneDrive's shell extension) are
    scheduled for deletion at the next restart, whenever that happens.

    Safe to run repeatedly. Schedule it in NinjaOne (e.g. weekly) to catch OneDrive coming back with a feature
    update or a new user profile.

    Deliberately NOT done:
      - C:\Windows\System32\OneDriveSetup.exe is left alone. It is owned by TrustedInstaller, feature updates restore
        it, and with the bootstrap Run value gone and the policy set it does nothing.
      - Microsoft 365 Apps' configuration is not changed. To stop Office installing OneDrive in the first place, add
        <ExcludeApp ID="OneDrive" /> to the Office Deployment Tool configuration used for this client.

    Run as SYSTEM (NinjaOne default) in 64-bit PowerShell; a 32-bit host relaunches itself in 64-bit.
#>

param (
    [switch]$IncludeKnownFolderMoveUsers,
    [switch]$SkipPolicy,
    [switch]$DryRun,
    [int]$UninstallTimeoutSeconds = 300
)

# Equivalent to "#Requires -RunAsAdministrator", which PowerShell 2.0/3.0 fails to parse as a switch.
$CurrentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
if (-not $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'This script requires administrator privileges.'
    exit 1
}

# A 32-bit host sees HKLM\SOFTWARE through WOW6432Node and cannot manage AppX packages, so relaunch in 64-bit.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($IncludeKnownFolderMoveUsers) { $Relaunch += '-IncludeKnownFolderMoveUsers' }
    if ($SkipPolicy)                  { $Relaunch += '-SkipPolicy' }
    if ($DryRun)                      { $Relaunch += '-DryRun' }
    $Relaunch += @('-UninstallTimeoutSeconds', $UninstallTimeoutSeconds)
    & "$env:windir\SysNative\WindowsPowerShell\v1.0\powershell.exe" @Relaunch
    exit $LASTEXITCODE
}

$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

# NinjaOne checkbox script variables arrive as the strings 'true'/'false'.
if ($env:includeKnownFolderMoveUsers -match '^(1|true|yes)$') { $IncludeKnownFolderMoveUsers = $true }
if ($env:skipPolicy -match '^(1|true|yes)$')                  { $SkipPolicy = $true }
if ($env:dryRun -match '^(1|true|yes)$')                      { $DryRun = $true }

$PolicyKey        = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
$SyncRootKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
$PersonalNavClsid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
$MachineInstalls  = @("$env:ProgramFiles\Microsoft OneDrive", "${env:ProgramFiles(x86)}\Microsoft OneDrive") | Where-Object { $_ -notmatch '^\\' }
$OverlayKeys      = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
)
$script:RemovedClsids = @()
$MachineUninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe'
)

# Write-Host rather than Write-Output so that helper functions returning a value do not also return their log
# lines. NinjaOne and the transcript both capture host output.
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    Write-Host ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

# Runs $Action, or under -DryRun only logs that it would have. Every change the script makes goes through here.
function Invoke-Change {
    param (
        [Parameter(Mandatory = $true)] [string]$Description,
        [Parameter(Mandatory = $true)] [scriptblock]$Action
    )
    if ($DryRun) {
        Write-Log "[DryRun] Would: $Description"
        return
    }
    Write-Log $Description
    try {
        & $Action
    } catch {
        Write-Log "Failed: $Description - $($_.Exception.Message)" -Level Warning
    }
}

# The null destination has to be passed from C#: PowerShell converts $null to an empty string when calling a .NET
# method with a string parameter, and MoveFileEx then fails with ERROR_PATH_NOT_FOUND. Returns 0 or the Win32 error.
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace OneDriveRemoval {
    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
        private const int MOVEFILE_DELAY_UNTIL_REBOOT = 4;
        public static int DeleteAtReboot(string path) {
            return MoveFileEx(path, null, MOVEFILE_DELAY_UNTIL_REBOOT) ? 0 : Marshal.GetLastWin32Error();
        }
    }
}
'@

# Deletes a folder, and schedules whatever is locked (OneDrive's shell extension DLL, loaded by a signed-in user's
# Explorer) for deletion at the next restart instead of forcing one. Files are queued before their folders, deepest
# folders first, because a folder can only be removed at boot once it is empty.
#
# This only ever deletes OneDrive's program folders, never a folder that could hold user files: anything other than
# ...\AppData\Local\Microsoft\OneDrive or ...\Microsoft OneDrive is refused, and so is a tree containing a junction or
# symlink, because Windows PowerShell 5.1's Remove-Item -Recurse can follow one into the folder it points at.
function Remove-PathNowOrAtReboot {
    param ([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($Path -notmatch '\\AppData\\Local\\Microsoft\\OneDrive$' -and $Path -notmatch '^[A-Za-z]:\\Program Files( \(x86\))?\\Microsoft OneDrive$') {
        Write-Log "Refusing to delete '$Path': not a OneDrive program folder." -Level Error
        return
    }
    $Links = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { $Links += Get-Item -LiteralPath $Path -Force }
    if ($Links.Count -gt 0) {
        Write-Log "Not deleting '$Path': it contains a junction or symlink ($($Links[0].FullName)). Remove it by hand after checking where it points." -Level Warning
        return
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $Leftovers = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
    $Ordered = @($Leftovers | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.FullName }) +
               @($Leftovers | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { $_.FullName }) +
               @($Path)
    $NotQueued = 0
    foreach ($Item in $Ordered) {
        $Win32Error = [OneDriveRemoval.NativeMethods]::DeleteAtReboot($Item)
        if ($Win32Error -ne 0) {
            $NotQueued++
            Write-Log "Could not queue '$Item' for deletion at restart (Win32 error $Win32Error)." -Level Warning
        }
    }
    Write-Log "$($Leftovers.Count) item(s) under '$Path' are in use; $($Ordered.Count - $NotQueued) of $($Ordered.Count) queued for deletion at the next restart." -Level Warning
}

# Splits an UninstallString such as '"C:\...\OneDriveSetup.exe"  /uninstall /allusers' into exe and arguments.
function Split-CommandLine {
    param ([string]$CommandLine)
    if ($CommandLine -match '^\s*"([^"]+)"\s*(.*)$' -or $CommandLine -match '^\s*(\S+?\.exe)\s*(.*)$') {
        return [PSCustomObject]@{ FilePath = $Matches[1]; Arguments = $Matches[2].Trim() }
    }
    return $null
}

# Runs a process with a bound on how long to wait. System.Diagnostics.Process is used directly because
# Start-Process -PassThru without -Wait does not populate ExitCode on Windows PowerShell 5.1.
function Invoke-ProcessWithTimeout {
    param (
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [string]$Arguments,
        [int]$TimeoutSeconds = 300
    )
    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName        = $FilePath
    $StartInfo.Arguments       = $Arguments
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow  = $true
    $Process = [System.Diagnostics.Process]::Start($StartInfo)
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Log "'$FilePath $Arguments' did not finish within $TimeoutSeconds seconds; stopping it." -Level Warning
        try { $Process.Kill() } catch { }
        return $null
    }
    return $Process.ExitCode
}

# Kills every process running from under $Path - OneDrive.exe, its updater, FileCoAuth.exe and so on. Matching on
# path rather than name means only the OneDrive belonging to the profile (or machine install) being removed is hit.
function Stop-ProcessesUnderPath {
    param ([Parameter(Mandatory = $true)] [string]$Path)
    $Prefix = $Path.TrimEnd('\') + '\'
    Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            Write-Log "Stopping $($_.Name) (PID $($_.ProcessId))"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

# Every real user profile: local and on-premises AD accounts (S-1-5-21-*) and Entra ID accounts (S-1-12-1-*).
function Get-UserProfiles {
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[\d-]+$' } |
        ForEach-Object {
            $ProfilePath = (Get-ItemProperty -LiteralPath $_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            if (-not $ProfilePath -or -not (Test-Path -LiteralPath $ProfilePath)) { return }
            $Account = $null
            try {
                $Account = (New-Object Security.Principal.SecurityIdentifier($_.PSChildName)).Translate([Security.Principal.NTAccount]).Value
            } catch { }
            [PSCustomObject]@{
                Sid         = $_.PSChildName
                ProfilePath = $ProfilePath
                Account     = $Account
                Label       = if ($Account) { $Account } else { $_.PSChildName }
            }
        }
}

# Returns the registry root of a user's hive, loading NTUSER.DAT under a temporary name if the user is not signed
# in. $script:MountedHives tracks what this script loaded so it can all be unloaded again in the finally block.
$script:MountedHives = @()
function Mount-UserHive {
    param ([Parameter(Mandatory = $true)] [string]$Name, [Parameter(Mandatory = $true)] [string]$HiveFile)

    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$Name") { return "Registry::HKEY_USERS\$Name" }
    if (-not (Test-Path -LiteralPath $HiveFile)) { return $null }

    $TempName = "OneDriveRemoval_$($Name -replace '[^\w-]', '')"
    & reg.exe load "HKU\$TempName" $HiveFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    $script:MountedHives += $TempName
    return "Registry::HKEY_USERS\$TempName"
}

function Dismount-UserHives {
    foreach ($TempName in $script:MountedHives) {
        # Any lingering .NET handle to the hive makes reg unload fail, so release them first.
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
            & reg.exe unload "HKU\$TempName" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
        if ($LASTEXITCODE -ne 0) { Write-Log "Could not unload hive HKU\$TempName." -Level Warning }
    }
    $script:MountedHives = @()
}

# Removes Run/RunOnce values that start OneDrive or its first-run installer from one hive (or HKLM).
function Remove-OneDriveRunValues {
    param ([Parameter(Mandatory = $true)] [string]$Root, [Parameter(Mandatory = $true)] [string]$Label)

    foreach ($SubKey in @('Software\Microsoft\Windows\CurrentVersion\Run', 'Software\Microsoft\Windows\CurrentVersion\RunOnce',
                          'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        $Key = Get-Item -LiteralPath "$Root\$SubKey" -ErrorAction SilentlyContinue
        if (-not $Key) { continue }
        foreach ($ValueName in $Key.GetValueNames()) {
            $Data = [string]$Key.GetValue($ValueName)
            if ($Data -match '\\OneDrive(Setup)?\.exe') {
                Invoke-Change "Remove $SubKey\$ValueName from $Label ($Data)" {
                    Remove-ItemProperty -LiteralPath "$Root\$SubKey" -Name $ValueName -Force -ErrorAction Stop
                }
            }
        }
    }
}

# Reads a user's OneDrive accounts and known folder redirections from their hive. Shell folder paths are read
# without expanding environment variables, because expanding them here would use SYSTEM's %USERPROFILE%.
function Get-ProfileOneDriveState {
    param ([Parameter(Mandatory = $true)] $UserProfile, [Parameter(Mandatory = $true)] [string]$HiveRoot)

    $InstallDir = Join-Path $UserProfile.ProfilePath 'AppData\Local\Microsoft\OneDrive'
    $UninstallString = (Get-ItemProperty -LiteralPath "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe" -ErrorAction SilentlyContinue).UninstallString

    $Accounts = @(Get-ChildItem -LiteralPath "$HiveRoot\Software\Microsoft\OneDrive\Accounts" -ErrorAction SilentlyContinue | ForEach-Object {
        $Props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        if ($Props.UserFolder) {
            [PSCustomObject]@{ Name = $_.PSChildName; UserFolder = $Props.UserFolder.TrimEnd('\'); Email = $Props.UserEmail }
        }
    })

    $Redirected = @()
    $ShellFolders = Get-Item -LiteralPath "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
    if ($ShellFolders) {
        foreach ($ValueName in $ShellFolders.GetValueNames()) {
            $Raw = [string]$ShellFolders.GetValue($ValueName, $null, 'DoNotExpandEnvironmentNames')
            $Expanded = $Raw -ireplace [regex]::Escape('%USERPROFILE%'), $UserProfile.ProfilePath
            $UnderAccount = $Accounts | Where-Object { $Expanded -eq $_.UserFolder -or $Expanded -like "$($_.UserFolder)\*" }
            $LooksLikeOneDrive = $Expanded -like "$($UserProfile.ProfilePath)\*" -and $Expanded -match '\\OneDrive( - [^\\]+)?(\\|$)'
            if ($UnderAccount -or $LooksLikeOneDrive) {
                $Redirected += [PSCustomObject]@{ Folder = $ValueName; Path = $Expanded }
            }
        }
    }

    [PSCustomObject]@{
        InstallDir      = $InstallDir
        PerUserInstall  = (Test-Path -LiteralPath (Join-Path $InstallDir 'OneDrive.exe')) -or [bool]$UninstallString
        UninstallString = $UninstallString
        Accounts        = $Accounts
        Redirected      = $Redirected
    }
}

# Removes OneDrive from a profile directly, without its uninstaller. Works the same whether or not the user is signed
# in; for a signed-in user, Explorer keeps the shell extension DLL loaded until they sign out. Idempotent.
function Remove-ProfileOneDriveLeftovers {
    param ([Parameter(Mandatory = $true)] $UserProfile, [Parameter(Mandatory = $true)] $State, [Parameter(Mandatory = $true)] [string]$HiveRoot)

    $Label = $UserProfile.Label

    if (Test-Path -LiteralPath $State.InstallDir) {
        Invoke-Change "Stop OneDrive processes for $Label" { Stop-ProcessesUnderPath -Path $State.InstallDir }
    }

    Remove-OneDriveRunValues -Root $HiveRoot -Label $Label

    $UninstallKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
    if (Test-Path -LiteralPath $UninstallKey) {
        Invoke-Change "Remove OneDrive uninstall entry for $Label" { Remove-Item -LiteralPath $UninstallKey -Recurse -Force -ErrorAction Stop }
    }

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like "OneDrive*-$($UserProfile.Sid)" } |
        ForEach-Object {
            $Task = $_
            Invoke-Change "Delete scheduled task '$($Task.TaskName)'" {
                Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Confirm:$false -ErrorAction Stop
            }
        }

    # File Explorer navigation pane: the Personal entry uses a fixed CLSID, work/school entries get a generated CLSID
    # whose target folder is the account's OneDrive folder.
    $NameSpaceKey = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace"
    Get-ChildItem -LiteralPath $NameSpaceKey -ErrorAction SilentlyContinue | ForEach-Object {
        $Clsid = $_.PSChildName
        $ClsidKey = "$HiveRoot\Software\Classes\CLSID\$Clsid"
        $Target = (Get-ItemProperty -LiteralPath "$ClsidKey\Instance\InitPropertyBag" -ErrorAction SilentlyContinue).TargetFolderPath
        $IsOneDrive = $Clsid -eq $PersonalNavClsid -or
                      ($Target -and ($State.Accounts | Where-Object { $Target.TrimEnd('\') -eq $_.UserFolder })) -or
                      ($Target -and $Target -match '\\OneDrive( - [^\\]+)?\\?$')
        if ($IsOneDrive) {
            $NameSpaceEntry = $_.PSPath
            Invoke-Change "Remove File Explorer navigation entry $Clsid for $Label" {
                Remove-Item -LiteralPath $NameSpaceEntry -Recurse -Force -ErrorAction Stop
                if ($Clsid -ne $PersonalNavClsid) { Remove-Item -LiteralPath $ClsidKey -Recurse -Force -ErrorAction SilentlyContinue }
                Remove-ItemProperty -LiteralPath "$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" -Name $Clsid -ErrorAction SilentlyContinue
            }
        }
    }

    # OneDrive pins its Personal entry with a per-user override of a CLSID that Windows itself owns, so unpin it
    # rather than delete it.
    $PersonalOverride = "$HiveRoot\Software\Classes\CLSID\$PersonalNavClsid"
    if ((Get-ItemProperty -LiteralPath $PersonalOverride -Name 'System.IsPinnedToNameSpaceTree' -ErrorAction SilentlyContinue).'System.IsPinnedToNameSpaceTree' -eq 1) {
        Invoke-Change "Unpin OneDrive - Personal from File Explorer for $Label" {
            Set-ItemProperty -LiteralPath $PersonalOverride -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord -ErrorAction Stop
        }
    }

    Get-ChildItem -LiteralPath $SyncRootKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "OneDrive!$($UserProfile.Sid)!*" } |
        ForEach-Object {
            $SyncRoot = $_
            Invoke-Change "Remove sync root registration '$($SyncRoot.PSChildName)'" {
                Remove-Item -LiteralPath $SyncRoot.PSPath -Recurse -Force -ErrorAction Stop
            }
        }

    # COM classes (shell extension, overlay icons, coauthoring) and protocol handlers (odopen:, etc.) that OneDrive
    # registered in the user's hive, identified by pointing into the program folder. This is what OneDrive's own
    # uninstaller would unregister. Registry paths are read unexpanded and expanded against this profile, not SYSTEM.
    # Uses the .NET registry API directly: walking a user's Classes key through the registry provider takes minutes.
    $LocalAppData = Join-Path $UserProfile.ProfilePath 'AppData\Local'
    $InstallPrefix = "$($State.InstallDir)\"
    $HiveName = $HiveRoot -replace '^Registry::HKEY_USERS\\', ''
    $Registrations = @()
    $Classes = [Microsoft.Win32.Registry]::Users.OpenSubKey("$HiveName\Software\Classes")
    if ($Classes) {
        try {
            $Candidates = @()
            foreach ($ClsidPath in @('CLSID', 'WOW6432Node\CLSID')) {
                $ClsidRoot = $Classes.OpenSubKey($ClsidPath)
                if (-not $ClsidRoot) { continue }
                foreach ($Name in $ClsidRoot.GetSubKeyNames()) {
                    $Candidates += [PSCustomObject]@{ Path = "$ClsidPath\$Name"; Name = $Name; Values = @("$ClsidPath\$Name\InprocServer32", "$ClsidPath\$Name\LocalServer32") }
                }
                $ClsidRoot.Close()
            }
            foreach ($Name in $Classes.GetSubKeyNames()) {
                if ($Name -in 'CLSID', 'WOW6432Node') { continue }
                $Candidates += [PSCustomObject]@{ Path = $Name; Name = $Name; Values = @("$Name\shell\open\command") }
            }
            foreach ($Candidate in $Candidates) {
                foreach ($ValuePath in $Candidate.Values) {
                    $Key = $Classes.OpenSubKey($ValuePath)
                    if (-not $Key) { continue }
                    $Value = [string]$Key.GetValue('', $null, 'DoNotExpandEnvironmentNames')
                    $Key.Close()
                    $Target = ($Value -ireplace '%LOCALAPPDATA%', $LocalAppData.Replace('$', '$$') -ireplace '%USERPROFILE%', $UserProfile.ProfilePath.Replace('$', '$$')).Trim().TrimStart('"')
                    if ($Target.StartsWith($InstallPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                        $Registrations += $Candidate
                        break
                    }
                }
            }
        } finally {
            $Classes.Close()
        }
    }
    if ($Registrations.Count -gt 0) {
        Invoke-Change "Remove $($Registrations.Count) OneDrive COM/protocol registration(s) for $Label" {
            foreach ($Registration in $Registrations) {
                $script:RemovedClsids += $Registration.Name
                Remove-Item -LiteralPath "$HiveRoot\Software\Classes\$($Registration.Path)" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        Get-AppxPackage -Name 'Microsoft.OneDriveSync' -User $UserProfile.Sid -ErrorAction Stop | ForEach-Object {
            $Package = $_
            Invoke-Change "Remove package $($Package.PackageFullName) for $Label" {
                Remove-AppxPackage -Package $Package.PackageFullName -User $UserProfile.Sid -ErrorAction Stop
            }
        }
    } catch {
        Write-Log "Could not query AppX packages for ${Label}: $($_.Exception.Message)" -Level Warning
    }

    $Shortcut = Join-Path $UserProfile.ProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk'
    if (Test-Path -LiteralPath $Shortcut) {
        Invoke-Change "Remove Start menu shortcut for $Label" { Remove-Item -LiteralPath $Shortcut -Force -ErrorAction Stop }
    }

    # Program files, logs and settings only - the user's synced files live in the OneDrive folder in their profile
    # root, which is never touched.
    if (Test-Path -LiteralPath $State.InstallDir) {
        Invoke-Change "Delete $($State.InstallDir)" { Remove-PathNowOrAtReboot -Path $State.InstallDir }
    }
}

# Reports a Microsoft 365 Apps install that will put OneDrive back on an install or repair.
function Test-OfficeExcludesOneDrive {
    $C2R = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if (-not $C2R -or -not $C2R.ProductReleaseIds) { return }
    foreach ($ProductId in ($C2R.ProductReleaseIds -split ',')) {
        $Excluded = $C2R."$ProductId.ExcludedApps"
        if ($Excluded -notmatch '(^|,)onedrive(,|$)') {
            Write-Log "Microsoft 365 Apps product '$ProductId' does not exclude OneDrive, so an Office install or repair can reinstall it (the policy keeps it from running). To stop that at the source, add <ExcludeApp ID=""OneDrive"" /> to the Office Deployment Tool configuration." -Level Warning
        }
    }
}

$Now     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogPath = "$env:windir\Temp\UninstallOneDrive_$Now.log"
Start-Transcript -Path $LogPath -Force | Out-Null

$Failed  = $false
$Targets = @()
$Blocked = @()
try {
    if ($DryRun) { Write-Log 'DRY RUN - nothing will be changed.' }

    $SignedInSids = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid } |
        Where-Object { $_ } | Select-Object -Unique)

    $MachineInstallKey = $MachineUninstallKeys | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $MachineInstallDir = $MachineInstalls | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'OneDrive.exe') } | Select-Object -First 1
    $HasMachineInstall = [bool]($MachineInstallKey -or $MachineInstallDir)
    if ($HasMachineInstall) { Write-Log "Per-machine OneDrive install found ($(if ($MachineInstallDir) { $MachineInstallDir } else { $MachineInstallKey }))." }

    # --- Survey ---
    foreach ($UserProfile in @(Get-UserProfiles)) {
        $HiveRoot = Mount-UserHive -Name $UserProfile.Sid -HiveFile (Join-Path $UserProfile.ProfilePath 'NTUSER.DAT')
        if (-not $HiveRoot) {
            # Without the hive there is no way to check for Known Folder Move, so treat the profile as unsafe.
            if (Test-Path -LiteralPath (Join-Path $UserProfile.ProfilePath 'AppData\Local\Microsoft\OneDrive\OneDrive.exe')) {
                Write-Log "$($UserProfile.Label): OneDrive is installed but the registry hive could not be loaded. Skipping." -Level Warning
                $Blocked += $UserProfile
            }
            continue
        }

        $State = Get-ProfileOneDriveState -UserProfile $UserProfile -HiveRoot $HiveRoot
        $HasOneDrive = $State.PerUserInstall -or ($HasMachineInstall -and $State.Accounts.Count -gt 0)
        $SignedIn = $SignedInSids -contains $UserProfile.Sid

        $Summary = "$($UserProfile.Label): " + $(if ($State.PerUserInstall) { 'per-user install' } elseif ($HasOneDrive) { 'uses per-machine install' } else { 'OneDrive not installed' })
        $Summary += $(if ($SignedIn) { ', signed in' } else { ', not signed in' })
        foreach ($Account in $State.Accounts) {
            $Summary += "; account '$($Account.Name)'$(if ($Account.Email) { " ($($Account.Email))" }) syncs to $($Account.UserFolder)"
        }
        Write-Log $Summary

        if ($State.Redirected.Count -gt 0) {
            $Folders = ($State.Redirected | ForEach-Object { "$($_.Folder) -> $($_.Path)" }) -join '; '
            if ($HasOneDrive -and -not $IncludeKnownFolderMoveUsers) {
                Write-Log "$($UserProfile.Label): known folders are redirected into OneDrive ($Folders). Skipping this profile - move these folders back to local paths first, or rerun with -IncludeKnownFolderMoveUsers." -Level Warning
                $Blocked += $UserProfile
                continue
            }
            Write-Log "$($UserProfile.Label): known folders are redirected into OneDrive ($Folders). They will keep pointing there, showing only files stored locally." -Level Warning
        }

        $Targets += [PSCustomObject]@{ Profile = $UserProfile; State = $State; HiveRoot = $HiveRoot; SignedIn = $SignedIn; HasOneDrive = $HasOneDrive }
    }

    # --- Per-user removal ---
    foreach ($Target in $Targets) {
        # Clear a pending OneDriveSetup bootstrap even for profiles that never got as far as installing OneDrive.
        # A program folder left from an earlier run (locked files, not yet rebooted) still gets the full sweep.
        if (-not $Target.HasOneDrive -and -not (Test-Path -LiteralPath $Target.State.InstallDir)) {
            Remove-OneDriveRunValues -Root $Target.HiveRoot -Label $Target.Profile.Label
            continue
        }
        Write-Log "Removing OneDrive for $($Target.Profile.Label)..."
        Remove-ProfileOneDriveLeftovers -UserProfile $Target.Profile -State $Target.State -HiveRoot $Target.HiveRoot
    }

    # --- New profiles ---
    $DefaultHive = Mount-UserHive -Name 'DefaultUser' -HiveFile "$env:SystemDrive\Users\Default\NTUSER.DAT"
    if ($DefaultHive) {
        Remove-OneDriveRunValues -Root $DefaultHive -Label 'the Default user profile'
    } else {
        Write-Log 'Could not load the Default user hive; new profiles may still install OneDrive at first sign-in.' -Level Warning
        $Failed = $true
    }

    # --- Machine-wide ---
    if ($Blocked.Count -gt 0) {
        Write-Log "$($Blocked.Count) profile(s) were skipped, so the per-machine removal and the policy are being held back on this machine - either would stop OneDrive for those users too." -Level Warning
    } else {
        Remove-OneDriveRunValues -Root 'HKLM:' -Label 'HKLM'

        if ($HasMachineInstall) {
            foreach ($Dir in $MachineInstalls) {
                if (Test-Path -LiteralPath $Dir) { Invoke-Change "Stop OneDrive processes running from $Dir" { Stop-ProcessesUnderPath -Path $Dir } }
            }
            $Command = if ($MachineInstallKey) { Split-CommandLine (Get-ItemProperty -LiteralPath $MachineInstallKey).UninstallString } else { $null }
            if ($Command -and (Test-Path -LiteralPath $Command.FilePath)) {
                $Arguments = if ($Command.Arguments -match '/allusers') { $Command.Arguments } else { "$($Command.Arguments) /allusers".Trim() }
                Invoke-Change "Run per-machine uninstaller: $($Command.FilePath) $Arguments" {
                    $ExitCode = Invoke-ProcessWithTimeout -FilePath $Command.FilePath -Arguments $Arguments -TimeoutSeconds $UninstallTimeoutSeconds
                    Write-Log "Per-machine uninstaller exited with code $ExitCode."
                }
            }
            foreach ($Key in $MachineUninstallKeys) {
                if (Test-Path -LiteralPath $Key) { Invoke-Change "Remove $Key" { Remove-Item -LiteralPath $Key -Recurse -Force -ErrorAction Stop } }
            }
            foreach ($Dir in $MachineInstalls) {
                if (Test-Path -LiteralPath $Dir) { Invoke-Change "Delete $Dir" { Remove-PathNowOrAtReboot -Path $Dir } }
            }
        }

        # Overlay icon handlers can only be registered machine-wide, even for a per-user install; they point at the
        # COM classes removed per profile above (or are named " OneDrive1".." OneDrive7" if that was done earlier).
        foreach ($OverlayKey in $OverlayKeys) {
            Get-ChildItem -LiteralPath $OverlayKey -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^\s*OneDrive\d*$' -or $script:RemovedClsids -contains [string]$_.GetValue('') } |
                ForEach-Object {
                    $Overlay = $_
                    Invoke-Change "Remove overlay icon handler '$($Overlay.PSChildName.Trim())'" {
                        Remove-Item -LiteralPath $Overlay.PSPath -Recurse -Force -ErrorAction Stop
                    }
                }
        }

        $CommonShortcut = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
        if (Test-Path -LiteralPath $CommonShortcut) {
            Invoke-Change 'Remove the all-users OneDrive Start menu shortcut' { Remove-Item -LiteralPath $CommonShortcut -Force -ErrorAction Stop }
        }

        # Whatever OneDrive task is left belongs to a profile that no longer exists or to the per-machine updater.
        Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like 'OneDrive*' -and (($_.Actions | ForEach-Object { $_.Execute }) -join ' ') -match 'OneDrive' } |
            ForEach-Object {
                $Task = $_
                Invoke-Change "Delete scheduled task '$($Task.TaskName)'" {
                    Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Confirm:$false -ErrorAction Stop
                }
            }

        try {
            Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq 'Microsoft.OneDriveSync' } | ForEach-Object {
                $Package = $_
                Invoke-Change "Deprovision $($Package.PackageName)" {
                    Remove-AppxProvisionedPackage -Online -PackageName $Package.PackageName -ErrorAction Stop | Out-Null
                }
            }
        } catch {
            Write-Log "Could not query provisioned AppX packages: $($_.Exception.Message)" -Level Warning
        }

        if ($SkipPolicy) {
            Write-Log 'Skipping the DisableFileSyncNGSC policy (-SkipPolicy). OneDrive will run again if it is reinstalled.' -Level Warning
        } elseif ((Get-ItemProperty -LiteralPath $PolicyKey -Name DisableFileSyncNGSC -ErrorAction SilentlyContinue).DisableFileSyncNGSC -eq 1) {
            Write-Log 'Policy DisableFileSyncNGSC is already set.'
        } else {
            Invoke-Change 'Set policy DisableFileSyncNGSC = 1 (Prevent the usage of OneDrive for file storage)' {
                New-Item -Path $PolicyKey -Force -ErrorAction Stop | Out-Null
                New-ItemProperty -Path $PolicyKey -Name DisableFileSyncNGSC -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
            }
        }
    }

    Test-OfficeExcludesOneDrive

    # --- Verification ---
    if (-not $DryRun) {
        foreach ($Target in ($Targets | Where-Object { $_.HasOneDrive })) {
            $Exe = Join-Path $Target.State.InstallDir 'OneDrive.exe'
            $Running = Get-CimInstance -ClassName Win32_Process -Filter "Name='OneDrive.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ExecutablePath -eq $Exe }
            if ($Running) {
                Write-Log "$($Target.Profile.Label): OneDrive is still running." -Level Error
                $Failed = $true
            } elseif (Test-Path -LiteralPath "$($Target.HiveRoot)\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe") {
                Write-Log "$($Target.Profile.Label): OneDrive is still registered as installed." -Level Error
                $Failed = $true
            }
        }
        if ($Blocked.Count -eq 0 -and ($MachineUninstallKeys | Where-Object { Test-Path -LiteralPath $_ })) {
            Write-Log 'The per-machine OneDrive install is still registered.' -Level Error
            $Failed = $true
        }
    }
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level Error
    $Failed = $true
}
finally {
    Dismount-UserHives
}

if ($Blocked.Count -gt 0) {
    Write-Log "Finished with $($Blocked.Count) profile(s) skipped: $(($Blocked | ForEach-Object { $_.Label }) -join ', '). Log: $LogPath" -Level Warning
    Stop-Transcript | Out-Null
    exit 1
}
if ($Failed) {
    Write-Log "Finished with errors. Log: $LogPath" -Level Error
    Stop-Transcript | Out-Null
    exit 1
}
Write-Log "$(if ($DryRun) { 'Dry run complete.' } else { 'OneDrive removed and blocked.' }) Log: $LogPath" -Level Success
Stop-Transcript | Out-Null
exit 0

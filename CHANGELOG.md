# Changelog

All notable changes to this repository are documented here. Entries are grouped by date where commit history allows, otherwise by theme.

## 2026-08-19

### Mac/Security - Get FileVault Status (update - publish to Ninja custom field)
- `Get FileVault Status.sh` now publishes the FileVault status (e.g. `FileVault is On`) to the `diskEncryptionStatus` Ninja custom field via `ninjarmm-cli`, in addition to printing it to stdout as before.
- Uses the correct CLI path (`/Applications/NinjaRMMAgent/programdata/ninjarmm-cli`), matching every other Mac script in the repo, and warns instead of failing if the CLI isn't found.
- Warns when not running as root (writes require root/SYSTEM) and prints the CLI's actual error message on a failed write instead of failing silently.
- Confirmed working via a live NinjaOne "Run as System" test.
- Updated `Mac/README.md` script index.

## 2026-07-08

### Windows/OS/Maintenance - Check for WSUS Settings and remove (new script)
- Adds `Check for WSUS Settings and remove.ps1` to detect WSUS registry settings (`HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate`), identify whether they're managed via Group Policy, and optionally remove them via a new `-RemoveWSUSSettings` switch (Ninja checkbox `removeWsusSettings`).
- GPO detection checks both domain SYSVOL and the local Group Policy folders on every device (previously servers only checked SYSVOL), so a true Local Group Policy Object is correctly identified instead of being reported as an unattributed "orphaned" registry setting.
- GPO detection also scans Group Policy Preferences `Registry.xml` files, not just Administrative Templates `Registry.pol` - some GPOs (e.g. SBS-era "Update Services Common Settings" policies) push WSUS values via Preferences.
- Fixed a bug where a GPO deliberately pushing blank/nullified `WUServer`/`WUStatusServer` values (a common way to overwrite a stale tattooed address) caused GPO detection to be skipped entirely, since it was mistaken for "nothing configured."
- Adds `Get-AppliedGPOs` (via `gpresult`) to cross-check the source when it can't be traced back to a specific GPO from the Registry.pol/xml scan; only entries whose name matches WSUS/Update/Patch are written to the custom field to stay under NinjaOne's ~200 character field limit, with the full list logged to console.
- After a successful removal, restarts `wuauserv`/`UsoSvc` so the Windows Update Agent drops any endpoint it already had cached in memory - without this, a patch scan run immediately after removal could still fail trying to reach the now-deleted server even though the registry was already clean.
- The custom field reports the end result of the run (post-removal state), while the console output shows the full before/after detail; a `Script Version` line is printed first so it's easy to confirm which revision actually ran on a given endpoint.
- Updated `Windows/README.md` script index.

## 2026-07-06

### Windows/Applications - Install WireGuard (update - per-user access, config delivery, registry fix)
- Added `-TargetUser` parameter (and `targetUser` Ninja script variable) to grant WireGuard tunnel management to one specific user instead of every user on the machine. When set, existing `Authenticated Users`/`Users` group membership on Network Configuration Operators is removed first so access is actually restricted to that user.
- `wireguardConfig` is now read via `Ninja-Property-Get` in addition to the `$env:wireguardConfig` script-variable override, so the organization custom field works without a separate script-variable mapping in the automation.
- Tunnel config delivery switched from `wireguard.exe /installtunnel` to the file-drop method: writes to a temp file first (avoids WireGuard's FileSystemWatcher reacting to a 0-byte file mid-write), copies it into `Data\Configurations\wg0.conf`, then waits up to 15s for the WireGuard Manager service to detect, encrypt (`wg0.conf.dpapi`), and import it.
- Fixed `LimitedOperatorUI` registry key being written to `WOW6432Node` instead of the native 64-bit hive when the host process is 32-bit (common for RMM agents) - now uses the `Microsoft.Win32.RegistryKey` API with an explicit `Registry64` view, with a readback verification step.
- Added `Test-UserExists`/`Show-LocalUsersList` to validate `-TargetUser` up front and fail fast with the local user list printed for troubleshooting if the name doesn't resolve.
- Updated `.NOTES` and `.PARAMETER` comment-based help to document the new parameter, custom-field auto-read, and new config path.

### Windows/Applications - Uninstall ScreenConnect (new script)
- Added `Uninstall ScreenConnect.ps1` to silently remove all installed ScreenConnect (ConnectWise Control) Client instances via NinjaRMM, targeting PowerShell 5.1+ (no `wmic`, no PS7-only cmdlets).
- Handles multiple simultaneous instances (each ScreenConnect Client install has its own "thumbprint" in its display name, e.g. "ScreenConnect Client (8f53c95c9d2e1234)") by enumerating the Uninstall registry (native + WOW6432Node) and looping per instance.
- Per instance: stops the matching service and sets it to Disabled, kills any running ScreenConnect processes, extracts the MSI product code from the UninstallString via regex, then runs `msiexec /x {guid} /qn /norestart` - no dialogs and no reboot, since end users may be actively on the machine.
- Sweeps for and removes leftover services, install directories (Program Files, Program Files (x86), ProgramData), and registry entries the MSI uninstaller leaves behind, then re-verifies and exits 1 if anything is still present so failures surface in Ninja rather than silently reporting success.
- Updated `Windows/README.md` script index.

## 2026-06-05

### RMM - Reinstall NinjaRMM Agent (improvement - MSI installer validation)
- Added robust multi-step verification of the downloaded NinjaOne MSI installer before beginning uninstallation.
- Verifies file existence, minimum size (>= 1KB), OLE Compound Document signature (D0 CF 11 E0 A1 B1 1A E1), and structural integrity via the Windows Installer (WindowsInstaller.Installer) COM object's OpenDatabase method.
- Aborts execution and preserves the existing agent if the downloaded file is corrupt, empty, or an HTML error page.

# Changelog

All notable changes to this repository are documented here. Entries are grouped by date where commit history allows, otherwise by theme.

## 2026-08-24

### RMM - Reinstall NinjaRMM Agent (major hardening, v2.0.0)

Investigated why the transfer succeeded on some endpoints but left others with **no agent at all**. Root-caused several distinct failure modes - each verified empirically on a real machine rather than assumed - and rewrote the script around them.

**Why the install silently never happened (the reported symptom):**

- **The scheduled task never fired on laptops.** `New-ScheduledTaskSettingsSet` defaults to `DisallowStartIfOnBatteries = True` and `StopIfGoingOnBatteries = True`, and the task inherited both - so a laptop on battery simply skipped the install. `StartWhenAvailable` also defaults to `False`, so a trigger missed because the device was off, asleep, or rebooting at the appointed minute was skipped permanently rather than run late. Now sets `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable`, adds an `AtStartup` trigger to cover a reboot during removal, and adds a 15-minute repetition across a 4-hour window so a transient failure self-heals. Verified by registering the task and reading the settings back.
- **The fixed 5-minute delay could race the cleanup.** Cleanup can exceed five minutes (30s + 10s sleeps, 2s per service, a hive load per user profile). If the task fired mid-cleanup, the *name-based* cleanup would delete the **brand-new** agent's service, directory, and registry keys - it had no way to tell the two instances apart. The install task now waits for an explicit `removal.done` signal, proceeds early once the incumbent agent has actually gone (covering the case where the parent script is killed by the agent teardown), and installs anyway on timeout rather than leaving the device bare. The delay is no longer load-bearing.
- **Nothing verified that the install worked.** The script exited `0` immediately after registering the task, so NinjaOne reported success unconditionally - and with the old agent already gone, nothing could report back. The install task now polls for the `NinjaRMMAgent` service, retries on failure, and only unregisters itself once the agent is confirmed present.

**Removal bugs that left a half-removed agent, which then blocks a fresh install:**

- **`$UninstallString.Split('X')[1]` was case-sensitive.** `/X{GUID}` worked, but a lowercase `/x{GUID}` yielded a 1-element array so `[1]` was `$null` - skipping the MSI uninstall entirely while still running the destructive file/service/registry cleanup, leaving the MSI product registration intact. That is the worst possible state to install over. Replaced with a GUID regex, verified against upper-case, lower-case, and path-containing-`X` forms.
- **Only the first of multiple agent registrations was uninstalled.** A real endpoint carried **two** `NinjaRMMAgent` uninstall entries with different product codes; `(...).UninstallString` returned an array and member enumeration silently kept only the first. A stray Windows Installer product record is NinjaOne's one documented cause of a reinstall refusing to proceed. All agent registrations are now uninstalled individually.
- **The 32-bit code path could never match anything** - it built the uninstall path without a trailing `\*`, so `Get-ItemProperty` read the parent key's own values (verified: 0 matches, versus 37 with the wildcard).
- **A 32-bit PowerShell host cannot see the native registry view** through the PS provider at all, so a natively-registered agent was invisible. Both views are now read explicitly via `OpenBaseKey`. This matters because the NinjaOne agent is itself a 32-bit application, so a Ninja-launched script can plausibly run 32-bit.
- **`pnputil` silently no-opped in a 32-bit host** - `System32` is redirected to `SysWOW64`, where `pnputil.exe` does not exist, so Ninja Remote's display driver was never removed. Now resolved through `Sysnative` when running 32-bit on 64-bit Windows.
- **Driver removal was locale-dependent.** It parsed `pnputil` output by the English field labels `Published Name` / `Provider Name`, which are translated on non-English Windows. It now matches the driver block on the `.inf` filename and takes the published name positionally, splits on `':'` with a limit of 2 so values containing a colon survive, and deletes each match individually instead of passing an array to `pnputil`.
- **The install-folder sweep was both too broad and too narrow.** Matching directory names against `Ninja` would have deleted a `NinjaDesktop` folder belonging to a separate product, while missing agent folders named after the customer's org and site (the agent installs to a path built from those names). Folders are now identified by *containing* `NinjaRMMAgent.exe`, discovered via fixed-depth wildcards rather than `-Recurse` so it costs about 4 seconds instead of scanning all of Program Files at the moment the machine is between agents.
- Scoped the MSI uninstall and the Windows Installer registry cleanup to the **agent** rather than anything matching `Ninja`. Other Ninja-branded products (an observed endpoint had `NinjaRMM Desktop Companion x64` in the native view) are now reported and left alone - deleting another product's installer records while leaving it installed would strand it, unable to be serviced or uninstalled.

**Download hardening.** The reported "corrupt download" problem is real, but narrower than assumed: `Invoke-WebRequest -OutFile` does *not* mangle binaries (that bug was `Invoke-RestMethod`). What does happen is that Windows PowerShell 5.1 carries an unfixed bug ([PowerShell#17931](https://github.com/PowerShell/PowerShell/issues/17931)) where a mid-transfer connection loss leaves a **partial file on disk and returns exit code 0 with no exception** - so on 5.1 the absence of an error is not evidence of a complete download. Fixed in PS 7; 5.1 is security-fix-only and will not receive it.

- Added a four-transport fallback chain with deliberately complementary failure modes: `curl.exe` (absent on Server 2016 and older; ignores the Windows proxy, so the WinINET proxy is now read and passed via `-x`; best stall detection via `--speed-limit`/`--speed-time`) then `HttpWebRequest` streaming copy, Chocolatey-style (honours the WinINET proxy; inspects `Content-Type` before writing a byte) then BITS (works fine under SYSTEM - `LocalSystem` is always considered logged on - but its defaults of a 600-second retry interval and a **14-day** retry timeout make a transient error look like a hang, so `-RetryTimeout` is capped) then `Invoke-WebRequest -UseBasicParsing` as a last resort. `--retry-all-errors` is probed rather than assumed, since it needs curl 7.71+ and Windows 10 1803 shipped 7.55.
- **Replaced the validation entirely, after measuring the old checks against deliberately damaged MSIs.** Magic bytes are a false negative for *every* truncation (the OLE header sits at offset 0 and survives any tail loss), and `WindowsInstaller.OpenDatabase` opened both a 99.9%-truncated file and a byte-flipped one, because the MSI tables sit at the front of the compound file while the bulk CAB payload is at the end - a file that opens cleanly as a database can still fail during `msiexec` extraction. The new ladder is: size floor, then `Content-Length` agreement (the check that directly defeats the 5.1 bug), then the OLE header, then **compound-file sector alignment** (a self-contained truncation detector needing neither network nor signature: an MSI is always a whole number of sectors, and an arbitrary cut almost never is), then **Authenticode** (the only check that caught all five damage cases, and it works on per-organization installers because the vendor signs the finished file - something no fixed published hash could do). `HashMismatch` is fatal; `NotSigned` and `UnknownError` only warn, since a revocation-check failure on a restricted network is not evidence of damage. Confirmed the live installer is signed by `CN=NinjaOne LLC`.
- On an OLE-header mismatch the first 512 bytes are logged as text. Proxy and web-filter block pages are commonly served as HTML with HTTP 200 and almost always name the vendor, which turns an unactionable "install failed" into "allowlist this URL". Content types are blacklisted (`text/*`) rather than allowlisted, because the NinjaOne CDN serves the non-standard `binary/octet-stream`.
- TLS is now raised additively with numeric literals (`-bor 3072 -bor 768`). The previous `[Net.SecurityProtocolType]::Tls12` assignment throws outright on .NET 4.0, where the enum member does not exist, and - worse - *replaced* the whole set on modern machines, disabling TLS 1.3.
- Confirmed the installer is roughly 59 MB (not 5-15 MB) and that `app.ninjarmm.com` issues a **307 redirect to `resources.ninjarmm.com`**, so proxy and AV allowlists need both hostnames; a partial allowlist blocking only the second hop is a plausible block-page cause. `Accept-Ranges: bytes` is honoured, so resume works.

**A bug introduced during this rewrite, recorded because the failure mode is instructive.** `Write-Log` used `Write-Output`, which writes to the *success pipeline* - so calling it from inside a value-returning function prepended every log line to that return value. `Test-InstallerFile` was handing its caller `@('log line', ..., $false)`: a non-empty array, which PowerShell evaluates as `$true`. That turned `if (-not (Test-InstallerFile ...))` into a no-op and **silently disabled the entire validation gate**. Caught when a `-DryRun` against the live endpoint reported success in five seconds with no validation output at all. Switched to `Write-Host` (still captured by NinjaOne, but off the pipeline) and suppressed a stray `$null` emitted by a COM `Execute()` call. Every boolean-returning function is now asserted to return a single clean `Boolean`.

**Other robustness and diagnosability changes:**

- Dropped `#Requires -RunAsAdministrator`: it is a PowerShell 4.0 feature and causes a confusing *parse-time* failure on PowerShell 3.0. Replaced with a runtime elevation check plus an explicit PowerShell 3.0 minimum, so an unsupported host gets a clear message instead of a syntax error.
- The script now refuses to start if the `ScheduledTasks` module is unavailable, rather than removing the agent and only then discovering it has no way to install the replacement.
- `$ErrorActionPreference` is `Stop` through preflight, download, and task registration - nothing is destroyed yet, so failing fast is safe - and is relaxed to `Continue` only once removal begins and best-effort cleanup becomes correct.
- Durable logging to `C:\ProgramData\RTT\NinjaAgentTransfer\`, replacing `Start-Transcript` in `%windir%\Temp`. It survives the agent teardown and is deliberately not cleaned up on failure. Preflight now records the PowerShell version, OS, process bitness, and identity - the variables that determine which failure modes apply. The MSI and the install helper live there too, and the helper is written as a readable `.ps1` rather than an opaque `-EncodedCommand`.
- The install task re-checks the MSI immediately before running it, since AV can quarantine a file *after* the download reported success.
- Added `-DryRun`, to validate the URL and survey a machine without changing anything, plus `-InstallDelayMinutes`, `-MaxRemovalWaitMinutes`, and `-RetryWindowHours`.
- Confirmed the scheduled-task approach is correct and should **not** be removed. The premise that NinjaOne had moved away from it was inverted: git history shows the task was *added* here (`bf7a5cc`) and the inline install *removed* (`75baeec`), and NinjaOne's own scripts never installed anything at all, being removal-only. Independent implementations converge on the same pattern, and NinjaOne's own GPO deployment tooling deploys via a scheduled task gated on service absence. Also documented NinjaOne's preferred alternative in `.NOTES`: having the incumbent MSP delete the device from their console triggers a silent uninstall that works even with Uninstall Prevention ON.
- Updated `RMM/README.md`, which still referenced the long-renamed `$RTTInstallerURL`.

## 2026-08-19

### HOWTO.md (new section - troubleshooting NinjaOne custom field writes)
- Added a "Troubleshooting NinjaOne Custom Field Writes" section after real-world testing showed a script finding the CLI and printing the right value but still not updating the field. That specific case turned out to be the stale `.app`-path bug fixed in `Get FileVault Status.sh`/`Get FileVault Key.sh` above, but the section documents the full set of causes so future cases can be diagnosed faster.
- Covers: running as root/SYSTEM being required (ninjarmm-cli/Ninja-Property-Set live in protected locations), field write permissions needing to be Read/Write for Automations, exact (case-sensitive) field name matching, read-only field types (Attachment, Device/Organization drop-downs), and the risk of scripts that suppress stderr from Ninja CLI calls hiding the real error.
- References NinjaOne's official CLI documentation.

### Windows/OS/Security - Get BitLocker Status (new script)
- Adds `Get BitLocker Status.ps1` to report the system drive's BitLocker encryption state and publish it to the `diskEncryptionStatus` Ninja custom field as `BitLocker <VolumeStatus>` (e.g. `BitLocker FullyEncrypted`, `BitLocker FullyDecrypted`), using `Get-BitLockerVolume`.
- Complements the existing `Get BitLocker Key.ps1`, which publishes the recovery key to a separate `diskEncryptionKey` field.
- Confirmed working via a live NinjaOne test run.
- Updated `Windows/README.md` script index.

### Mac/Security - Get FileVault Key (fix - wrong ninjarmm-cli path)
- Fixed `ninjarmm-cli` being invoked at `/Applications/NinjaRMMAgent.app/Contents/MacOS/ninjarmm-cli`, which does not exist on the Mac agent - confirmed failing in production (`No such file or directory`). Switched to the correct path (`/Applications/NinjaRMMAgent/programdata/ninjarmm-cli`) used by every other Mac script in the repo.
- The custom field write now skips quietly with a console warning if the CLI still can't be found, instead of the script erroring out.
- `ninja_set` now surfaces the actual `ninjarmm-cli` error on failure instead of swallowing stderr, so a bad field write is visible in the console output rather than looking identical to success.

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

---

## 2026-06-04

### RMM - Reinstall NinjaRMM Agent (improvement - download before uninstall + NJCliPSh cleanup)
- MSI is now downloaded at the top of the script, before the agent is touched. If the URL is unreachable or the download fails the script exits 1 immediately with no changes made to the machine. Previously a bad URL would orphan the device - agent removed, new agent never installed.
- `Register-InstallTask` simplified: removed the download logic from the task's embedded script. The task now just runs `msiexec /i <local path>` against the already-downloaded file, with no network dependency at fire time.
- Added cleanup of `$env:ProgramFiles\WindowsPowerShell\Modules\NJCliPSh` - the NinjaOne PowerShell module installed alongside the agent that was not previously removed.

### RMM - Reinstall NinjaRMM Agent (fix - PS5.1 service path fallback)
- Fixed install location fallback that used `Get-Service` and `BinaryPathName`; `BinaryPathName` is not a property of `ServiceController` in PowerShell 5.1/.NET Framework - it was added in PS7/.NET 5
- Replaced with `Get-CimInstance Win32_Service` and its `PathName` property, which works on PS3+ through PS7
- This fallback only fires when Ninja's main registry key is absent (partial/failed prior uninstall), but the path lookup was silently returning null in those cases

### RMM - Reinstall NinjaRMM Agent (refactor - install architecture)
- Removed the inline install path; the Scheduled Task is now the sole install path
- Previously the script tried to unregister the task and run `msiexec` directly if it survived the uninstall; this introduced a race condition - if cleanup took longer than 5 minutes the task could fire while the script was still running, resulting in a double install
- The task now handles the install in all cases; the script's job ends after cleanup
- Added self-unregistration to the task's script block so it removes itself from Task Scheduler after running
- Added a cancel/cleanup note to the `.NOTES` section explaining how to abort the install task before it fires

### RMM - Reinstall NinjaRMM Agent (fix - SYSTEM account URL access)
- Fixed 80070005 Access Denied when the scheduled task safety net tried to run `msiexec /i <URL>` as SYSTEM
- Root cause: the SYSTEM account uses WinHTTP, which does not inherit user-context proxy or authentication settings; passing a URL directly to msiexec as SYSTEM fails without a proxy configured for WinHTTP
- Fix: both the scheduled task action and the inline install path now download the MSI to `%windir%\Temp\NinjaAgentInstall.msi` via .NET `WebClient` (with TLS 1.2 forced) and then run `msiexec /i` against the local file path

---

## 2026-06-03

### RMM - Reinstall NinjaRMM Agent (fix - live test)
- Fixed crash in orphaned installer key check: inner `try/catch` with `-ErrorAction Stop` on `Get-ItemPropertyValue` was letting the terminating error escape to the outer handler in PowerShell 5.1; switched to `-ErrorAction SilentlyContinue` + null check and used `PSChildName` instead of `Name` for the GUID exclusion filter; wrapped the entire check in its own `try/catch` so any future failure here is a non-fatal warning
- Added Scheduled Task safety net: the Ninja scripting engine runs inside the Ninja process tree; when the MSI uninstaller removes the agent it terminates the script process before the install step can run; the script now registers a one-time SYSTEM-level Scheduled Task (fires T+5 min) before starting the uninstall; if the script survives it unregisters the task and runs `msiexec /i` directly for exit code checking; if killed the task fires as a fallback

### RMM - Reinstall NinjaRMM Agent (update)
- Rewrote to coding standards: added `#Requires -RunAsAdministrator`, comment-based help, `param()` block, `Write-Log` function with timestamps and severity levels, `try/catch` with explicit `exit 0`/`exit 1`, and `$ProgressPreference = 'SilentlyContinue'`
- Added `$RTTInstallerURL` configuration variable near the top of the script for direct execution without any additional setup - the partner MSP fills in the URL and deploys as-is
- Added Ninja script variable support: create a String variable named `installerUrl` in NinjaOne; its value is passed as `$env:installerUrl` and takes highest precedence
- Installer URL precedence: Ninja script variable > `-InstallerURL` parameter > `$RTTInstallerURL` hardcoded value
- Removed `Read-Host` prompt - script fails fast with exit 1 if no URL is available, which is correct for SYSTEM-level RMM execution
- Removed manual UAC re-launch block (replaced by `#Requires -RunAsAdministrator`)
- Removed global `$ErrorActionPreference = 'SilentlyContinue'`; scoped `-ErrorAction SilentlyContinue` to individual calls that are expected to fail on clean machines
- Moved `Remove-NRRegistryItems` function definition before first use
- Wrapped transcript in the main `try/catch` so it is always stopped on both success and failure paths
- Updated `RMM/README.md` script index

---

## 2026-05-22

### Windows - Configure Auto Logoff (fix)
- Fixed `autoLogoffInactiveUsers` checkbox not triggering task removal when unchecked
- Root cause: `Get-NinjaProperty` returns checkbox values as string `"0"`/`"1"`, not boolean. The removal condition only tested for `$false` and `"false"`, missing the `"0"` case
- Added `$v -eq '0'` to the removal condition

---

## 2026-05-20

### Windows - Configure Auto Logoff (new)
- Added `Configure Auto Logoff.ps1` to `Windows/OS/Security/`
- Registers a scheduled task (`RTT - Shared Device Auto Logoff`) using Windows Task Scheduler's built-in `IdleTrigger`; logs off the physical console session via `logoff console` after a configurable idle timeout
- Reads idle timeout from the `minutesToAutoLogoff` NinjaOne org-level integer custom field via `Get-NinjaProperty`; falls back to the `idleLogoffMinutes` script variable (legacy env var) and then the `-IdleMinutes` parameter default of 10
- Reads `autoLogoffInactiveUsers` NinjaOne device-level checkbox field; unchecked (`false`) forces task removal; null (never touched) is ignored so the org setting applies
- Setting `minutesToAutoLogoff` to 0 or passing `-IdleMinutes 0` removes the task
- Runs as SYSTEM; `cmd.exe` wrapper suppresses errors when no session is present so Task Scheduler does not report failure at the login screen
- `DisallowStartIfOnBatteries=false` and `StopIfGoingOnBatteries=false` ensure the task fires on laptops running on battery
- Idempotent: re-running updates the timeout by removing and re-registering the task
- Updated `Windows/README.md` script index

---

## 2026-05-15

### Windows - Install WireGuard (new)
- Added `Install WireGuard.ps1` to `Windows/Applications/`
- Installs WireGuard via winget (`WireGuard.WireGuard --scope machine`); falls back to downloading the latest architecture-appropriate MSI from https://download.wireguard.com/windows-client/ (parsed from the directory listing), with a secondary fallback to `wireguard-installer.exe`
- Sets `HKLM\Software\WireGuard\LimitedOperatorUI = 1` so members of "Network Configuration Operators" can manage tunnels without local admin rights
- Adds the built-in **Users** group itself (not its members) to "Network Configuration Operators" so all present and future users on the machine can manage WireGuard tunnels
- Optionally reads a WireGuard tunnel config from the `wireguardConfig` Ninja organization custom field (multi-line text, inherited at the device level), writes it to `C:\ProgramData\WireGuard\wg0.conf` with ACLs restricted to SYSTEM and Administrators, and registers it as a managed tunnel service via `wireguard /installtunnel`
- Updated `Windows/README.md` script index

---

## 2026-05-13

### Mac - Detect Antivirus (update - 524c7de)
- Added Avira detection (`/Applications/Avira Security.app`, `/Applications/Avira Antivirus Pro.app`, `/Library/Application Support/Avira`; processes: `Avira.ServiceHost`, `avira_daemon`, `AviraDaemon`)

### Windows - Detect Antivirus (update - dc3e918)
- Added five products to the service-based detection tier: Avira (`AntivirService`, `Avira.ServiceHost`), Comodo Internet Security (`cmdagent`, `CmdVirth`), Panda Dome (`PSANToManager`, `NanoServiceMain`), Emsisoft (`a2service`), 360 Total Security (`ZhuDongFangYu`)
- Updated `.NOTES` block to list the new products

### Windows - Detect Antivirus (fix - 14b3fe5)
- Fixed script producing no output (FAILURE) on Windows Server 2019 Standard
- Root cause: `Write-Log` used `Write-Error` for Error-level messages; with `$ErrorActionPreference = 'Stop'` set globally, calling `Write-Error` inside the outer `catch` block threw a second terminating exception that escaped unhandled, killing the script with zero output
- Fix: replaced `Write-Error` with `[Console]::Error.WriteLine` - writes to stderr without triggering PowerShell's error-action machinery

### Windows - Detect Antivirus (new)
- Added `Detect Antivirus.ps1` to `Windows/OS/Security/`
- Tier 1: queries `root\SecurityCenter2` WMI (Windows Security Center) on workstations; decodes the packed `productState` field to determine active vs. inactive registration; skips built-in Windows Defender entries
- Tier 2: service-based detection for 19 known AV/EDR products using `Get-Service`; runs on Windows Server (no WSC) and as a fallback on workstations when WSC returns no active products
- Tier 3: Windows Defender fallback via `Get-MpComputerStatus` (available on both client and server); reports real-time protection state, `AMRunningMode` (Normal/Passive/EDR Block Mode), and signature version/date; detects Passive mode as a signal that an unrecognised primary AV is present
- Writes the result to a NinjaOne custom device field (default `installedAntivirus`) via `Set-NinjaProperty`; field name overridable via `NINJA_FIELD_NAME` env var
- Updated `Windows/README.md` script index

### Mac - Detect Antivirus (new)
- Added `Detect Antivirus.sh` to `Mac/Security/`
- Scans for known third-party AV/EDR products (BitDefender, Sophos, CrowdStrike, SentinelOne, Microsoft Defender, Malwarebytes, ESET, Webroot, Norton/Symantec, McAfee, Trend Micro, Avast, AVG, Kaspersky, Huntress, Cortex XDR, Carbon Black, Cylance, Trellix, WithSecure) by combining application bundle / library path checks with a single `ps` snapshot to confirm the main daemon is running
- A product is flagged "Active" only when both install footprint and process are present; install-only matches are recorded but not reported as the active AV
- Falls back to Apple XProtect when no third-party AV is active, reporting XProtect data version and last-update date from `XProtect.meta.plist`, plus presence of XProtect Remediator
- Writes the result to a NinjaOne custom device field (default `installedAntivirus`, overridable via `NINJA_FIELD_NAME` env var) using `/Applications/NinjaRMMAgent/programdata/ninjarmm-cli`
- Requires root; logs a structured summary to stdout for Ninja activity capture
- Updated `Mac/README.md` script index

---

## 2026-05-08

### Windows - Enable and Start Service (new)
- Added `Enable and Start Service.ps1` to `Windows/OS/Maintenance/`
- For each named service: sets startup type to Automatic if Disabled, starts if stopped, restarts if already Running
- Accepts `Name` (comma-separated or array), `Attempts`, and `WaitTimeInSecs` parameters with matching NinjaRMM env var overrides
- Retry loop polls the service status after each start attempt and re-tries `Start-Service` up to the configured attempt count before reporting failure
- Supports both service `Name` and `DisplayName` for lookup
- Updated `Windows/README.md` script index

---

## 2026-04-24

### Google - Audit Google Groups (fixes and tree view)
- **Fixed Cloud Identity label parsing.** GAM emits one boolean column per label (`labels.cloudidentity.googleapis.com/groups.security`, `labels.cloudidentity.googleapis.com/groups.discussion_forum`) holding `True` when applied, not a single serialized `labels` column. The previous regex match returned `Unknown` for every group; now `Type` (`Security` / `Email` / `Both` / `Unknown`) is correctly assigned across the tenant
- **Pared `Summary.txt` down to statistics only.** Sections now cover group type counts, membership totals broken out by role and member type, and risk flag tallies. Per-group risk drill-downs and external-member listings moved into the new `GroupTree.txt`
- **Added `GroupTree.txt`.** A visual companion to `GroupMembers.csv`: every group rendered as a heading (`[S]` / `[E]` / `[B]` / `[?]` type tag, name, email, description), risk flags rendered inline (`!! NO OWNERS | PUBLIC POST`), then every member listed beneath sorted OWNER -> MANAGER -> MEMBER. External members marked with `*`, nested members annotated with `(nested via parent-group@domain)`. Mirrors the `FolderTree.txt` pattern from the Drive audit script
- Updated `Google/README.md` script index and CHANGELOG to reflect the four-output structure (`GroupMembers.csv`, `Groups.csv`, `GroupTree.txt`, `Summary.txt`)

### Google - Audit Google Groups (update)
- Reworked output focus from counts to specific names and addresses, per vCIO request for "Group Name, email and Members"
- `GroupMembers.csv` is now the primary export: columns are `GroupName`, `GroupEmail`, `GroupType`, `MemberName` (display name), `MemberEmail`, `Role`, `MemberType`, `Status`, `Internal`, `External`, `NestedVia`
  - `MemberName` populated by adding `name` to the `gam print group-members fields` list
  - `NestedVia` populated from GAM's `subGroupEmail` column when `-ExpandNestedGroups` is used, identifying the direct-member group through which a transitively included user comes
  - `GroupName` and `GroupType` denormalized onto every row so the CSV stands alone without requiring a join to `Groups.csv`
- `Groups.csv` now includes `OwnerEmails`, `ManagerEmails`, and `ExternalMemberEmails` columns with semicolon-delimited address lists alongside the existing count columns
- `Summary.txt` external-members section now drills down to list specific external member emails under each affected group (with display name, role, and NestedVia when applicable), not just group names
- Added `Add-ExternalMemberSection` helper that produces the detailed per-group/per-member breakdown in `Summary.txt`
- Updated `Add-RiskSection` to display group display name + email rather than just the email address
- Added `Google/README.md` Future Enhancements section documenting six ideas for later: external-domain frequency table, permission impact for security groups, diff/change detection, nesting depth report, mail-flow risk overlay, owner-less stale group cleanup

### Google - Audit Google Groups (new)
- Added `Audit Google Groups.ps1` for tenant-wide Google Workspace group security audits
- Reuses the workspace-selection, transcript logging, internal-domain-list, and `Invoke-GamStream` heartbeat patterns from `Audit Shared Drive Folder.ps1`
- Inventories every group in three GAM calls:
  - `gam print groups` for email, name, description, member counts
  - `gam print cigroups labels` to classify each group as **Security**, **Email** (discussion forum / distribution), or **Both** based on Cloud Identity labels (`cloudidentity.googleapis.com/groups.security` and `cloudidentity.googleapis.com/groups.discussion_forum`)
  - `gam print groups settings` for access-control fields (`whoCanJoin`, `whoCanPostMessage`, `whoCanViewMembership`, `allowExternalMembers`, `archiveOnly`, `messageModerationLevel`); skippable via `-SkipSettings`
  - `gam print group-members` (optionally `recursive` via `-ExpandNestedGroups`) for membership rows
- Computes per-group internal vs external member counts using the configured comma-separated internal domain list (alias domains supported)
- Emits eight risk flag columns: `Risk_NoOwners`, `Risk_HasExternalMembers`, `Risk_ExternalOwners`, `Risk_PublicJoin`, `Risk_PublicPost`, `Risk_ExternalsAllowed`, `Risk_SecurityWithExternal`, `Risk_HasNestedGroups`
- Outputs three files: `Groups.csv` (one row per group), `GroupMembers.csv` (one row per (group, member) with internal/external classification), and `Summary.txt` (human-readable risk highlights with up to 50 examples per category)
- Updated `Google/README.md` script index

---

## 2026-04-18

### Google - Audit Shared Drive Folder
- **Major reliability rework** for very large Drive trees that previously appeared to hang for hours
- Replaced the single buffered `gam print diskusage` + `gam print filelist` walks (which held the full result set in memory and produced no output until completion) with a streaming, checkpointed, per-subtree architecture:
  - **Step 1**: enumerate the audited folder's immediate children with one fast API call to build a work list
  - **Step 2**: walk each child subtree independently with `gam print filelist`, streaming each row to a per-subtree CSV in `_subtrees/` as it arrives; print a heartbeat every 30 seconds with rows-written and rows-per-minute
  - **Step 2.5**: merge per-subtree CSVs into the unified `FileDetails.csv`, deduplicating by file ID
  - **Step 2.6**: derive `FolderDetails.csv` locally in PowerShell from the file list (eliminates the second slow API walk that the prior version's diskusage step performed)
- Added `audit.state.json` checkpoint file written after every subtree completes; tracks per-subtree status (pending / in-progress / done / failed)
- Added `-Resume` and `-Restart` switches; when neither is supplied and a state file is detected, the script prompts interactively (Yes / No / Quit) so re-running against the same OutputDir never silently destroys data
- An interrupted run (Ctrl+C, reboot, network drop) leaves a `.partial` file behind so the partially-streamed subtree can be re-walked on resume without confusion
- Console output during long walks now shows per-subtree progress (`[5/120] FolderName`, ID, row count, heartbeat) instead of going silent for hours
- Verified Google Drive API limits: 12,000 queries/60s/user (no daily cap); GAM walks one folder per API call, so wall-clock time scales with folder count, not file count

---

## 2026-04-17

### Google - Audit Shared Drive Folder
- Added early detection for resource key-protected Google Drive folders (pre-September 2021 link-shared items)
- GAM7 does not send the `X-Goog-Drive-Resource-Keys` HTTP header required by the Drive API v3 for these folders, causing all API calls to return 404 Not Found
- When a resource key is detected, the script prompts for the folder owner's email, verifies access, and switches the impersonation target so the audit can proceed without re-running
- Clarified the user email prompt to indicate GAM will impersonate the supplied account
- Affects both folder ID (option 2) and Shared Drive ID (option 3) input paths

---

## 2026-04-13

### Repository — Design spec and engineering principles
- Added "Verify, never assume" and "Prefer platform APIs" to Engineering Principles in `.github/copilot-instructions.md`
- Added verified Graph Authentication section documenting interactive browser auth as the recommended flow for technician scripts, with source references to Microsoft Learn
- Corrected Required Modules table: `Microsoft.Graph` → `Microsoft.Graph.Authentication` (only module needed for REST calls via `Invoke-MgGraphRequest`)
- Added Version Control and Changelog section requiring per-script commits and changelog entries
- Updated Definition of Done to include per-script commits and changelog updates

### Microsoft 365 — Get Mailbox Usage (Reporting)
- **Rewrote to v3.0** — replaced per-user Graph SDK enumeration with four bulk report APIs (`getOffice365ActiveUserDetail`, `getMailboxUsageDetail`, `getOneDriveUsageAccountDetail`, `userRegistrationDetails`), reducing from thousands of API calls to four
- Now requires only `Microsoft.Graph.Authentication` (previously loaded all 38 `Microsoft.Graph` submodules, ~1.5 GB)
- Switched from device code auth to interactive browser auth
- Replaced `exit` with `throw` for fatal errors; removed dot-source guard
- Added `$ErrorActionPreference = 'Stop'` and proper `try/catch` structure

### Microsoft 365 — Get MFA Status Report (Security and Compliance)
- Replaced `Install-Module Microsoft.Graph` (all 38 submodules) with targeted installs of only `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, and `Microsoft.Graph.Identity.SignIns`
- Switched from `-UseDeviceAuthentication` to interactive browser auth
- Replaced all `exit` calls with `throw`
- Removed redundant `if ($PSVersionTable...)` version check (already handled by `#Requires -Version 7`)
- Added comment-based help block (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`)
- Added `$ErrorActionPreference = 'Stop'`

### Microsoft 365 — Get Immutable ID (Entra ID)
- Replaced `Install-Module Microsoft.Graph` (all 38 submodules) with `Install-Module Microsoft.Graph.Users` (only module needed)
- Switched from `-UseDeviceAuthentication` to interactive browser auth
- Replaced all `exit` calls with `throw`; removed trailing `exit 0`
- Updated help block to reflect corrected module and auth method

### Microsoft 365 — Get Message Trace (Exchange Online)
- Fixed module detection: replaced fragile `Get-InstalledModule` (throws if not installed) with `Get-Module -ListAvailable`
- Added `-Force -Scope CurrentUser -AllowClobber` to `Install-Module` for non-interactive install
- Removed `Set-ExecutionPolicy RemoteSigned` (unnecessary, fails without elevation)
- Removed redundant version check; replaced `exit` with `throw`
- Added comment-based help block

### Microsoft 365 — Get Mailbox Rules and Forwards (Exchange Online)
- Removed pinned `-RequiredVersion 1.0.1` on ExchangeOnlineManagement (years outdated)
- Fixed module detection: replaced fragile `Get-InstalledModule` with `Get-Module -ListAvailable`
- Removed `Set-ExecutionPolicy RemoteSigned`
- Removed redundant version check; replaced `exit` with `throw`
- Added comment-based help block

### Microsoft 365 — Import AppRiver Users (Exchange Online)
- Fixed module detection: replaced `Get-Module` (without `-ListAvailable`, only checks loaded modules) with `Get-Module -ListAvailable`
- Added `-Force -Scope CurrentUser -AllowClobber` to `Install-Module`
- Added `-ErrorAction Stop` to `Import-Module`
- Removed `Set-ExecutionPolicy RemoteSigned`
- Removed redundant version check and `exit`
- Added comment-based help block

### Microsoft 365 — Download Message Trace Reports (Exchange Online)
- Fixed module detection: replaced `Get-InstalledModule` with `Get-Module -ListAvailable`
- Removed `Set-ExecutionPolicy RemoteSigned`
- Replaced `exit` calls with `throw` and `return`
- Removed redundant version check
- Added comment-based help block

### Microsoft 365 — Fix Message Trace Encoding (Exchange Online)
- Replaced all `exit 1` calls with `throw`
- Removed redundant version check
- Added comment-based help block

### Microsoft 365 — Create Contacts from CSV (Exchange Online)
- Replaced `exit` calls with `throw`
- Removed redundant version check
- Added comment-based help block

### Microsoft 365 — Add Users to Distribution List (Exchange Online)
- Replaced `exit` calls with `throw`
- Removed redundant version check
- Added comment-based help block

### Microsoft 365 — Configure AppRiver Inbound Limit (Exchange Online)
- Replaced all `exit 1` calls with `throw`
- Removed redundant version check
- Added comment-based help block

### Microsoft 365 — Configure AppRiver Bypass Filtering (Exchange Online)
- Replaced `exit 1` with `throw`
- Removed redundant version check
- Added comment-based help block

### Microsoft 365 — Configure Phinsec Phishing Simulation (Security and Compliance)
- Replaced all `exit 1` calls with `throw`
- Removed redundant version check
- Added comment-based help block

### Microsoft 365 — Configure Defendify Phishing Simulation (Security and Compliance)
- Replaced `exit 1` with `throw`
- Fixed broken module version check: `Get-Module` (without `-ListAvailable`) always returned null; replaced with proper `Get-Module -ListAvailable` pattern
- Removed unnecessary `Find-Module` / `Update-Module` version comparison logic
- Added `-Scope CurrentUser -AllowClobber -ErrorAction Stop` to `Install-Module`
- Removed redundant version check
- Added comment-based help block

### Google — Initialize GAM
- Replaced all `exit 1` calls with `throw`; replaced `exit 0` with `return` or natural script end
- No other changes needed (already had proper help block and no M365 module concerns)

### Google — Audit Shared Drive Folder
- Replaced all `exit 1` calls with `throw`; replaced `exit 0` with natural script end
- No other changes needed (already had proper help block)

---

## [Unreleased] — 2026-03-31

### Repository restructure and documentation
- Renamed ~100 scripts to the `Action Product.ext` naming convention
- Renamed `Office 365/` folder to `Microsoft 365/`
- Reorganized `Windows/` into subfolders: `Applications/`, `CVE Mitigations/`, `OS/Maintenance/`, `OS/Migration/`, `OS/Networking/`, `OS/Reporting/`, `OS/Security/`, `OS/User Management/`
- Reorganized `Mac/` into subfolders: `Applications/`, `OS/`, `Security/`
- Reorganized `Linux/` into subfolders: `Agents/`, `Tools/`
- Reorganized `Microsoft 365/` into subfolders: `Entra ID/`, `Exchange Online/`, `Reporting/`, `Security and Compliance/`
- Removed duplicate and superseded scripts (7 files deleted)
- Replaced all EOL `MSOnline` and `AzureAD` cmdlets with `Microsoft.Graph` equivalents across M365 scripts
- Added `HOWTO.md` — guide for finding, downloading, and running scripts
- Added `SECURITY.md` — credential policy and responsible disclosure
- Added `CONTRIBUTING.md` — naming convention, script structure standards, no-secrets checklist, submission process
- Rewrote root `README.md`; added script index tables to all folder READMEs
- Updated `.github/copilot-instructions.md` with naming schema, folder structure, and README maintenance rules

---

## 2026-03-04

### Mac — Install Huntress Agent
- Synced `Install Huntress Agent.sh` from Huntress' GitHub repository (3/4/2026)
- Added reinstall support and network extension auto-install
- Retained NinjaOne RMM custom field support from prior version (`c70a2d7`, `607c817`)

---

## 2026-03

### Mac — Detect MDM Enrollment
- New script: detects MDM enrollment across Mosyle, NinjaOne MDM, Apple Business Essentials, and other platforms (`6fabff6`)
- Improved Apple Business Essentials detection logic (`ad8894e`)

### Windows — Get Windows License Info
- New script: reports Windows activation status and license key details (`a0fb1e6`)

### Windows — Set Windows License Key
- Switched from `.exe` to `.vbs` invocation for broader system compatibility (`5fe6373`)
- Initial version added (`598d8d5`)

### Datto — Uninstall Datto Endpoint Backup
- New script: silently uninstalls the Datto Endpoint Backup for PCs agent (`3c6991a`)

---

## 2026-02

### Microsoft 365 — Authentication overhaul (all scripts)
- Required PowerShell 7 across all M365 scripts with a clear error and download link if running on 5.1 (`b22b3ab`)
- Fixed auth: replaced `-Device` flag (PS7-only) with `-DisableWAM` for PowerShell 5.1 compatibility (`47210b5`)
- Fixed WAM window handle error: switched to device code flow across all M365 scripts (`c696690`)
- Fixed module install failure on machines with outdated `PowerShellGet` (`fc4bda5`)

### Microsoft 365 — Get MFA Status Report
- Retooled from EOL `MSOnline` cmdlets to `Microsoft.Graph`; significantly expanded output (`91854c0`)

### Microsoft 365 — Configure AppRiver Inbound Limit
- Added user prompt for additional IPs and automatic conversion to `/32` subnets (`ac554fe`)
- Fixed module install reliability (`fc4bda5`)

### Microsoft 365 — Download Message Trace Reports / Fix Message Trace Encoding
- Improved M365 output parsing and CSV encoding handling (`07b5961`)

---

## 2025 and earlier

### Microsoft 365 — Exchange Online
- Added `Add Users to Distribution List` script (`b649bfc`)
- Added `Create Contacts from CSV` script (`ac48afb`)
- Added `Get Message Trace` script (`f0402d7`)
- Added `Download Message Trace Reports` and `Fix Message Trace Encoding` scripts (`c0d2d54`, `d656706`)
- Updated `Get Mailbox Rules and Forwards` to include console output in addition to CSV (`292ffee`)
- Added `Get Mailbox Usage` script — iterated through multiple versions (`2dd713c`, `954fb2a`, `c7b1bd1`, `0516e3b`, `d8a2adc`)
- Added `Import AppRiver Users` script; converted from deprecated component to EXO (`bc31cda`)
- Added `Configure AppRiver Bypass Filtering` script (`2b69cc8`, `3de7cf4`)
- Added `Configure AppRiver Inbound Limit` script (`dc6d59d`)
- Added `Configure Defendify Phishing Simulation` script
- Added `Configure Phinsec Phishing Simulation` script — iterated through multiple versions (`1973ca6`, `46d03b0`, `66e4ab9`, `62ab64c`)
- Added `Get Immutable ID` script

### Windows — Applications
- Added `Repair Microsoft Defender` script (`9bca5bb`)
- Added `Install ConnectSecure Agent` script (`d1fb311`, `992ece4`)
- Added `Remove Unwanted UWP Apps` script — expanded UWP list to include preinstalled Office apps (`221e78f`)
- Added `Get Application Version` script; updated for NinjaOne custom field output (`3faa957`, `7a6d89d`)
- Added `Install AnyDesk` and `Uninstall AnyDesk` scripts (`8d6f7b3`)
- Added `Install Dropbox` and `Uninstall Dropbox` scripts (`7b93d1f`)
- Added `Install AnyConnect` script (`08b4cb7`)
- Added `Install Splashtop SOS` script (`7f1838d`)
- Added `Remove Dell OEM Software` script (`87e17b0`)
- Added `Uninstall Sophos Endpoint` script (`9da8337`)
- Added `Uninstall Webroot` script (`de45195`)

### Windows — OS
- Added `Enable BitLocker` script (`300c880`)
- Added `Get BitLocker Key` script; secured key from stdout (`726585f`, `e8e818c`)
- Added `Get Share Permissions` script (`fc1a8ec`)
- Added `Get Files by Type` script (`0138f68`)
- Added `Audit RMM Group Policies` script (`eea6efe`)
- Added `Promote User to Local Admin` script (`5109d19`, `c048319`)
- Added `Audit Local Admin Users` script — added NinjaOne output (`0a546bd`)
- Added `Disable Offline Files`, `Sync Time to NTP`, `Cleanup Old Windows Versions` scripts (`b3ce1aa`)
- Added `Cleanup Intune MSI Cache` script (`afdcf31`)
- Added `Schedule Check Disk`, disk management, and scan/repair scripts (`fd659cb`)
- Added `Cleanup Driver Cache` and `Cleanup Old Drivers` scripts (`17d5f84`)
- Added `Rebuild Windows Search Index` script
- Added `Rebuild WMI Repository` script

### Mac
- Added `Install BitDefender GravityZone` script (`00ec129`, `9bbd3fa`)
- Added `Install ConnectSecure Agent` script (`d1fb311`)
- Added `Create Admin User` script (`3bd155f`, `9c9a665`)
- Added `Create Desktop Shortcut` script (`ef3197e`)
- Added `Get FileVault Status` and `Get FileVault Key` scripts
- Added `Audit Admin Users` script (`381cb90`)

### Linux
- Added `Install ConnectSecure Agent` script — added agent/curl pre-checks (`0ef5ee2`, `9410a90`, `7f01f8b`)
- Added `Get GeoIP Location` script (`b8d950c`)
- Added `Ping IP Addresses` script (`b3ce1aa`)
- Added `Scan MX Records` script (`37d3c0b`)
- Added `Scan VPN Connections` script (`f8930dc`)
- Added `Download File List` script
- Expanded `Linux/README.md` command reference (`4dfa860` and others)

### RMM
- Added `Set Organization UDF from Hostname` script (`b3ce1aa`)
- Added `Reinstall NinjaRMM Agent` script

### Datto
- Added `SaaS Protection Bulk Seat Change` (Python) script — initial draft (`a1784ab`)

### IT Glue
- Added `Format Import Template` Python script (`895d0d0`)
- Added `Download IT Glue Export` script

### Misc
- Added `Generate Huntress Site Key` Python script — moved from `_Customer/` to `Misc/` (`e3d7a8d`, `7b2f545`, `b4f1691`)

### Repository maintenance
- Added `.github/copilot-instructions.md` with AI agent framework (`ebb3d5a`)
- Expanded `.gitignore` to cover common OS and IDE files (`fb694ba`, `b8e3c61`)

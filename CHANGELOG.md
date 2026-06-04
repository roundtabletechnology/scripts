# Changelog

All notable changes to this repository are documented here. Entries are grouped by date where commit history allows, otherwise by theme.

---

## 2026-06-04

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

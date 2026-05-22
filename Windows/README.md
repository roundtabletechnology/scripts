# Windows

## Table of Contents

- [Scripts](#scripts)
  - [Applications](#applications)
  - [CVE Mitigations](#cve-mitigations)
  - [OS — Maintenance](#os--maintenance)
  - [OS — Migration](#os--migration)
  - [OS — Networking](#os--networking)
  - [OS — Reporting](#os--reporting)
  - [OS — Security](#os--security)
  - [OS — User Management](#os--user-management)
- [Command Reference](#command-reference)
  - [Filesystem Operations](#filesystem-operations)
  - [System Functions](#system-functions)
  - [Network](#network)
  - [User Functions](#user-functions)
  - [References](#references)

---

## Scripts

Scripts are organized into subfolders by function. For guidance on downloading and running any script, see [HOWTO.md](../HOWTO.md).

### Applications

| Script | Description |
|---|---|
| [Cleanup Dell SupportAssist Snapshots.ps1](Applications/Cleanup%20Dell%20SupportAssist%20Snapshots.ps1) | Removes accumulated Dell SupportAssist snapshot files to recover disk space |
| [Cleanup MS Teams Cache.ps1](Applications/Cleanup%20MS%20Teams%20Cache.ps1) | Clears the Microsoft Teams local cache to resolve performance and login issues |
| [Cleanup Outlook OST Files.ps1](Applications/Cleanup%20Outlook%20OST%20Files.ps1) | Removes stale Outlook OST files for users no longer on the machine |
| [Cleanup QuickBooks Update Cache.ps1](Applications/Cleanup%20QuickBooks%20Update%20Cache.ps1) | Deletes cached QuickBooks update files |
| [Cleanup UniFi Controller MongoDB.bat](Applications/Cleanup%20UniFi%20Controller%20MongoDB.bat) | Shrinks the MongoDB database used by the UniFi controller |
| [Configure CCH Engagement SQL.bat](Applications/Configure%20CCH%20Engagement%20SQL.bat) | Configures SQL Server settings required for CCH Engagement |
| [Configure Chrome Updates.bat](Applications/Configure%20Chrome%20Updates.bat) | Configures Google Chrome update policy via registry |
| [Configure FortiClient VPN.ps1](Applications/Configure%20FortiClient%20VPN.ps1) | Deploys FortiClient VPN configuration |
| [Enable Outlook Meeting Copy.bat](Applications/Enable%20Outlook%20Meeting%20Copy.bat) | Enables the copy-to-calendar feature for Outlook meeting responses |
| [Get Application Version.ps1](Applications/Get%20Application%20Version.ps1) | Reports the installed version of a specified application |
| [Get Datto Cloud Continuity Logs.ps1](Applications/Get%20Datto%20Cloud%20Continuity%20Logs.ps1) | Retrieves Datto Cloud Continuity agent logs for diagnostics |
| [Install AnyConnect.bat](Applications/Install%20AnyConnect.bat) | Installs Cisco AnyConnect VPN client |
| [Install AnyDesk.ps1](Applications/Install%20AnyDesk.ps1) | Silently installs AnyDesk remote access |
| [Install BitDefender GravityZone.ps1](Applications/Install%20BitDefender%20GravityZone.ps1) | Installs the BitDefender GravityZone endpoint agent |
| [Install ConnectSecure Agent.ps1](Applications/Install%20ConnectSecure%20Agent.ps1) | Installs the ConnectSecure (CyberCNS) vulnerability scanning agent |
| [Install Datto Endpoint Backup.ps1](Applications/Install%20Datto%20Endpoint%20Backup.ps1) | Installs the Datto Endpoint Backup for PCs agent |
| [Install Dialpad.ps1](Applications/Install%20Dialpad.ps1) | Silently installs the Dialpad softphone client |
| [Install Dropbox.ps1](Applications/Install%20Dropbox.ps1) | Silently installs Dropbox |
| [Install Google Drive File Stream.ps1](Applications/Install%20Google%20Drive%20File%20Stream.ps1) | Installs Google Drive for Desktop |
| [Install JumpCloud Agent.ps1](Applications/Install%20JumpCloud%20Agent.ps1) | Installs the JumpCloud directory agent using a connect key |
| [Install MSI Package.ps1](Applications/Install%20MSI%20Package.ps1) | Generic silent MSI installer — accepts path or URL and optional install arguments |
| [Install NordLayer VPN.ps1](Applications/Install%20NordLayer%20VPN.ps1) | Installs the NordLayer business VPN client |
| [Install PowerShell.bat](Applications/Install%20PowerShell.bat) | Installs PowerShell 7 via winget |
| [Install Splashtop SOS.ps1](Applications/Install%20Splashtop%20SOS.ps1) | Installs Splashtop SOS remote support client |
| [Install WireGuard.ps1](Applications/Install%20WireGuard.ps1) | Installs WireGuard VPN client via winget or direct MSI download, enables limited non-admin tunnel management, and optionally deploys a tunnel config from a Ninja custom field |
| [PreStage JumpCloud Migration.ps1](Applications/PreStage%20JumpCloud%20Migration.ps1) | Prepares a device for JumpCloud migration before agent installation |
| [Remove Dell OEM Software.ps1](Applications/Remove%20Dell%20OEM%20Software.ps1) | Removes Dell bloatware and OEM preinstalled applications |
| [Remove HP Bloatware.ps1](Applications/Remove%20HP%20Bloatware.ps1) | Removes HP bloatware and OEM preinstalled applications |
| [Remove HP Wolf Security.vbs](Applications/Remove%20HP%20Wolf%20Security.vbs) | Removes HP Wolf Security when the standard uninstaller fails |
| [Remove Unwanted UWP Apps.ps1](Applications/Remove%20Unwanted%20UWP%20Apps.ps1) | Removes a configurable list of built-in Windows UWP apps |
| [Repair Microsoft Defender.ps1](Applications/Repair%20Microsoft%20Defender.ps1) | Re-registers and repairs a broken Microsoft Defender installation |
| [Start JumpCloud Migration.ps1](Applications/Start%20JumpCloud%20Migration.ps1) | Executes the JumpCloud migration workflow after prestaging |
| [Uninstall AnyDesk.ps1](Applications/Uninstall%20AnyDesk.ps1) | Silently uninstalls AnyDesk |
| [Uninstall ConnectWise.ps1](Applications/Uninstall%20ConnectWise.ps1) | Removes ConnectWise Manage or ConnectWise Control agent |
| [Uninstall Datto RMM Agent.bat](Applications/Uninstall%20Datto%20RMM%20Agent.bat) | Uninstalls the Datto RMM (formerly Autotask) agent |
| [Uninstall Dropbox.ps1](Applications/Uninstall%20Dropbox.ps1) | Silently uninstalls Dropbox |
| [Uninstall ESET Antivirus.bat](Applications/Uninstall%20ESET%20Antivirus.bat) | Removes ESET endpoint antivirus |
| [Uninstall Huntress.bat](Applications/Uninstall%20Huntress.bat) | Removes the Huntress agent |
| [Uninstall Malwarebytes.ps1](Applications/Uninstall%20Malwarebytes.ps1) | Silently uninstalls Malwarebytes |
| [Uninstall Out-N-About.bat](Applications/Uninstall%20Out-N-About.bat) | Removes Out-N-About time tracking software |
| [Uninstall Sage Timeslips.bat](Applications/Uninstall%20Sage%20Timeslips.bat) | Removes Sage Timeslips |
| [Uninstall SonicWall Global VPN.ps1](Applications/Uninstall%20SonicWall%20Global%20VPN.ps1) | Silently uninstalls the SonicWall Global VPN client |
| [Uninstall Sophos Endpoint.ps1](Applications/Uninstall%20Sophos%20Endpoint.ps1) | Removes Sophos Endpoint using the Sophos uninstaller |
| [Uninstall Webroot.bat](Applications/Uninstall%20Webroot.bat) | Removes the Webroot SecureAnywhere agent |

### CVE Mitigations

| Script | Description |
|---|---|
| [Detect CVE FireEye Compromise.ps1](CVE%20Mitigations/Detect%20CVE%20FireEye%20Compromise.ps1) | Checks for indicators of the FireEye/SolarWinds supply chain compromise |
| [Mitigate CVE-2020-1350 DNS.bat](CVE%20Mitigations/Mitigate%20CVE-2020-1350%20DNS.bat) | Applies the registry workaround for the Windows DNS Server SIGRed vulnerability |
| [Mitigate CVE-2021-3922 Lenovo.ps1](CVE%20Mitigations/Mitigate%20CVE-2021-3922%20Lenovo.ps1) | Applies mitigation for the Lenovo ImController privilege escalation vulnerability |
| [Mitigate CVE-2022-30190 Follina.ps1](CVE%20Mitigations/Mitigate%20CVE-2022-30190%20Follina.ps1) | Disables the MSDT URL protocol handler to mitigate the Follina vulnerability |
| [Mitigate Log4j APC PowerChute.ps1](CVE%20Mitigations/Mitigate%20Log4j%20APC%20PowerChute.ps1) | Applies Log4Shell mitigation specific to APC PowerChute Business Edition |
| [Mitigate Log4j Lookups.ps1](CVE%20Mitigations/Mitigate%20Log4j%20Lookups.ps1) | Disables Log4j JNDI lookups system-wide to mitigate Log4Shell |

### OS — Maintenance

| Script | Description |
|---|---|
| [Audit RMM Group Policies.ps1](OS/Maintenance/Audit%20RMM%20Group%20Policies.ps1) | Reports GPOs deployed by RMM tooling to identify conflicts or stale policies |
| [Cleanup Driver Cache.ps1](OS/Maintenance/Cleanup%20Driver%20Cache.ps1) | Removes old cached driver packages from the driver store |
| [Cleanup Intune MSI Cache.ps1](OS/Maintenance/Cleanup%20Intune%20MSI%20Cache.ps1) | Clears the Intune cached MSI installer files |
| [Cleanup Old Drivers.ps1](OS/Maintenance/Cleanup%20Old%20Drivers.ps1) | Removes outdated third-party drivers from the system |
| [Cleanup Old Windows Versions.bat](OS/Maintenance/Cleanup%20Old%20Windows%20Versions.bat) | Removes Windows.old and other old OS installation folders |
| [Cleanup Windows Components.ps1](OS/Maintenance/Cleanup%20Windows%20Components.ps1) | Runs DISM component store cleanup |
| [Cleanup Windows Patches.ps1](OS/Maintenance/Cleanup%20Windows%20Patches.ps1) | Removes superseded Windows update packages |
| [Cleanup Windows Update Cache.ps1](OS/Maintenance/Cleanup%20Windows%20Update%20Cache.ps1) | Clears the Windows Update download cache (SoftwareDistribution folder) |
| [Disable Windows Welcome Experience.bat](OS/Maintenance/Disable%20Windows%20Welcome%20Experience.bat) | Suppresses the Windows Welcome Experience screen shown after updates |
| [Enable and Start Service.ps1](OS/Maintenance/Enable%20and%20Start%20Service.ps1) | Enables (if disabled) and starts (or restarts) one or more Windows services; retries on failure |
| [Install Hotfix PrintNightmare.bat](OS/Maintenance/Install%20Hotfix%20PrintNightmare.bat) | Applies the PrintNightmare security hotfix |
| [Install Windows Product Key.bat](OS/Maintenance/Install%20Windows%20Product%20Key.bat) | Activates Windows with a provided product key |
| [Rebuild Windows Search Index.ps1](OS/Maintenance/Rebuild%20Windows%20Search%20Index.ps1) | Rebuilds the Windows Search index from scratch |
| [Rebuild WMI Repository.bat](OS/Maintenance/Rebuild%20WMI%20Repository.bat) | Stops WMI, verifies the repository, and rebuilds if corrupt |
| [Remove Windows Hotfix.ps1](OS/Maintenance/Remove%20Windows%20Hotfix.ps1) | Uninstalls a specific Windows update by KB number |
| [Scan and Repair Windows.bat](OS/Maintenance/Scan%20and%20Repair%20Windows.bat) | Runs SFC and DISM to scan and repair Windows system files |
| [Schedule Check Disk.bat](OS/Maintenance/Schedule%20Check%20Disk.bat) | Schedules a chkdsk run on next reboot |
| [Set Windows License Key.ps1](OS/Maintenance/Set%20Windows%20License%20Key.ps1) | Sets and activates a Windows license key via PowerShell |

### OS — Migration

| Script | Description |
|---|---|
| [Enroll Device in Intune.ps1](OS/Migration/Enroll%20Device%20in%20Intune.ps1) | Triggers Intune MDM enrollment on a device |
| [PreStage Entra ID Migration.ps1](OS/Migration/PreStage%20Entra%20ID%20Migration.ps1) | Prepares a device for Entra ID join by installing prerequisites and configuring settings |
| [Run Profile Migration Wizard.ps1](OS/Migration/Run%20Profile%20Migration%20Wizard.ps1) | Launches the User State Migration Tool or profile migration wizard |

### OS — Networking

| Script | Description |
|---|---|
| [Disable Offline Files.ps1](OS/Networking/Disable%20Offline%20Files.ps1) | Disables the Windows Offline Files feature |
| [Enable WakeOnLAN.ps1](OS/Networking/Enable%20WakeOnLAN.ps1) | Enables Wake-on-LAN for the active network adapter |
| [Get Mapped Network Drives.ps1](OS/Networking/Get%20Mapped%20Network%20Drives.ps1) | Reports all mapped network drives for all user profiles on the machine |
| [Get Network Name.ps1](OS/Networking/Get%20Network%20Name.ps1) | Retrieves the network profile name shown in Windows |
| [Set Mapped Network Drive.bat](OS/Networking/Set%20Mapped%20Network%20Drive.bat) | Maps a network drive persistently for a specified user |
| [Sync Time to NTP.bat](OS/Networking/Sync%20Time%20to%20NTP.bat) | Forces a time sync against a specified NTP server |

### OS — Reporting

| Script | Description |
|---|---|
| [Audit Server Environment.ps1](OS/Reporting/Audit%20Server%20Environment.ps1) | Inventories a server's OS, roles, hardware, and configuration |
| [Capture Webcam Image.ps1](OS/Reporting/Capture%20Webcam%20Image.ps1) | Captures a still image from the device webcam (for asset verification or theft recovery) |
| [Check Windows 11 Upgrade Capability.ps1](OS/Reporting/Check%20Windows%2011%20Upgrade%20Capability.ps1) | Checks whether the device meets Windows 11 hardware requirements |
| [Get Disk SMART Status.bat](OS/Reporting/Get%20Disk%20SMART%20Status.bat) | Reports SMART health status for all physical drives |
| [Get Files by Type.ps1](OS/Reporting/Get%20Files%20by%20Type.ps1) | Searches a path for files matching a specified extension |
| [Get Folder Sizes.ps1](OS/Reporting/Get%20Folder%20Sizes.ps1) | Reports disk usage by folder under a specified root path |
| [Get Group Policies.ps1](OS/Reporting/Get%20Group%20Policies.ps1) | Reports all GPOs applied to the device |
| [Get Installed Printers.ps1](OS/Reporting/Get%20Installed%20Printers.ps1) | Lists all installed printers and their port/driver details |
| [Get Log File Contents.bat](OS/Reporting/Get%20Log%20File%20Contents.bat) | Reads and outputs the contents of a specified log file |
| [Get Services by Logon Account.ps1](OS/Reporting/Get%20Services%20by%20Logon%20Account.ps1) | Reports all services configured to run as a specific user account |
| [Get Share Permissions.ps1](OS/Reporting/Get%20Share%20Permissions.ps1) | Reports share and NTFS permissions for all shared folders on the machine |
| [Get Windows License Info.ps1](OS/Reporting/Get%20Windows%20License%20Info.ps1) | Reports Windows activation status and license key details |
| [Get Windows Update Log.ps1](OS/Reporting/Get%20Windows%20Update%20Log.ps1) | Converts and exports the Windows Update ETL log to a readable format |

### OS — Security

| Script | Description |
|---|---|
| [Audit Local Admin Users.ps1](OS/Security/Audit%20Local%20Admin%20Users.ps1) | Reports all members of the local Administrators group |
| [Configure Auto Logoff.ps1](OS/Security/Configure%20Auto%20Logoff.ps1) | Creates a scheduled task that logs off the active console session after a configurable idle timeout (default 10 minutes); intended for shared workstations and laptops |
| [Detect Antivirus.ps1](OS/Security/Detect%20Antivirus.ps1) | Detects installed/active third-party AV or EDR products and falls back to Windows Defender status on workstations and servers; reports to NinjaOne `installedAntivirus` field |
| [Disable Cached Domain Credentials.bat](OS/Security/Disable%20Cached%20Domain%20Credentials.bat) | Sets the registry value to disable cached domain credential storage |
| [Disable SMB Guest Logon.ps1](OS/Security/Disable%20SMB%20Guest%20Logon.ps1) | Disables SMB guest access on the machine |
| [Enable BitLocker.ps1](OS/Security/Enable%20BitLocker.ps1) | Enables BitLocker encryption on the system drive and stores the recovery key |
| [Enable Cached Domain Credentials.bat](OS/Security/Enable%20Cached%20Domain%20Credentials.bat) | Restores cached domain credential storage (reverses the disable) |
| [Enable SMB Guest Logon.ps1](OS/Security/Enable%20SMB%20Guest%20Logon.ps1) | Re-enables SMB guest access (use with caution) |
| [Enable UAC.bat](OS/Security/Enable%20UAC.bat) | Re-enables User Account Control via registry |
| [Get BitLocker Key.ps1](OS/Security/Get%20BitLocker%20Key.ps1) | Retrieves the BitLocker recovery key for the system drive |
| [Set Execution Policy.ps1](OS/Security/Set%20Execution%20Policy.ps1) | Sets the PowerShell execution policy for the machine or current user |

### OS — User Management

| Script | Description |
|---|---|
| [Audit User Profiles.ps1](OS/User%20Management/Audit%20User%20Profiles.ps1) | Reports all user profiles on the machine with last logon and size |
| [Cleanup User Profiles.ps1](OS/User%20Management/Cleanup%20User%20Profiles.ps1) | Removes stale or inactive user profiles based on age or last logon |
| [Create Admin User.bat](OS/User%20Management/Create%20Admin%20User.bat) | Creates a local administrator account |
| [Create User with Random Password.ps1](OS/User%20Management/Create%20User%20with%20Random%20Password.ps1) | Creates a local user account with a randomly generated password |
| [Delete User Profile.ps1](OS/User%20Management/Delete%20User%20Profile.ps1) | Permanently deletes a specific user profile from the machine |
| [Promote User to Local Admin.ps1](OS/User%20Management/Promote%20User%20to%20Local%20Admin.ps1) | Adds an existing user to the local Administrators group |
| [Reset Admin Password.bat](OS/User%20Management/Reset%20Admin%20Password.bat) | Resets the local Administrator account password |
| [Set Local Username.bat](OS/User%20Management/Set%20Local%20Username.bat) | Renames a local user account |

---

## Command Reference

These are commands that one may find useful on Windows workstations and servers. The commands are a mix of DOS/CMD and PowerShell. The easiest way to tell them apart is that DOS commands will be in all capital letters, PowerShell will be mixed-case.

Many of these commands require an elevated command prompt or PowerShell terminal; run as Administrator. Note that any DOS command can be run in PowerShell, but PowerShell can't be run in the DOS command prompt without calling the PowerShell interpreter. If you are working from the DOS command prompt, you can run simple Powershell commands that don't include quotations using the exmaple below:
`powershell -c "Get-Volume C"`

Any text after a # in an example is a remark or comment, which explains what the command does.

<!-- TOC -->

- [About](#about)
- [Filesystem Operations](#filesystem-operations)
    - [Directories](#directories)
    - [Common locations and their aliases](#common-locations-and-their-aliases)
    - [File operations](#file-operations)
    - [Disks and drives](#disks-and-drives)
- [System Functions](#system-functions)
    - [Operating System Info](#operating-system-info)
    - [Run a command](#run-a-command)
    - [Operations](#operations)
    - [Services](#services)
    - [Process list](#process-list)
    - [Kill](#kill)
    - [Aliases](#aliases)
    - [Connected devices**](#connected-devices)
- [Network](#network)
    - [LAN IP](#lan-ip)
    - [WAN IP](#wan-ip)
    - [Domain Name Lookup and DNS Records](#domain-name-lookup-and-dns-records)
    - [Who owns an IP or domain](#who-owns-an-ip-or-domain)
    - [Where is an IP from](#where-is-an-ip-from)
    - [Who is on the network, are they reachable?](#who-is-on-the-network-are-they-reachable)
    - [Remote Command Line](#remote-command-line)
    - [Get Files from the Internet](#get-files-from-the-internet)
    - [Install Applications with winget](#install-applications-with-winget)
- [User functions](#user-functions)
    - [Who am I](#who-am-i)
    - [Who is signed in](#who-is-signed-in)
    - [Change password](#change-password)
    - [List users and groups](#list-users-and-groups)
    - [Group Policy](#group-policy)
- [References](#references)

<!-- /TOC -->

# Filesystem Operations
##	Directories
**Change Directory**
```bat
CD \                    # Go to root directory of current drive
CD ..                   # Go back one directory
CD ..\..                # Layered to go back two directories
CD C:\Temp\             # Change directory to the Temp folder on the C: drive
CD "C:\Program Files\"  # Changing to a directory with spaces in the name requires quotes
```
**Print working directory**
```bat
CD       # In CMD, CD with no arguments prints the current path
```
```powershell
Get-Location  # PowerShell equivalent — also aliased as 'pwd' or 'gl'
```

**List Files**
```bat
DIR                    # List files in current directory
DIR /A                 # Include hidden and system files
DIR /S                 # Recursive listing including subdirectories
DIR /B                 # Bare format (names only, no headers)
DIR C:\Temp\*.log      # List files matching a pattern
```
```powershell
Get-ChildItem                        # List files and folders — also works as: ls, dir, gci
ls                                   # Works fine in PowerShell; aliases to Get-ChildItem
Get-ChildItem -Force                 # Include hidden items
Get-ChildItem -Recurse               # Recursive listing
Get-ChildItem -Filter "*.log"        # Filter by name pattern
Get-ChildItem -File                  # Files only
Get-ChildItem -Directory             # Folders only
```

## Common locations and their aliases
To use these: %AppData% is the current user's full path to their appdata folder;
*e.g.: CD %AppData% = CD C:\Users\username\AppData\Roaming*

- %AllUsersProfile% - Open the All User's Profile C:\ProgramData
- %AppData% - Opens AppData folder C:\Users\{username}\AppData\Roaming
- %CommonProgramFiles% - C:\Program Files\Common Files
- %CommonProgramFiles(x86)% - C:\Program Files (x86)\Common Files
- %HomeDrive% - Opens your home drive C:\
- %LocalAppData% - Opens local AppData folder C:\Users\{username}\AppData\Local
- %ProgramData% - C:\ProgramData
- %ProgramFiles% - C:\Program Files or C:\Program Files (x86)
- %ProgramFiles(x86)% - C:\Program Files (x86)
- %Public% - C:\Users\Public
- %SystemDrive% - C:
- %SystemRoot% - Opens Windows folder C:\Windows
- %Temp% - Opens temporary file Folder C:\Users\{Username}\AppData\Local\Temp
- %UserProfile% - Opens your user's profile C:\Users\{username}
- %AppData%\Microsoft\Windows\Start Menu\Programs\Startup - Opens Windows 10 Startup location for program shortcuts
- ~ - In PowerShell, the tilde can be used as the user's home director, just like in Linux: CD ~

## File operations
**View file contents**
```bat
TYPE filename.txt               # Print a file's contents to the terminal
MORE filename.txt               # Paginate output — press Space to advance
```
```powershell
Get-Content filename.txt        # Print file contents (alias: cat, gc)
Get-Content filename.txt | More # Paginate output
```

**Find**
```bat
DIR /S /B "filename.txt"        # Search for a file by name recursively
FINDSTR "search text" file.txt  # Search file contents for a string (like grep)
FINDSTR /S /I "text" *.log      # Recursive, case-insensitive content search
```
```powershell
Get-ChildItem -Recurse -Filter "filename.txt"              # Find file by name
Get-ChildItem -Recurse | Where-Object { $_.Name -like "*.log" }  # Pattern match
Select-String -Path "*.log" -Pattern "error" -Recurse      # Search file contents
```

**Edit**
```bat
NOTEPAD filename.txt    # Open file in Notepad (from CMD or Run dialog)
```
```powershell
notepad filename.txt    # Open in Notepad
code filename.txt       # Open in VS Code (if installed)
# Append a line to a file:
Add-Content -Path filename.txt -Value "new line here"
# Overwrite a file:
Set-Content -Path filename.txt -Value "replacement content"
```

**Copy, Move, Delete**
```bat
COPY source.txt dest.txt        # Copy a file
XCOPY source\ dest\ /E /I      # Copy a folder tree (/E = include empty dirs)
ROBOCOPY source\ dest\ /MIR    # Mirror copy — best tool for folder sync/backup
MOVE source.txt C:\dest\        # Move a file
DEL filename.txt                # Delete a file
RD /S /Q foldername             # Delete a folder and all its contents
```
```powershell
Copy-Item source.txt dest.txt                        # Copy file
Copy-Item source\ dest\ -Recurse                    # Copy folder tree
Move-Item source.txt C:\dest\                        # Move file
Remove-Item filename.txt                             # Delete file
Remove-Item foldername -Recurse -Force               # Delete folder and contents
```

**Symbolic Links**
```bat
# Symbolic link (file or folder)
MKLINK link.txt target.txt           # Create a symbolic link to a file
MKLINK /D C:\LinkFolder C:\Target    # Create a directory symbolic link

# Junction (folder only, local volumes)
MKLINK /J C:\LinkFolder C:\Target    # Create a junction

# Hard link (file only, same volume)
MKLINK /H hardlink.txt original.txt  # Create a hard link
```
```powershell
New-Item -ItemType SymbolicLink -Path C:\LinkFolder -Target C:\Target
New-Item -ItemType Junction    -Path C:\LinkFolder -Target C:\Target
New-Item -ItemType HardLink    -Path hardlink.txt  -Target original.txt
```

**Folders**
```powershell
# Get folder size
(Get-ChildItem C:\Users\username\Downloads | measure Length -s).sum /1GB
```

##	Disks and drives
**Disks and partitions**
```cmd
C:         # Enter drive letter and colon to change drive
FORMAT D:  # Format disk
FDISK
DISKPART
```

**Filesystem and OS image repair**
```cmd
DISM.exe /Online /Cleanup-image /Restorehealth  # Deployment Image Service and Management Tool
sfc /scannow        # Scans and repairs corrupted system files
echo y | chkdsk /r  # Perform offline checkdisk at next boot, assume yes
```

**Get checkdisk results**
```powershell
get-winevent -FilterHashTable @{logname="Application"; id="1001"}| ?{$_.providername –match "wininit"} | Select-Object -first 1 | fl timecreated, message
```

**Disk SMART Status**
```powershell
# Note: wmic is deprecated in Windows 11 — prefer Get-CimInstance
Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus
Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus
```

# System Functions
## Operating System Info
```powershell
Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, OsBuildNumber  # OS name and build
[System.Environment]::OSVersion                                             # .NET OS version
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture
Get-TimeZone                                        # Current time zone
Get-Date                                            # Current date and time
```
```bat
VER                      # Windows version string
SYSTEMINFO               # Full OS, hardware, and network summary
SYSTEMINFO | FINDSTR /B /C:"OS Name" /C:"OS Version"
```

## Run a command
```bat
cmd /c "command"          # Run a CMD command and exit
start program.exe         # Launch a program without waiting for it
call script.bat           # Call another batch file and return
```
```powershell
Invoke-Expression "command"                          # Run a string as a command
Start-Process notepad.exe                            # Launch a process
Start-Process powershell.exe -Verb RunAs             # Launch elevated (as Admin)
& "C:\path\to\script.ps1"                            # Call/invoke a script
powershell -ExecutionPolicy Bypass -File script.ps1  # Run script bypassing policy
```

## Operations
```powershell
Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object CSName, LastBootUpTime  # Get last boot time
(Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime  # Uptime as a timespan
Restart-Computer -Force               # Reboot immediately
Stop-Computer -Force                  # Shut down immediately
```
```bat
shutdown /r /t 0      # Reboot immediately
shutdown /s /t 0      # Shut down immediately
shutdown /a           # Abort a pending shutdown
shutdown /r /t 60 /c "Rebooting for updates"  # Reboot in 60 seconds with message
```

**Unexpected Reboots**

Event ID 41 (Kernel-Power) and 6008 both indicate the system rebooted without a clean shutdown (crash, hard reset, or power loss).

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008} -MaxEvents 20 |
    Select-Object TimeCreated, Id, @{N='Summary';E={$_.Message -split "`n" | Select-Object -First 1}} |
    Format-Table -AutoSize
```

## Services
```powershell
# Get-Service cmdlet
Get-Service                                  # List all services
Get-Service {service}                        # Get service status by name
Get-Service {service} | Start-Service        # Start the service
Get-Service {service} | Stop-Service         # Stop the service
Get-Service {service} | Restart-Service      # Restart the service
Set-Service {service} -StartupType Automatic # Change startup type

# CIM methods (note: Get-WmiObject is deprecated — use Get-CimInstance)
Get-CimInstance -Class Win32_Service -Filter "Name='ServiceName'"   # Get service info
(Get-CimInstance -Class Win32_Service -Filter "Name='ServiceName'").Delete()  # Delete service
```

```cmd
# CMD / DOS batch methods
net start                                    # Show all running services
sc query {service}                           # Get info on a service
sc queryex {service}                         # Get extended info
sc [stop/start/restart/delete] {service}     # Control service state
```
References: 
* https://ss64.com/nt/sc.html
* https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sc-query

##	Process list
```powershell
get-process                                   # List all processes
get-process -Name "Notepad"                   # Get processes named Notepad
get-process -Name "*notepad*"                 # Get process info for applications with Notepad in their name
```

##	Kill
```powershell
Stop-Process 26152                            # Kill the process with ID #26152, identified above with get-process
Stop-Process -Name "Notepad"                  # Kill the processes named Notepad
get-process -Name "*notepad*" | Stop-Process  # Get and kill the processes with Notepad in their name
```

## Aliases
Windows supports filesystem aliases (junctions and symlinks) similar to Linux symlinks. These let you create a shortcut path that points to another folder — useful for redirecting legacy paths without moving data.
```bat
# Create a junction — a directory alias pointing to another folder on the same volume
MKLINK /J C:\OldPath C:\NewPath

# Create a directory symbolic link — works across volumes, requires admin
MKLINK /D C:\LinkFolder C:\Target

# List junctions/symlinks in a directory
DIR /AL C:\SomePath         # /AL shows only reparse points (junctions and symlinks)
```
```powershell
# Create via New-Item
New-Item -ItemType Junction    -Path C:\OldPath    -Target C:\NewPath
New-Item -ItemType SymbolicLink -Path C:\LinkFolder -Target C:\Target

# Find all junctions and symlinks under a path
Get-ChildItem -Recurse | Where-Object { $_.Attributes -match 'ReparsePoint' }
```
For **shell command aliases** (mapping one command name to another), see PowerShell's `Get-Alias` / `Set-Alias`.

## Connected Devices
```powershell
Get-PnpDevice                                     # List all Plug-and-Play devices
Get-PnpDevice -PresentOnly                        # Only devices currently connected
Get-PnpDevice -Class USB                          # USB devices only
Get-PnpDevice | Where-Object { $_.Status -eq 'Error' }  # Devices with errors
```
```bat
DEVMGMT.MSC     # Open Device Manager (GUI)
```

# Network
## LAN IP
```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" }
(Get-NetIPConfiguration).IPv4Address.IPAddress  # Quick one-liner
```
```bat
IPCONFIG                  # Full adapter details
IPCONFIG /ALL             # Includes MAC address, DHCP server, DNS servers
```

## WAN IP
```powershell
(Invoke-RestMethod "https://ifconfig.me/ip").Trim()         # Quick WAN IP lookup
(Invoke-WebRequest "https://api.ipify.org").Content.Trim()
```

## Domain Name Lookup and DNS Records
```powershell
Resolve-DnsName google.com              # DNS lookup (supports A, MX, TXT, PTR, etc.)
Resolve-DnsName google.com -Type MX    # Get MX records
Resolve-DnsName google.com -Type TXT   # Get TXT/SPF records
Resolve-DnsName 8.8.8.8                # Reverse lookup (PTR)
```
```bat
NSLOOKUP google.com                    # Forward lookup
NSLOOKUP -type=MX google.com          # MX record lookup
NSLOOKUP -type=TXT google.com         # TXT record lookup
```

## Who owns an IP or domain
```powershell
# PowerShell has no built-in whois — use an external tool or online lookup
# With Windows Subsystem for Linux (WSL):
whois 8.8.8.8
# Or use the ARIN REST API:
(Invoke-RestMethod "https://rdap.arin.net/registry/ip/8.8.8.8").handle
```
```bat
WHOIS 8.8.8.8       # Requires Sysinternals whois.exe in PATH
                    # Download: https://learn.microsoft.com/en-us/sysinternals/downloads/whois
```

## Where is an IP from
```powershell
Invoke-RestMethod "https://ipinfo.io/8.8.8.8"       # Returns JSON with city, region, org
(Invoke-RestMethod "https://ipinfo.io/8.8.8.8/country").Trim()
```

## Who is on the network, are they reachable?
```powershell
Test-Connection 192.168.1.1 -Count 4         # Ping (PowerShell equivalent)
Test-Connection 192.168.1.1 -Quiet           # Returns True/False only
Test-NetConnection 192.168.1.1 -Port 443     # Test TCP port reachability
1..254 | ForEach-Object { Test-Connection "192.168.1.$_" -Count 1 -Quiet -AsJob }
# Then check arp table:
arp -a                                       # Show ARP cache (known LAN IPs and MACs)
```
```bat
PING 192.168.1.1              # Basic ping
PING -n 1 192.168.1.1         # Single ping
ARP -A                        # Show ARP table
```

## Scan a Port
```powershell
Test-NetConnection 192.168.1.1 -Port 3389   # Test if RDP port is open
Test-NetConnection smtp.office365.com -Port 587  # Test SMTP port
```

## Remote Command Line
```powershell
# PowerShell Remoting (WinRM)
Enter-PSSession -ComputerName server01                   # Interactive remote session
Invoke-Command -ComputerName server01 -ScriptBlock { Get-Service }  # Run command remotely
Invoke-Command -ComputerName server01 -FilePath script.ps1          # Run script remotely

# SSH (available on Windows 10+ and Server 2019+)
ssh user@server01                      # Open SSH session
ssh user@server01 "Get-Process"        # Run a single command via SSH
```
```bat
MSTSC /v:192.168.1.100        # Open RDP to an IP address
PSEXEC \\computername cmd.exe # Remote CMD via Sysinternals PsExec
```

## Get Files from the Internet
```powershell
Invoke-WebRequest -Uri {URL} -OutFile C:\Temp\filename.ext  # Download a file
Start-BitsTransfer -Source {URL} -Destination C:\Temp\      # BITS transfer (resumable)
```
```bat
curl -o C:\Temp\file.ext {URL}   # curl is available in Windows 10+ CMD
```

## Install Applications with winget
winget is the Windows Package Manager, built into Windows 10 (1809+) and Windows 11. A quick alternative to Ninite for common app installs.

**Install individual apps**

> `--source winget` pins the install to the winget community repository — without it, winget may find the same package in the Microsoft Store and prompt you to choose.  
> `--silent` suppresses the installer UI and progress. Remove it to see the normal installer window.  
> `--accept-package-agreements` and `--accept-source-agreements` are required to skip license prompts — keep these even without `--silent`.

```bat
winget install --id Google.Chrome             --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Mozilla.Firefox           --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Zoom.Zoom                 --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id SlackTechnologies.Slack   --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Dialpad.Dialpad           --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.Teams           --source winget --silent --accept-package-agreements --accept-source-agreements --override "/quiet NOLAUNCH=1"
winget install --id 7zip.7zip                 --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.DotNet.DesktopRuntime.8 --source winget --silent --accept-package-agreements --accept-source-agreements
winget install --id Microsoft.VCRedist.2015+.x64      --source winget --silent --accept-package-agreements --accept-source-agreements
```

**Install all of the above in one go**
```powershell
$apps = @(
    "Google.Chrome",
    "Mozilla.Firefox",
    "Zoom.Zoom",
    "SlackTechnologies.Slack",
    "Dialpad.Dialpad",
    "Microsoft.Teams",
    "7zip.7zip",
    "Microsoft.DotNet.DesktopRuntime.8",
    "Microsoft.VCRedist.2015+.x64"
)
foreach ($app in $apps) {
    $extra = if ($app -eq "Microsoft.Teams") { "--override '/quiet NOLAUNCH=1'" } else { "" }
    winget install --id $app --source winget --silent --accept-package-agreements --accept-source-agreements $extra
    while (Get-Process msiexec -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 3 }
}
```

**Install all of the above as a one-liner**

> Remove `--silent` to see the installer UI and monitor progress.

```powershell
"Google.Chrome","Mozilla.Firefox","Zoom.Zoom","SlackTechnologies.Slack","Dialpad.Dialpad","Microsoft.Teams","7zip.7zip","Microsoft.DotNet.DesktopRuntime.8","Microsoft.VCRedist.2015+.x64" | ForEach-Object { winget install --id $_ --source winget --silent --accept-package-agreements --accept-source-agreements; while (Get-Process msiexec -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 3 } }
```

**Engineer / sysadmin add-ons** (VS Code, Notepad++, Python 3)
```powershell
"Microsoft.VisualStudioCode","Notepad++.Notepad++","Python.Python.3.13" | ForEach-Object { winget install --id $_ --source winget --silent --accept-package-agreements --accept-source-agreements; while (Get-Process msiexec -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 3 } }
```

**Other useful winget commands**
```bat
winget list                        # Show all installed apps winget knows about
winget upgrade --all --silent      # Update every app winget can manage
winget upgrade --id Google.Chrome  # Update a specific app
winget uninstall --id Zoom.Zoom    # Uninstall an app
winget search "zoom"               # Search for a package by name
```

# User functions
##	Who am I
```bat
WHOAMI  # Get current sername, presented as authentication source and username
        # COMPTUERNAME\USER, or DOMAIN\USER
```

## Who is signed in
```bat
QUSER                          # List all users currently logged on, including RDP sessions
QWINSTA                        # List sessions and their state
```
```powershell
Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object UserName  # Currently logged-on user
query user                                                                  # All sessions
```

## Change password
```bat
NET USER {username} {newpassword}          # Set a local user's password
NET USER {username} *                      # Prompt for new password interactively
```
```powershell
$pw = ConvertTo-SecureString "NewPass123!" -AsPlainText -Force
Set-LocalUser -Name {username} -Password $pw
```

## List users and groups
```bat
NET USER                              # List all local user accounts
NET USER {username}                   # Details for a specific user
NET LOCALGROUP                        # List all local groups
NET LOCALGROUP Administrators         # List members of the Administrators group
NET LOCALGROUP Administrators "Username" /add   # Add a user to the Administrators group
```
```powershell
Get-LocalUser                         # List local users
Get-LocalUser | Where-Object { $_.Enabled -eq $true }  # Enabled users only
Get-LocalGroup                        # List local groups
Get-LocalGroupMember Administrators   # Members of a specific group
Add-LocalGroupMember -Group Administrators -Member {username}  # Add user to group
Remove-LocalGroupMember -Group Administrators -Member {username}
```

## Group Policy
```bat
GPUPDATE /FORCE              # Force a Group Policy refresh immediately
GPRESULT /R                  # Show applied GPOs for the current user and computer
GPRESULT /H C:\gpreport.html # Export a detailed HTML report
```
```powershell
Invoke-GPUpdate -Force                  # Force GP refresh (requires RSAT)
Get-GPResultantSetOfPolicy -ReportType Html -Path C:\gpreport.html
```

# References
- https://superuser.com/questions/217504/is-there-a-list-of-windows-special-directories-shortcuts-like-temp
- https://ss64.com/nt/ — CMD/DOS command reference
- https://ss64.com/ps/ — PowerShell command reference
- https://learn.microsoft.com/en-us/powershell/scripting/overview — Official PowerShell docs
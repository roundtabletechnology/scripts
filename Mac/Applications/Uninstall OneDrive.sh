#!/bin/bash
#
# Uninstall OneDrive.sh
#
# SYNOPSIS
#   Silently removes the OneDrive sync app from a Mac and blocks it from syncing if it is reinstalled, with no
#   prompts and no restart. The macOS counterpart of Windows/Applications/Uninstall OneDrive.ps1.
#
# DESCRIPTION
#   On a Mac, OneDrive is a single app in /Applications - the standalone build (com.microsoft.OneDrive, from
#   Microsoft's .pkg or the Office suite installer) or the Mac App Store build (com.microsoft.OneDrive-mac) - plus
#   updater launch agents/daemons and per-user support files. This script:
#     1. Surveys every user account for OneDrive sync folders and for Folder Backup (Desktop/Documents moved into
#        OneDrive).
#     2. Stops every process running from the OneDrive app, unloads and removes its launch agents and daemons,
#        deletes the app bundle and forgets its installer receipts.
#     3. Removes per-user caches, logs and support files that macOS does not privacy-protect.
#     4. Writes Microsoft's documented machine-wide OneDrive settings so a reinstalled standalone OneDrive cannot
#        sync anything: DisablePersonalSync, an AllowTenantList that allows no real tenant, and KFMBlockOptIn.
#     5. Reports, but does not change, an Office for Mac install that is not configured to exclude OneDrive.
#
#   USER FILES ARE NEVER DELETED. Each user's sync folder (~/Library/CloudStorage/OneDrive-*, or ~/OneDrive* on
#   older versions) is the user's synced data and is left exactly where it is; files that were stored locally stay
#   readable, anything online-only remains in OneDrive online. Every delete in this script goes through one
#   function that refuses any path not on a fixed allowlist of OneDrive program locations.
#
#   DATA SAFETY - Folder Backup. If a user's Desktop or Documents has been moved into OneDrive, removing OneDrive
#   leaves those folders inside a sync folder that no longer syncs, showing only what was stored locally. Because
#   the app is shared by every account on the Mac, it cannot be removed for some users and kept for others - so by
#   default, if ANY user has Folder Backup, nothing is changed and the script exits 1 so the device stands out in
#   NinjaOne. Have those users stop Folder Backup and move their files back first (OneDrive > Settings > Backup >
#   Manage backup), or pass --include-folder-backup-users to remove OneDrive regardless.
#
#   Deliberately NOT touched, because macOS privacy protection (TCC) can show the signed-in user an "access data
#   from other apps" prompt when another process reads them, and because none of it runs anything once the app is
#   gone: ~/Library/Containers, ~/Library/Group Containers, the Keychain, and the CloudStorage / File Provider data.
#
# OPTIONS (or the matching NinjaOne script variable, as a checkbox)
#   --dry-run                        dryRun                       Report what would be done; change nothing.
#   --include-folder-backup-users    includeFolderBackupUsers     Remove OneDrive even if a user has Folder Backup.
#   --skip-policy                    skipPolicy                   Do not write the machine-wide sync block.
#
# EXIT CODES
#   0  OneDrive removed (or was not present) and the sync block is in place.
#   1  Skipped because of Folder Backup, something could not be removed, or not run as root.
#
# NOTES
#   Run as root (NinjaOne default). Never restarts, never logs anyone out, never shows anything to the user beyond
#   the OneDrive menu bar icon disappearing. Safe to run repeatedly - schedule it (e.g. weekly) to catch OneDrive
#   coming back from a user download or an Office suite install.
#
#   Deleting an app bundle is governed by macOS App Management. If the RMM agent lacks the permission, the delete
#   fails, which the script reports (exit 1). Grant the agent Full Disk Access / App Management through MDM.
#
#   The sync block applies to the standalone OneDrive. The Mac App Store build keeps its settings inside its own
#   container and only honors them through a configuration profile, so to block that build, or to stop the Office
#   suite installer adding OneDrive (com.microsoft.office InstallOneDrive = false, profile only), use MDM.
#

DryRun=false
IncludeFolderBackupUsers=false
SkipPolicy=false

for Arg in "$@"; do
    case "$Arg" in
        --dry-run)                     DryRun=true ;;
        --include-folder-backup-users) IncludeFolderBackupUsers=true ;;
        --skip-policy)                 SkipPolicy=true ;;
        *) echo "Unknown option: $Arg" >&2; exit 1 ;;
    esac
done

# NinjaOne checkbox script variables arrive as the strings 'true'/'false'.
IsTrue() { case "$1" in 1|true|TRUE|True|yes|YES) return 0 ;; *) return 1 ;; esac; }
IsTrue "$dryRun"                   && DryRun=true
IsTrue "$includeFolderBackupUsers" && IncludeFolderBackupUsers=true
IsTrue "$skipPolicy"               && SkipPolicy=true

AppPath="/Applications/OneDrive.app"
PolicyDomain="/Library/Preferences/com.microsoft.OneDrive"
# AllowTenantList takes priority over everything else; an entry for a tenant that cannot exist allows no tenant.
NoTenant="00000000-0000-0000-0000-000000000000"
LogFile="/var/log/UninstallOneDrive_$(date '+%Y-%m-%d_%H%M%S').log"
Failed=false

Log() {
    local Line
    Line="[$(date '+%Y-%m-%d %H:%M:%S')] [${2:-Info}] $1"
    echo "$Line"
    echo "$Line" >> "$LogFile" 2>/dev/null
}

# Runs a command, or under --dry-run only logs that it would have. Every change the script makes goes through here.
Change() {
    local Description="$1"; shift
    if $DryRun; then
        Log "[DryRun] Would: $Description"
        return 0
    fi
    Log "$Description"
    if ! "$@"; then
        Log "Failed: $Description" Warning
        return 1
    fi
}

# Deletes a file or folder, but only if it is one of OneDrive's program locations. User data - CloudStorage, any
# ~/OneDrive* sync folder, Desktop, Documents, containers - can never match, so a bug elsewhere cannot reach it.
RemoveSafely() {
    local Target="$1"
    [ -e "$Target" ] || [ -L "$Target" ] || return 0
    case "$Target" in
        "$AppPath" | \
        /Library/LaunchAgents/com.microsoft.OneDrive*.plist | \
        /Library/LaunchDaemons/com.microsoft.OneDrive*.plist | \
        /Library/LaunchAgents/com.microsoft.SyncReporter.plist | \
        /Library/LaunchDaemons/com.microsoft.SyncReporter.plist | \
        /Library/PrivilegedHelperTools/com.microsoft.OneDrive* | \
        /Users/*/Library/Caches/com.microsoft.OneDrive* | \
        /Users/*/Library/Caches/com.microsoft.SharePoint-mac | \
        /Users/*/Library/Logs/OneDrive | \
        /Users/*/Library/Application\ Support/OneDrive | \
        /Users/*/Library/Application\ Support/com.microsoft.OneDrive* | \
        /Users/*/Library/Saved\ Application\ State/com.microsoft.OneDrive* | \
        /Users/*/Library/LaunchAgents/com.microsoft.OneDrive*.plist)
            ;;
        *)
            Log "Refusing to delete '$Target': not a OneDrive program location." Error
            Failed=true
            return 1
            ;;
    esac
    case "$Target" in
        */CloudStorage/* | */Containers/* | */Group\ Containers/*)
            Log "Refusing to delete '$Target': protected location." Error
            Failed=true
            return 1
            ;;
    esac
    Change "Delete $Target" rm -rf "$Target"
}

# Real user accounts: UID 501 and up with a home folder that exists.
ListUsers() {
    dscl . -list /Users UniqueID | while read -r Name Uid; do
        [ "$Uid" -ge 501 ] 2>/dev/null || continue
        Home=$(dscl . -read "/Users/$Name" NFSHomeDirectory 2>/dev/null | awk '{ $1 = ""; sub(/^ /, ""); print }')
        [ -d "$Home" ] || continue
        echo "$Name|$Uid|$Home"
    done
}

# Prints a user's OneDrive sync folders (current File Provider location and the legacy home-folder location).
SyncFolders() {
    local Home="$1" Folder
    for Folder in "$Home"/Library/CloudStorage/OneDrive* "$Home"/OneDrive*; do
        [ -e "$Folder" ] && echo "$Folder"
    done
}

# Prints "Desktop -> target" for each of Desktop/Documents that has been relocated into a OneDrive folder.
FolderBackupRedirects() {
    local Home="$1" Name Target
    for Name in Desktop Documents; do
        [ -L "$Home/$Name" ] || continue
        Target=$(readlink "$Home/$Name")
        case "$Target" in
            *OneDrive*) echo "$Name -> $Target" ;;
        esac
    done
}

# PIDs of every process whose executable lives inside the OneDrive app bundle: the app, its File Provider and Finder
# extensions, the launcher and the updater. Matches the start of the executable path only, so a process that merely
# mentions the path in its arguments is never hit.
OneDrivePids() {
    ps -axo pid=,comm= | awk -v Prefix="$AppPath/" '{ Pid = $1; $1 = ""; sub(/^ +/, ""); if (index($0, Prefix) == 1) print Pid }'
}

StopOneDriveProcesses() {
    local Pids
    Pids=$(OneDrivePids)
    [ -n "$Pids" ] || return 0
    # shellcheck disable=SC2086
    kill $Pids 2>/dev/null
    sleep 2
    Pids=$(OneDrivePids)
    # shellcheck disable=SC2086
    [ -z "$Pids" ] || kill -9 $Pids 2>/dev/null
    return 0
}

# Writes the machine-wide block through cfprefsd (export, edit a copy, import) so the preferences cache stays
# coherent and the existing keys in the domain are kept. A pre-existing AllowTenantList or BlockTenantList is
# replaced: Microsoft documents that the two must not be combined, and any real tenant left in an allow list would
# keep that tenant syncing.
WritePolicy() {
    local Copy
    Copy=$(mktemp /tmp/onedrive-policy.XXXXXX) || return 1
    if ! defaults export "$PolicyDomain" "$Copy" 2>/dev/null; then
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
            '<plist version="1.0"><dict/></plist>' > "$Copy"
    fi
    /usr/libexec/PlistBuddy -c "Delete :AllowTenantList" "$Copy" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Delete :BlockTenantList" "$Copy" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Delete :DisablePersonalSync" "$Copy" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Delete :KFMBlockOptIn" "$Copy" >/dev/null 2>&1
    /usr/libexec/PlistBuddy \
        -c "Add :AllowTenantList dict" \
        -c "Add :AllowTenantList:$NoTenant bool true" \
        -c "Add :DisablePersonalSync bool true" \
        -c "Add :KFMBlockOptIn integer 1" \
        "$Copy" >/dev/null || { rm -f "$Copy"; return 1; }
    defaults import "$PolicyDomain" "$Copy"
    local Result=$?
    rm -f "$Copy"
    chmod 644 "$PolicyDomain.plist" 2>/dev/null
    return $Result
}

PolicyInPlace() {
    [ "$(defaults read "$PolicyDomain" DisablePersonalSync 2>/dev/null)" = "1" ] || return 1
    defaults read "$PolicyDomain" AllowTenantList 2>/dev/null | grep -q "$NoTenant" || return 1
    [ "$(defaults read "$PolicyDomain" AllowTenantList 2>/dev/null | grep -c '=')" = "1" ]
}

# Reports an Office for Mac install that would put OneDrive back if the Office suite installer runs again.
CheckOfficeExclusion() {
    local App Found=false
    for App in Word Excel PowerPoint Outlook; do
        [ -d "/Applications/Microsoft $App.app" ] && Found=true
    done
    $Found || return 0
    if [ "$(defaults read "/Library/Managed Preferences/com.microsoft.office" InstallOneDrive 2>/dev/null)" != "0" ]; then
        Log "Office for Mac is installed without the InstallOneDrive = false configuration profile, so reinstalling the Office suite would add OneDrive back (the sync block keeps it from syncing). To stop that at the source, deploy com.microsoft.office InstallOneDrive = false through MDM." Warning
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

$DryRun && Log "DRY RUN - nothing will be changed."

# --- Survey ---
Users=$(ListUsers)
Blocked=""
while IFS='|' read -r Name Uid Home; do
    [ -n "$Name" ] || continue
    Folders=$(SyncFolders "$Home" | tr '\n' ';' | sed 's/;$//; s/;/; /g')
    Redirects=$(FolderBackupRedirects "$Home" | tr '\n' ';' | sed 's/;$//; s/;/; /g')
    Log "$Name: ${Folders:-no OneDrive sync folder}"
    if [ -n "$Redirects" ]; then
        if $IncludeFolderBackupUsers; then
            Log "$Name: Folder Backup is on ($Redirects). Those folders will stay inside the OneDrive folder, showing only files stored locally." Warning
        else
            Log "$Name: Folder Backup is on ($Redirects). Have them stop Folder Backup and move their files back first, or rerun with --include-folder-backup-users." Warning
            Blocked="$Blocked $Name"
        fi
    fi
done <<< "$Users"

if [ -n "$Blocked" ]; then
    Log "Nothing was changed: OneDrive is shared by every account on this Mac, and Folder Backup is on for:$Blocked. Log: $LogFile" Warning
    exit 1
fi

# --- App, launchd items, receipts ---
if [ -d "$AppPath" ]; then
    BundleId=$(defaults read "$AppPath/Contents/Info" CFBundleIdentifier 2>/dev/null)
    Log "OneDrive app found: $AppPath ($BundleId, version $(defaults read "$AppPath/Contents/Info" CFBundleShortVersionString 2>/dev/null))"
fi

Change "Stop OneDrive processes" StopOneDriveProcesses

for Plist in /Library/LaunchDaemons/com.microsoft.OneDrive*.plist /Library/LaunchDaemons/com.microsoft.SyncReporter.plist; do
    [ -e "$Plist" ] || continue
    if launchctl print "system/$(basename "$Plist" .plist)" >/dev/null 2>&1; then
        Change "Unload $Plist" launchctl bootout system "$Plist"
    fi
    RemoveSafely "$Plist"
done
for Plist in /Library/LaunchAgents/com.microsoft.OneDrive*.plist /Library/LaunchAgents/com.microsoft.SyncReporter.plist; do
    [ -e "$Plist" ] || continue
    while IFS='|' read -r Name Uid Home; do
        [ -n "$Uid" ] || continue
        if launchctl print "gui/$Uid/$(basename "$Plist" .plist)" >/dev/null 2>&1; then
            Change "Unload $(basename "$Plist") for $Name" launchctl bootout "gui/$Uid" "$Plist"
        fi
    done <<< "$Users"
    RemoveSafely "$Plist"
done
for Helper in /Library/PrivilegedHelperTools/com.microsoft.OneDrive*; do
    RemoveSafely "$Helper"
done

# The updater can relaunch the app between the first stop and the delete.
$DryRun || StopOneDriveProcesses
RemoveSafely "$AppPath"

for Receipt in $(pkgutil --pkgs 2>/dev/null | grep -i 'com\.microsoft\.OneDrive'); do
    Change "Forget installer receipt $Receipt" pkgutil --forget "$Receipt"
done

# --- Per-user leftovers (only locations macOS does not privacy-protect) ---
while IFS='|' read -r Name Uid Home; do
    [ -n "$Home" ] || continue
    for Leftover in "$Home"/Library/Caches/com.microsoft.OneDrive* "$Home/Library/Caches/com.microsoft.SharePoint-mac" \
                    "$Home/Library/Logs/OneDrive" "$Home/Library/Application Support/OneDrive" \
                    "$Home"/Library/Application\ Support/com.microsoft.OneDrive* \
                    "$Home"/Library/Saved\ Application\ State/com.microsoft.OneDrive* \
                    "$Home"/Library/LaunchAgents/com.microsoft.OneDrive*.plist; do
        RemoveSafely "$Leftover"
    done
done <<< "$Users"

# --- Sync block ---
if $SkipPolicy; then
    Log "Skipping the machine-wide sync block (--skip-policy). A reinstalled OneDrive will sync again." Warning
elif PolicyInPlace; then
    Log "Machine-wide sync block is already in place."
else
    Change "Write machine-wide sync block to $PolicyDomain.plist (DisablePersonalSync, AllowTenantList with no real tenant, KFMBlockOptIn)" WritePolicy \
        || Failed=true
fi

CheckOfficeExclusion

# --- Verification ---
if ! $DryRun; then
    if [ -e "$AppPath" ]; then
        Log "$AppPath is still present. The RMM agent may need App Management / Full Disk Access granted through MDM." Error
        Failed=true
    fi
    if [ -n "$(OneDrivePids)" ]; then
        Log "OneDrive processes are still running." Error
        Failed=true
    fi
    if ! $SkipPolicy && ! PolicyInPlace; then
        Log "The machine-wide sync block did not read back as expected." Error
        Failed=true
    fi
fi

if $Failed; then
    Log "Finished with errors. Log: $LogFile" Error
    exit 1
fi
if $DryRun; then
    Log "Dry run complete. Log: $LogFile" Success
else
    Log "OneDrive removed and blocked. Log: $LogFile" Success
fi
exit 0

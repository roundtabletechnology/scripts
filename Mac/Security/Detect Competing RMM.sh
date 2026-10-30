#!/usr/bin/env bash
# ==============================================================================
# .SYNOPSIS
#   Detects competing RMM agents and remote access tools on macOS.
#
# .DESCRIPTION
#   NinjaOne agents cannot be installed by more than one MSP on the same device,
#   and other MSPs' agents (ConnectWise Automate, Datto RMM, Kaseya, N-able,
#   Atera, Syncro, Addigy, ...) and remote access tools (ScreenConnect, AnyDesk,
#   TeamViewer, ...) are a sign the device is still managed by someone else.
#
#   Each product in the catalog is classified as:
#     RMM            A management agent from another MSP / RMM vendor. Treat as a
#                    conflict to resolve before or during onboarding.
#     Remote access  A remote support or remote control tool. Often legitimate
#                    (a client's own TeamViewer), but worth reviewing.
#
#   Evidence is gathered once, then matched against the catalog:
#     1. Application bundles  /Applications, /Applications/<folder>, ~/Applications
#     2. launchd jobs         LaunchDaemons / LaunchAgents (system and every user)
#     3. Installer receipts   pkgutil --pkgs
#     4. Running processes    process names
#     5. Install folders      /Library, /Library/Application Support, /opt,
#                             /usr/local, plus explicit paths per product
#
#   A product is "Active" when a matching process is running and "Installed"
#   when only files, receipts or launchd jobs remain.
#
#   The NinjaOne agent itself is reported as informational and is never counted
#   as a conflict, since this script normally runs from it. Use --pre-onboarding
#   when scanning a Mac that is NOT yet under your NinjaOne instance: any NinjaOne
#   agent found is then another MSP's.
#
#   The result is written to a NinjaOne custom device field (default:
#   competingRmm) and printed to stdout for activity logs.
#
# .NOTES
#   Designed for NinjaOne RMM deployment (SYSTEM / root level). Also runs
#   directly from a terminal with sudo. Compatible with the stock macOS bash 3.2.
#
#   Options (flags win over nothing; environment variables are also honoured):
#     --pre-onboarding    Treat a NinjaOne agent as a competing RMM.
#                         Env: PRE_ONBOARDING (true/1)
#     --ignore "A,B"      Product names to leave out, for tools your own company
#                         uses (e.g. "ScreenConnect,Splashtop"). Case-insensitive
#                         substring match on the names printed in the output.
#                         Env: IGNORE_PRODUCTS
#     --fail-on-detect    Exit 2 when a competing RMM (not just a remote access
#                         tool) is found, so the run can be a NinjaOne condition.
#                         Env: FAIL_ON_DETECT (true/1)
#
#   Environment Variables (NinjaOne / RMM):
#     NINJA_FIELD_NAME  - (optional) Custom field to write the result into.
#                         Defaults to "competingRmm". Set to empty to skip.
#
#   Exit codes: 0 = scan completed (whether or not anything was found),
#               1 = the scan failed, 2 = --fail-on-detect and a competing RMM found.
#
#   Several macOS footprints below (launchd labels and install folders) are
#   matched on vendor keywords rather than exact paths, because vendors vary them
#   per tenant. Validate any product you depend on against a lab install.
#
#   Not covered on purpose: overlay networks / tunnels (Tailscale, ZeroTier,
#   ngrok), built-in tools (Apple Remote Desktop, Screen Sharing), and MDM
#   platforms (see "Detect MDM Enrollment.sh").
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()    { echo "[INFO]    $*"; }
log_success() { echo "[SUCCESS] $*"; }
log_warn()    { echo "[WARN]    $*"; }
log_error()   { echo "[ERROR]   $*" >&2; }

# ------------------------------------------------------------------------------
# Options
# ------------------------------------------------------------------------------
is_truthy() { echo "$1" | grep -qiE '^(true|1|yes)$'; }

PRE_ONBOARDING_MODE=0
FAIL_ON_DETECT_MODE=0
IGNORE_LIST="${IGNORE_PRODUCTS:-}"
is_truthy "${PRE_ONBOARDING:-}" && PRE_ONBOARDING_MODE=1
is_truthy "${FAIL_ON_DETECT:-}" && FAIL_ON_DETECT_MODE=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pre-onboarding) PRE_ONBOARDING_MODE=1 ;;
        --fail-on-detect) FAIL_ON_DETECT_MODE=1 ;;
        --ignore)
            if [[ $# -lt 2 ]]; then log_error "--ignore needs a value."; exit 1; fi
            IGNORE_LIST="${IGNORE_LIST:+$IGNORE_LIST,}$2"; shift ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ------------------------------------------------------------------------------
# Root check (needed to read every user's launch agents and all processes)
# ------------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    log_error "This script must be run as root (sudo)."
    exit 1
fi

NINJA_FIELD_NAME="${NINJA_FIELD_NAME-competingRmm}"
NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"

# ==============================================================================
# Evidence collection - gathered once, matched against every product
# ==============================================================================

# names_in <dir>... : one entry per line (basename, without .app / .plist)
names_in() {
    local d
    for d in "$@"; do
        [[ -d "$d" ]] || continue
        ls -1 "$d" 2>/dev/null
    done | sed -e 's/\.app$//' -e 's/\.plist$//'
}

USER_HOMES=$(ls -1d /Users/*/ 2>/dev/null | sed 's:/$::' | grep -v -E '/(Shared|Guest)$')

APPS=$( { names_in /Applications
          for h in $USER_HOMES; do names_in "$h/Applications"; done; } )

LAUNCHD=$( { names_in /Library/LaunchDaemons /Library/LaunchAgents
             for h in $USER_HOMES; do names_in "$h/Library/LaunchAgents"; done; } )

PKGS=$(pkgutil --pkgs 2>/dev/null)

PROCS=$(ps -axco command 2>/dev/null)

FOLDERS=$(names_in /Library "/Library/Application Support" /opt /usr/local)

# ==============================================================================
# Product catalog
#
#   One product per line:  Name # Type # Regex # Path;Path;...
#
#   Type   RMM, Remote (remote access) or Own (NinjaOne, see description).
#   Regex  Case-insensitive ERE tested against every name gathered above. Built
#          from B (a word boundary) plus vendor keywords. Keep it specific: it
#          is the main cause of false positives.
#   Paths  Explicit globs (spaces are fine) checked as-is.
#
# Sources: vendor documentation, the LOLRMM catalog (lolrmm.io), and agent
# footprints observed on managed devices. Add new products at the bottom of the
# matching section.
# ==============================================================================
B='(^|[._ -])'
E='([._ -]|$)'

CATALOG=$(cat <<EOF
NinjaOne#Own#${B}(ninjarmm|ninjaone|ncstreamer|ninjaremote)#/Applications/NinjaRMMAgent;/Applications/NinjaRemote*
ConnectWise Automate (LabTech)#RMM#${B}(labtech|ltechagent|ltsvc|connectwise\.automate)#/usr/local/ltechagent
ConnectWise RMM (Continuum)#RMM#${B}(continuum|itsplatform|saaz)#
Datto RMM (CentraStage)#RMM#${B}(centrastage|aemagent|cagservice|datto\.rmm|dattormm)#/Applications/CentraStage*;/Library/Application Support/CentraStage*
Kaseya VSA#RMM#${B}(kaseya|agentmon)#/Library/Kaseya*;/Applications/Kaseya*
N-able (N-central / RMM / SolarWinds MSP)#RMM#${B}(n-able|n-central|ncentral|solarwindsmsp|solarwinds\.msp|advanced.?monitoring)#/Library/N-able*
Atera#RMM#${B}atera#/Applications/AteraAgent*;/Library/Application Support/Atera*
Syncro (Kabuto)#RMM#${B}(syncro|kabuto|repairtech)#/Applications/Syncro*;/Library/Application Support/Syncro*
SuperOps#RMM#${B}superops#
Pulseway#RMM#${B}(pulseway|pcmonitor)#/Applications/Pulseway*
Level#RMM#${B}(io\.level|level\.io)|^level(-agent| agent)?$#/Applications/Level*
ManageEngine Endpoint Central / RMM Central#RMM#${B}(manageengine|desktopcentral|uems)#/Library/Application Support/ManageEngine*
Tactical RMM#RMM#${B}(tacticalagent|tacticalrmm|tactical-rmm)#/opt/tacticalagent;/Library/Application Support/tacticalagent
Addigy#RMM#${B}addigy#/Library/Addigy;/Library/Application Support/Addigy
Itarian / Comodo One#RMM#${B}(itarian|comodo\.itsm|comodo.?one)#
Quest KACE#RMM#${B}(kace|kbox)${E}#/Library/Application Support/Quest/KACE*
PDQ Connect#RMM#${B}pdq.?connect#
Naverisk#RMM#${B}naverisk#
Domotz#RMM#${B}domotz#
GoTo Resolve (GoToAssist Corporate)#RMM#${B}(gotoresolve|goto\.resolve|gotoassist|gotoopener|goto-opener)#
Faronics#RMM#${B}faronics#
Absolute (Computrace)#RMM#${B}(absolute\.software|absolutesoftware|computrace|rpcnet)#
Ivanti / LANDesk#RMM#${B}(landesk|ivanti\.(agent|endpoint))#/Library/Application Support/LANDesk*
Tanium#RMM#${B}tanium#/Library/Tanium
Zabbix Agent#RMM#${B}zabbix#
GLPI / OCS Inventory Agent#RMM#${B}(glpi-agent|glpi\.agent|ocsinventory)#
Senso.cloud#RMM#${B}senso\.cloud#
ScreenConnect (ConnectWise Control)#Remote#${B}(connectwisecontrol|screenconnect)#/opt/screenconnect*;/opt/connectwisecontrol*
AnyDesk#Remote#${B}(anydesk|philandro)#/Applications/AnyDesk.app
TeamViewer#Remote#${B}teamviewer#/Applications/TeamViewer*
Splashtop#Remote#${B}splashtop#/Applications/Splashtop*
LogMeIn / GoTo#Remote#${B}(logmein|gotomypc|lmirescue)#/Applications/LogMeIn*
RustDesk#Remote#${B}rustdesk#/Applications/RustDesk.app
Zoho Assist#Remote#${B}(zoho.?assist|zohomeeting|zohors)#
BeyondTrust (Bomgar)#Remote#${B}(beyondtrust|bomgar)#
N-able Take Control (BeAnywhere)#Remote#${B}(take.?control|beanywhere|basupport|basup)#
MeshCentral (Mesh Agent)#Remote#${B}(meshagent|mesh\.agent|meshcentral)#/usr/local/mesh_services*
SimpleHelp#Remote#${B}simplehelp#/Library/Application Support/SimpleHelp*
NetSupport Manager#Remote#${B}netsupport#
DWService (DWAgent)#Remote#${B}dwagent#
Chrome Remote Desktop#Remote#${B}(chromeremotedesktop|chrome-remote-desktop|chromoting)#/Applications/Chrome Remote Desktop Host Uninstaller.app
RemotePC#Remote#${B}remotepc#
Remote Utilities#Remote#${B}(remoteutilities|remote.utilities)#
VNC (RealVNC / TightVNC)#Remote#${B}(realvnc|vnc.?server|vnc.?connect|tightvnc)#/Applications/RealVNC*
NoMachine#Remote#${B}nomachine#/Applications/NoMachine*
Jump Desktop#Remote#${B}jump.?desktop#
Supremo#Remote#${B}supremo#
HopToDesk#Remote#${B}hoptodesk#
Iperius Remote#Remote#${B}iperius#
ISL Online / ISL Light#Remote#${B}(isl.?light|isl.?online|islalwayson)#
AweSun / SunLogin / ToDesk#Remote#${B}(todesk|sunlogin|awesun)#
AeroAdmin / Ammyy Admin#Remote#${B}(aeroadmin|ammyy)#
GetScreen / UltraViewer#Remote#${B}(getscreen|ultraviewer)#
Parsec#Remote#${B}parsec${E}#
EOF
)

# ==============================================================================
# Matching
# ==============================================================================
ignored() {
    local item
    [[ -z "$IGNORE_LIST" ]] && return 1
    local IFS=','
    for item in $IGNORE_LIST; do
        item=$(echo "$item" | sed -e 's/^ *//' -e 's/ *$//')
        [[ -z "$item" ]] && continue
        if echo "$1" | grep -qiF "$item"; then return 0; fi
    done
    return 1
}

# hits <label> <regex> <names> : prints "label 'name'" for each match
hits() {
    local label="$1" regex="$2" names="$3" line
    echo "$names" | grep -iE -e "$regex" 2>/dev/null | sort -u | while IFS= read -r line; do
        [[ -n "$line" ]] && echo "$label '$line'"
    done
}

RMM_BLOCK=""    RMM_NAMES=""    RMM_COUNT=0
REMOTE_BLOCK="" REMOTE_NAMES="" REMOTE_COUNT=0
OWN_BLOCK=""

log_info "Scanning for competing RMM agents and remote access tools..."

while IFS='#' read -r name type regex paths; do
    [[ -z "$name" ]] && continue
    ignored "$name" && continue

    evidence=""
    evidence="${evidence}$(hits 'app' "$regex" "$APPS")"$'\n'
    evidence="${evidence}$(hits 'launchd job' "$regex" "$LAUNCHD")"$'\n'
    evidence="${evidence}$(hits 'installer receipt' "$regex" "$PKGS")"$'\n'
    evidence="${evidence}$(hits 'folder' "$regex" "$FOLDERS")"$'\n'

    active=0
    proc_hits=$(hits 'process' "$regex" "$PROCS")
    if [[ -n "$proc_hits" ]]; then
        evidence="${evidence}${proc_hits}"$'\n'
        active=1
    fi

    if [[ -n "$paths" ]]; then
        IFS=';' read -r -a path_list <<< "$paths"
        for p in "${path_list[@]}"; do
            [[ -z "$p" ]] && continue
            while IFS= read -r found; do
                [[ -n "$found" ]] && evidence="${evidence}path '$found'"$'\n'
            done < <(compgen -G "$p" 2>/dev/null)
        done
    fi

    evidence=$(echo "$evidence" | grep -v '^$' | awk '!seen[$0]++')
    [[ -z "$evidence" ]] && continue

    state="Installed"; [[ "$active" -eq 1 ]] && state="Active"

    if [[ "$type" == "Own" && "$PRE_ONBOARDING_MODE" -eq 1 ]]; then type="RMM"; fi

    block="  - ${name} [${state}]"$'\n'"$(echo "$evidence" | sed 's/^/      /')"$'\n'
    label="$name"; [[ "$state" == "Installed" ]] && label="$name (inactive)"

    case "$type" in
        RMM)    RMM_BLOCK="${RMM_BLOCK}${block}";       RMM_NAMES="${RMM_NAMES:+$RMM_NAMES, }${label}";       RMM_COUNT=$((RMM_COUNT + 1)) ;;
        Remote) REMOTE_BLOCK="${REMOTE_BLOCK}${block}"; REMOTE_NAMES="${REMOTE_NAMES:+$REMOTE_NAMES, }${label}"; REMOTE_COUNT=$((REMOTE_COUNT + 1)) ;;
        Own)    OWN_BLOCK="${OWN_BLOCK}${block}" ;;
    esac
done <<< "$CATALOG"

# ==============================================================================
# Output summary
# ==============================================================================
echo ""
echo "============================================================"
echo "Competing RMM / Remote Access Detection"
[[ "$PRE_ONBOARDING_MODE" -eq 1 ]] && echo "(pre-onboarding mode: NinjaOne agents count as competing)"
[[ -n "$IGNORE_LIST" ]] && echo "(ignored: ${IGNORE_LIST})"
echo "============================================================"

[[ "$RMM_COUNT" -gt 0 ]]    && { echo "Competing RMM agents:"; printf '%s' "$RMM_BLOCK"; }
[[ "$REMOTE_COUNT" -gt 0 ]] && { echo "Remote access tools:";  printf '%s' "$REMOTE_BLOCK"; }
[[ -n "$OWN_BLOCK" ]]       && { echo "Own agent (informational):"; printf '%s' "$OWN_BLOCK"; }
if [[ "$RMM_COUNT" -eq 0 && "$REMOTE_COUNT" -eq 0 ]]; then
    echo "No competing RMM agents or remote access tools detected."
fi

RESULT=""
[[ "$RMM_COUNT" -gt 0 ]]    && RESULT="RMM: ${RMM_NAMES}"
[[ "$REMOTE_COUNT" -gt 0 ]] && RESULT="${RESULT:+$RESULT | }Remote access: ${REMOTE_NAMES}"
[[ -z "$RESULT" ]] && RESULT="None detected"

echo "------------------------------------------------------------"
echo "Reported value: ${RESULT}"
echo "============================================================"

# ==============================================================================
# Write to NinjaOne custom field
# ==============================================================================
if [[ -n "$NINJA_FIELD_NAME" ]]; then
    if [[ -x "$NINJA_CLI" ]]; then
        if "$NINJA_CLI" set "$NINJA_FIELD_NAME" "$RESULT" 2>/dev/null; then
            log_success "Wrote '${RESULT}' to Ninja field '${NINJA_FIELD_NAME}'."
        else
            log_warn "Could not write to Ninja field '${NINJA_FIELD_NAME}'."
        fi
    else
        log_warn "ninjarmm-cli not found at ${NINJA_CLI} - skipping Ninja field write."
    fi
fi

if [[ "$FAIL_ON_DETECT_MODE" -eq 1 && "$RMM_COUNT" -gt 0 ]]; then exit 2; fi
exit 0

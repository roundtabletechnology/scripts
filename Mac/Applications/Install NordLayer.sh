#!/bin/bash
# Install NordLayer [MAC]
# Installs the NordLayer VPN client via NinjaOne, presetting the organization ID
# from the Ninja custom field "nordlayerorgid", then drops a SettingsConfig.plist
# that appends the trusted Wi-Fi networks from the comma-separated Ninja custom
# field "NordTrustedNetworks" into each user's NordLayer container.
#
# NordLayer docs:
#   https://help.nordlayer.com/docs/guide-to-presetting-organization-id-in-nordlayer
#   https://help.nordlayer.com/docs/how-to-preset-nordlayer-application-settings
#
# Notes:
# - The org ID is set as an extended attribute on the .pkg and only applies to a
#   first-time install, so it is skipped when NordLayer is already installed.
# - SettingsConfig.plist lives in a per-user sandbox container. NordLayer reads
#   it at launch and every 5 minutes, applies it, then deletes it. If a user's
#   container doesn't exist yet (app never launched), the app is launched for
#   the logged-in user so macOS creates it; other users are skipped.
# - Writing into another app's container needs Full Disk Access for the Ninja
#   agent on macOS 14+.

# Configuration
NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"
ORG_ID_FIELD="nordlayerorgid"
TRUSTED_NETWORKS_FIELD="NordTrustedNetworks"
DOWNLOAD_URL="https://downloads.nordlayer.com/mac/latest/NordLayer.pkg"
APP_PATH="/Applications/NordLayer.app"
BUNDLE_ID="com.nordvpn.macos.teams"
CONFIG_SUBPATH="Library/Containers/$BUNDLE_ID/Data/Library/Application Support/$BUNDLE_ID"
CONTAINER_WAIT_SECONDS=60

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root."
    exit 1
fi

if [[ ! -x "$NINJA_CLI" ]]; then
    echo "Error: ninjarmm-cli not found at $NINJA_CLI"
    exit 1
fi

org_id=$("$NINJA_CLI" get "$ORG_ID_FIELD" 2>/dev/null | tr -d '[:space:]')
trusted_raw=$("$NINJA_CLI" get "$TRUSTED_NETWORKS_FIELD" 2>/dev/null)

# Split the comma-separated SSIDs into an array, trimming surrounding whitespace
trusted_networks=()
IFS=',' read -r -a parts <<< "$trusted_raw"
for ssid in "${parts[@]}"; do
    ssid="${ssid#"${ssid%%[![:space:]]*}"}"
    ssid="${ssid%"${ssid##*[![:space:]]}"}"
    [[ -n "$ssid" ]] && trusted_networks+=("$ssid")
done

# ---- Install ----
if [[ -d "$APP_PATH" ]]; then
    echo "NordLayer already installed - skipping install (org ID only applies to a first-time install)."
else
    if [[ -z "$org_id" ]]; then
        echo "Error: Ninja custom field '$ORG_ID_FIELD' is empty."
        exit 1
    fi

    work_dir=$(mktemp -d)
    trap 'rm -rf "$work_dir"' EXIT
    pkg="$work_dir/NordLayer.pkg"

    echo "Downloading NordLayer..."
    if ! curl -fsSL "$DOWNLOAD_URL" -o "$pkg"; then
        echo "Error: failed to download $DOWNLOAD_URL"
        exit 1
    fi

    if ! pkgutil --check-signature "$pkg" >/dev/null 2>&1; then
        echo "Error: downloaded package failed signature check."
        exit 1
    fi

    if ! xattr -w com.nordlayer.organization_id "$org_id" "$pkg"; then
        echo "Error: failed to set organization ID on the package."
        exit 1
    fi
    echo "Preset organization ID: $org_id"

    echo "Installing NordLayer..."
    if ! installer -pkg "$pkg" -target / ; then
        echo "Error: NordLayer install failed."
        exit 1
    fi
    echo "NordLayer installed."
fi

# ---- Trusted networks ----
if [[ ${#trusted_networks[@]} -eq 0 ]]; then
    echo "Ninja custom field '$TRUSTED_NETWORKS_FIELD' is empty - no trusted networks to set."
    exit 0
fi

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "$s"
}

plist_content='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AppendTrustedNetworks</key>
    <array>
'
for ssid in "${trusted_networks[@]}"; do
    plist_content+="        <string>$(xml_escape "$ssid")</string>"$'\n'
done
plist_content+='    </array>
</dict>
</plist>
'

console_user=$(stat -f '%Su' /dev/console)

write_config() {
    local user="$1" home="$2"
    local config_dir="$home/$CONFIG_SUBPATH"
    local config_file="$config_dir/SettingsConfig.plist"

    mkdir -p "$config_dir" || return 1
    printf '%s' "$plist_content" > "$config_file" || return 1
    if ! plutil -lint -s "$config_file"; then
        rm -f "$config_file"
        return 1
    fi
    chown "$user":staff "$config_file"
    chmod 644 "$config_file"
}

echo "Trusted networks: $(IFS=','; echo "${trusted_networks[*]}")"

# Real local users (UID 501+) with a home under /Users
while IFS= read -r user; do
    home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [[ "$home" == /Users/* && -d "$home" ]] || continue

    container="$home/Library/Containers/$BUNDLE_ID"
    if [[ ! -d "$container" && "$user" == "$console_user" ]]; then
        echo "Launching NordLayer for $user to create its app container..."
        launchctl asuser "$(id -u "$user")" sudo -u "$user" open -a "$APP_PATH"
        for (( i = 0; i < CONTAINER_WAIT_SECONDS; i++ )); do
            [[ -d "$container/Data/Library" ]] && break
            sleep 1
        done
    fi

    if [[ ! -d "$container" ]]; then
        echo "Skipped $user: NordLayer has not been launched for this user yet."
        continue
    fi

    if write_config "$user" "$home"; then
        echo "Wrote trusted networks config for $user."
    else
        echo "Failed to write trusted networks config for $user (does the Ninja agent have Full Disk Access?)."
    fi
done < <(dscl . -list /Users UniqueID | awk '$2 >= 501 {print $1}')

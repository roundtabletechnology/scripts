#!/bin/bash

# Developed by Jeff and Gemini
# NordLayer Install [MAC]
# Get latest version of NordLayer VPN and install it. 
# Uses custom variables for Nord Site ID and Nord Trusted WiFi networks.

# ==============================================================================
# ENVIRONMENT & NINJARMM-CLI PATH VALIDATION
# ==============================================================================
# Define the definitive systemic path for the NinjaOne Mac Agent CLI utility
NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"

echo "=========================================================================="
echo " Starting NordLayer Managed Deployment via NinjaRMM Native CLI"
echo "=========================================================================="

# Check that the runtime environment is elevated to root
if [ "$EUID" -ne 0 ]; then
   echo "ERROR: This script must be executed as root by the NinjaRMM Agent."
   exit 1
fi

# Confirm the native CLI engine is present and executable before proceeding
if [ ! -x "$NINJA_CLI" ]; then
    echo "ERROR: NinjaRMM CLI binary not found or not executable at $NINJA_CLI"
    echo "Please ensure the target device has the active NinjaOne Mac Agent installed."
    exit 1
fi

# ==============================================================================
# FIELD RETRIEVAL & INITIAL VALIDATION
# ==============================================================================
echo "Querying NinjaRMM custom attributes..."

# Extract the values dynamically from the Ninja custom fields database
RAW_ORG_ID=$("$NINJA_CLI" get "nordlayerorgid" 2>/dev/null)
RAW_TRUSTED_NETWORKS=$("$NINJA_CLI" get "NordTrustedNetworks" 2>/dev/null)

# Define operational internal variables (Using the updated, working URL)
INSTALLER_URL="https://downloads.nordlayer.com/mac/latest/NordLayer.pkg"
INSTALLER_PATH="/tmp/NordLayer.pkg"

# Helper validation loop function to strip and catch empty/null outputs
is_valid_variable() {
    local var_value="$1"
    # Filter true blanks, null strings, or empty value indicators
    if [ -z "$var_value" ] || [ "$var_value" = "null" ] || [ "$var_value" = '$' ]; then
        return 1
    fi
    return 0
}

# Resolve active console (GUI desktop) user to bind target sandboxed directories
CURRENT_USER=$(stat -f '%Su' /dev/console)
if [ -z "$CURRENT_USER" ] || [ "$CURRENT_USER" = "root" ]; then
    echo "WARNING: No active GUI console user resolved. Configurations cannot be mapped."
    CURRENT_USER=""
fi

# ==============================================================================
# STAGE 1: DOWNLOAD CLEAN BUNDLE
# ==============================================================================
echo "Downloading fresh system package layer directly from NordLayer..."
if curl -L -s --max-time 600 -o "$INSTALLER_PATH" "$INSTALLER_URL"; then
    echo "Binary cache successfully written to $INSTALLER_PATH."
else
    echo "ERROR: Transfer failed from target source $INSTALLER_URL"
    exit 1
fi

# ==============================================================================
# STAGE 2: PROCESS & ALLOCATE ORGANIZATION ID
# ==============================================================================
if is_valid_variable "$RAW_ORG_ID"; then
    echo "Validated Organization ID retrieved: '$RAW_ORG_ID'. Assigning package header..."
    
    # Preset the package extended attributes so the login screen autofills the Org ID
    if xattr -w com.nordlayer.organization_id "$RAW_ORG_ID" "$INSTALLER_PATH"; then
        echo "Successfully mapped unique organization metadata directly to binary."
    else
        echo "WARNING: Attribute utility failed to apply metadata payload."
    fi
else
    echo "Organization ID custom field data empty or unset. Bypassing metadata wrapper allocation."
fi

# ==============================================================================
# STAGE 3: CONFIGURE SAFE NETWORKS AND AUTO-CONNECT BEHAVIORS
# ==============================================================================
if is_valid_variable "$RAW_TRUSTED_NETWORKS"; then
    echo "Validated Trusted Networks retrieved: '$RAW_TRUSTED_NETWORKS'"
    
    if [ -n "$CURRENT_USER" ]; then
        # Define structural application sandbox profile path
        PLIST_DIR="/Users/$CURRENT_USER/Library/Containers/com.nordvpn.macos.teams/Data/Library/Application Support/com.nordvpn.macos.teams"
        PLIST_PATH="$PLIST_DIR/SettingsConfig.plist"
        
        echo "Constructing secure context profile tree for user path: /Users/$CURRENT_USER"
        mkdir -p "$PLIST_DIR"
        
        # Parse the comma-separated trusted networks into XML <string> tags
        FORMATTED_NETWORKS=""
        IFS=',' read -ra NETWORKS_ARRAY <<< "$RAW_TRUSTED_NETWORKS"
        for network in "${NETWORKS_ARRAY[@]}"; do
            # Safely trim leading and trailing spaces without modifying internal spaces
            CLEAN_SSID=$(echo "$network" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [ -n "$CLEAN_SSID" ]; then
                FORMATTED_NETWORKS="${FORMATTED_NETWORKS}        <string>${CLEAN_SSID}</string>
"
            fi
        done
        
        # Deploy xml plist template ensuring safe networks disable auto-connect loops
        # NOTE: Adding networks to 'AppendTrustedNetworks' tells NordLayer to completely 
        # bypass and turn off Auto-Connect behaviors while active on those SSIDs.
        cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AppendTrustedNetworks</key>
    <array>
${FORMATTED_NETWORKS}    </array>
</dict>
</plist>
EOF

        # Hand ownership back to the desktop user context so the engine sandbox can read it
        chown -R "$CURRENT_USER":staff "/Users/$CURRENT_USER/Library/Containers/com.nordvpn.macos.teams"
        echo "Configuration verified and locked at user tier path: $PLIST_PATH"
    else
        echo "WARNING: Safe zone network profiles found, but skipping profile output because no active desktop user was identified."
    fi
else
    echo "Trusted Networks custom field data empty or unset. Bypassing trusted wifi addition"
fi

# ==============================================================================
# STAGE 4: TRIGGER NATIVE INSTALLATION
# ==============================================================================
echo "Triggering native system target installation utility..."
if installer -pkg "$INSTALLER_PATH" -target /; then
    echo "NordLayer deployment executed and successfully finalized."
    
    # Perform operational housekeeping cleanup
    rm -f "$INSTALLER_PATH"
    exit 0
else
    echo "ERROR: Underpinning OS installation process returned a critical non-zero error."
    exit 1
fi

```
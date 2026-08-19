#!/bin/bash
# Check FileVault status [MAC]
# Checks if FileVault is enabled on Mac, prints it to stdout, and
# publishes it to the Ninja RMM custom field "diskEncryptionStatus".

# Configuration
NINJA_CUSTOM_FIELD="diskEncryptionStatus"
NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"

fv_status=$(fdesetup status)
echo "$fv_status"

# Strip the trailing period, e.g. "FileVault is On." -> "FileVault is On"
fv_value="${fv_status%.}"

if [[ -f "$NINJA_CLI" ]]; then
    # ninjarmm-cli lives in a folder that's inaccessible to non-root users, so
    # writes silently fail unless this script is run as root (SYSTEM, when
    # deployed via NinjaOne; sudo, when run manually for testing).
    if [[ $EUID -ne 0 ]]; then
        echo "Warning: not running as root - ninjarmm-cli set may fail due to permissions."
    fi

    cli_error=$("$NINJA_CLI" set "$NINJA_CUSTOM_FIELD" "$fv_value" 2>&1 >/dev/null)
    if [[ $? -eq 0 ]]; then
        echo "Published '$fv_value' to Ninja custom field: $NINJA_CUSTOM_FIELD"
    else
        echo "Failed to write Ninja custom field '$NINJA_CUSTOM_FIELD': $cli_error"
    fi
else
    echo "ninjarmm-cli not found at $NINJA_CLI - skipping Ninja field write."
fi
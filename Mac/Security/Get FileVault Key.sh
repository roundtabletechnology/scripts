#!/bin/bash

################################################################################
# SYNOPSIS
#     Checks FileVault status and attempts to retrieve recovery key.
#
# DESCRIPTION
#     This script checks FileVault status and attempts to retrieve the recovery
#     key. Note: macOS does not provide a native command to retrieve the 
#     recovery key after FileVault is enabled. The key must be escrowed during
#     setup using an MDM solution or captured at enablement time.
#
# NOTES
#     Requires:
#     - macOS with FileVault enabled
#     - Root/sudo privileges
#     - Ninja RMM agent installed
################################################################################

# Configuration
NINJA_CUSTOM_FIELD="diskEncryptionKey"
NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"

# Publishes a value to the Ninja custom field, skipping quietly if the CLI isn't present
ninja_set() {
    if [[ -f "$NINJA_CLI" ]]; then
        cli_error=$("$NINJA_CLI" set "$NINJA_CUSTOM_FIELD" "$1" 2>&1 >/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "Published '$1' to Ninja custom field: $NINJA_CUSTOM_FIELD"
        else
            echo "Failed to write Ninja custom field '$NINJA_CUSTOM_FIELD': $cli_error"
        fi
    else
        echo "ninjarmm-cli not found at $NINJA_CLI - skipping Ninja field write."
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check if FileVault is enabled
fv_status=$(fdesetup status)

if [[ $fv_status == *"FileVault is Off"* ]]; then
    echo "FileVault is not enabled"
    ninja_set "FileVault Not Enabled"
    exit 0
fi

echo "FileVault Status: On"

# Check if using recovery key
using_recovery=$(fdesetup usingrecoverykey 2>&1)
has_personal=$(fdesetup haspersonalrecoverykey 2>&1)
has_institutional=$(fdesetup hasinstitutionalrecoverykey 2>&1)

echo "Using Recovery Key: $using_recovery"
echo "Has Personal Recovery Key: $has_personal"
echo "Has Institutional Recovery Key: $has_institutional"

# Check for institutional key in FileVaultMaster.keychain
if [[ -f /Library/Keychains/FileVaultMaster.keychain ]]; then
    echo "Institutional recovery keychain found"
    # Note: The actual key is encrypted and cannot be retrieved without the master password
fi

echo ""
echo "WARNING: macOS does not provide a native command to retrieve the FileVault"
echo "recovery key after it has been created. The recovery key is only displayed"
echo "once during FileVault setup."
echo ""
echo "To capture FileVault keys, you need to:"
echo "  1. Use an MDM solution that escrows keys during enablement"
echo "  2. Use 'fdesetup enable' with the -outputplist option to capture the key"
echo "  3. Have users manually record their keys during setup"
echo ""
echo "The key may be stored in:"
echo "  - iCloud Keychain (if that option was selected)"
echo "  - Your organization's MDM system"
echo "  - A text file saved during initial setup"

ninja_set "FileVault Enabled - Key Not Retrievable via CLI"
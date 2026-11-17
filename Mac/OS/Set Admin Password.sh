#!/usr/bin/env bash
# ==============================================================================
# .SYNOPSIS
#   Changes a local macOS admin account's password from its known old password
#   to a new one, keeping its Secure Token, FileVault unlock and login keychain
#   in step.
#
# .DESCRIPTION
#   On APFS Macs an account with a Secure Token has three copies of its password:
#     1. The Open Directory login password (what the login window checks).
#     2. The APFS crypto user / Secure Token (what the FileVault unlock screen
#        checks at boot, and what authorizes FileVault and other token users).
#     3. The login keychain password.
#   A plain *reset* (dscl . -passwd user NEW, or sysadminctl -resetPasswordFor
#   without token credentials) only changes #1. The Mac then boots to a FileVault
#   screen that wants the OLD password, the token can stop working, and the
#   keychain no longer opens. Apple's DTS engineers and macOSLAPS both state the
#   old password must be known to change a Secure Token account safely.
#
#   This script therefore only ever *changes* the password using the old one:
#     1. Reads the username, old password and new password (NinjaOne org custom
#        fields by default).
#     2. If the new password already works, skips the change (safe to re-run on
#        every Mac in the org). If neither password works, stops without
#        touching anything, because a reset would break the Secure Token.
#     3. Changes the password with sysadminctl, authorizing with the account's
#        own token (-adminUser <user> -adminPassword <old>). Falls back to
#        dscl . -passwd <user> <old> <new> if that does not take.
#     4. Verifies the new password at the login layer (dscl -authonly) and that
#        the Secure Token is still ENABLED.
#     5. If the account is an APFS crypto user (Secure Token / FileVault user),
#        confirms the FileVault unlock password is the new one with
#        diskutil apfs changePassphrase. If the unlock password is still the old
#        one, it is moved to the new one here (this is the "system can boot"
#        check).
#     6. Updates the login keychain from old to new. If the keychain uses some
#        other password it is moved aside (kept as a .bak) so the next login
#        creates a fresh one instead of prompting.
#     7. Refreshes the Preboot volume when FileVault is on, so the unlock screen
#        reflects the change.
#
# .NOTES
#   Designed for NinjaOne RMM deployment (runs as root). Also runs directly from
#   a terminal with sudo. Compatible with the stock macOS bash 3.2.
#
#   NinjaOne custom fields (read with ninjarmm-cli get, which returns the value
#   inherited from the organization when the device has none). Secure fields
#   can only be read when the script runs as a NinjaOne automation.
#     clientAdminName   - Text:   admin account short name
#     clientAdminPwOld  - Secure: current (old) password
#     clientAdminPw     - Secure: new password
#
#   Environment variables / NinjaOne script variables (all optional):
#     USERNAME_FIELD       - Field holding the username.     Default clientAdminName
#     OLD_PASSWORD_FIELD   - Field holding the old password. Default clientAdminPwOld
#     NEW_PASSWORD_FIELD   - Field holding the new password. Default clientAdminPw
#     ADMIN_USERNAME, ADMIN_OLD_PASSWORD, ADMIN_NEW_PASSWORD
#                          - Values to use instead of the fields (for running
#                            outside NinjaOne or testing).
#
#   Rolling out a new password across an organization:
#     Put the current password in the old-password field and the new one in the
#     new-password field, then run on every Mac. Macs already on the new
#     password just get verified. Leave the old-password field in place until
#     every Mac has reported success; offline Macs still need it.
#
#   Passwords are passed to sysadminctl, dscl, diskutil and security as
#   arguments, so they are briefly visible to other local processes (ps) while
#   each command runs. macOS offers no non-interactive alternative for these
#   tools. Do not add "set -x" to this script.
#
#   Exit codes: 0 = new password in place and verified (or already in place),
#               1 = failed or could not be verified. Read the log before
#                   rebooting a Mac that returned 1 with FileVault on.
# ==============================================================================

set -o pipefail

NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"

log()  { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
info() { log "INFO" "$1"; }
warn() { log "WARN" "$1"; }
err()  { log "ERROR" "$1" >&2; }

die() {
    err "$1"
    unset OLD_PW NEW_PW
    exit 1
}

# Print a command's captured output indented, skipping blank lines.
print_output() {
    [[ -n "$1" ]] && printf '%s\n' "$1" | sed '/^[[:space:]]*$/d; s/^/    /'
}

# Reads a NinjaOne custom field. Prints nothing when the CLI or field is missing.
read_ninja_field() {
    local name="$1" value
    [[ -n "$name" && -x "$NINJA_CLI" ]] || return 0
    value=$("$NINJA_CLI" get "$name" 2>/dev/null) || return 0
    printf '%s' "${value%$'\r'}"
}

# True when the password is accepted for the account at the login layer.
password_works() {
    dscl . -authonly "$1" "$2" >/dev/null 2>&1
}

secure_token_status() {
    if sysadminctl -secureTokenStatus "$1" 2>&1 | grep -q "ENABLED"; then
        echo "ENABLED"
    else
        echo "DISABLED"
    fi
}

# Device identifier of the volume holding the account's crypto user. On
# Catalina and later that is the Data volume, before that the boot volume.
get_crypto_volume() {
    local mount_point="/"
    if mount | grep -q " on /System/Volumes/Data "; then
        mount_point="/System/Volumes/Data"
    fi
    diskutil info "$mount_point" 2>/dev/null | awk -F': *' '/Device Identifier/ {print $2; exit}'
}

# Changes the account password with the old one. Returns 0 once the new
# password works at the login layer.
change_password() {
    local output

    info "Changing password with sysadminctl (authorized by the account's own Secure Token)."
    output=$(sysadminctl -adminUser "$ADMIN_USER" -adminPassword "$OLD_PW" \
        -resetPasswordFor "$ADMIN_USER" -newPassword "$NEW_PW" 2>&1)
    print_output "$output"
    # sysadminctl often exits 0 on failure, so check the result directly.
    if password_works "$ADMIN_USER" "$NEW_PW"; then
        CHANGE_METHOD="sysadminctl"
        return 0
    fi

    warn "sysadminctl did not change the password. Trying dscl with the old password."
    output=$(dscl . -passwd "/Users/$ADMIN_USER" "$OLD_PW" "$NEW_PW" 2>&1)
    print_output "$output"
    if password_works "$ADMIN_USER" "$NEW_PW"; then
        CHANGE_METHOD="dscl"
        return 0
    fi
    return 1
}

# Confirms the FileVault / Secure Token unlock password is the new one, moving
# it from the old one if it was left behind.
verify_unlock_password() {
    local output

    # Re-wrapping with the same passphrase only succeeds if the new password
    # already unlocks the volume.
    if output=$(diskutil apfs changePassphrase "$CRYPTO_VOLUME" -user "$ADMIN_GUID" \
            -oldPassphrase "$NEW_PW" -newPassphrase "$NEW_PW" 2>&1); then
        info "FileVault unlock password confirmed: the new password unlocks $CRYPTO_VOLUME."
        return 0
    fi
    warn "The new password does not unlock $CRYPTO_VOLUME yet:"
    print_output "$output"

    info "Moving the FileVault unlock password from the old password to the new one."
    if output=$(diskutil apfs changePassphrase "$CRYPTO_VOLUME" -user "$ADMIN_GUID" \
            -oldPassphrase "$OLD_PW" -newPassphrase "$NEW_PW" 2>&1); then
        info "FileVault unlock password synced to the new password."
        return 0
    fi
    print_output "$output"
    return 1
}

# Brings the login keychain over to the new password.
update_login_keychain() {
    local home keychain backup

    home=$(dscl . -read "/Users/$ADMIN_USER" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
    keychain="$home/Library/Keychains/login.keychain-db"
    if [[ -z "$home" || ! -f "$keychain" ]]; then
        info "No login keychain for $ADMIN_USER. Nothing to update."
        return 0
    fi

    # Run as the account so the keychain file keeps its owner.
    if sudo -u "$ADMIN_USER" security set-keychain-password -o "$OLD_PW" -p "$NEW_PW" "$keychain" >/dev/null 2>&1; then
        info "Login keychain password changed to the new password."
        return 0
    fi
    if sudo -u "$ADMIN_USER" security unlock-keychain -p "$NEW_PW" "$keychain" >/dev/null 2>&1; then
        sudo -u "$ADMIN_USER" security lock-keychain "$keychain" >/dev/null 2>&1
        info "Login keychain already uses the new password."
        return 0
    fi

    backup="$keychain.$(date '+%Y%m%d%H%M%S').bak"
    if mv "$keychain" "$backup"; then
        warn "Login keychain opened with neither password. Moved it to $backup; macOS creates a new one at the next login."
    else
        warn "Login keychain opened with neither password and could not be moved aside. Expect a keychain prompt at the next login."
    fi
}

# ------------------------------------------------------------------------------
# Inputs
# ------------------------------------------------------------------------------
echo "Set Admin Password (macOS)"
echo "=========================================="

[[ $EUID -eq 0 ]] || die "Must run as root (NinjaOne runs scripts as root; use sudo in a terminal)."

USERNAME_FIELD="${USERNAME_FIELD:-clientAdminName}"
OLD_PASSWORD_FIELD="${OLD_PASSWORD_FIELD:-clientAdminPwOld}"
NEW_PASSWORD_FIELD="${NEW_PASSWORD_FIELD:-clientAdminPw}"

ADMIN_USER="${ADMIN_USERNAME:-$(read_ninja_field "$USERNAME_FIELD")}"
OLD_PW="${ADMIN_OLD_PASSWORD:-$(read_ninja_field "$OLD_PASSWORD_FIELD")}"
NEW_PW="${ADMIN_NEW_PASSWORD:-$(read_ninja_field "$NEW_PASSWORD_FIELD")}"

[[ -n "$ADMIN_USER" ]] || die "No username. Set the '$USERNAME_FIELD' custom field or ADMIN_USERNAME."
[[ -n "$OLD_PW" ]]     || die "No old password. Set the '$OLD_PASSWORD_FIELD' custom field or ADMIN_OLD_PASSWORD."
[[ -n "$NEW_PW" ]]     || die "No new password. Set the '$NEW_PASSWORD_FIELD' custom field or ADMIN_NEW_PASSWORD."
[[ "$OLD_PW" != "$NEW_PW" ]] || die "The old and new passwords are the same. Nothing to change."
[[ "$ADMIN_USER" != "root" ]] || die "Refusing to change the root password with this script."
id "$ADMIN_USER" >/dev/null 2>&1 || die "User '$ADMIN_USER' does not exist on this Mac."

if ! dseditgroup -o checkmember -m "$ADMIN_USER" admin >/dev/null 2>&1; then
    warn "$ADMIN_USER is not in the admin group. Continuing with the password change anyway."
fi

# ------------------------------------------------------------------------------
# Current state
# ------------------------------------------------------------------------------
ADMIN_GUID=$(dscl . -read "/Users/$ADMIN_USER" GeneratedUID 2>/dev/null | awk '{print $2}')
TOKEN_BEFORE=$(secure_token_status "$ADMIN_USER")
FILEVAULT_ON="false"
fdesetup isactive >/dev/null 2>&1 && FILEVAULT_ON="true"
CRYPTO_VOLUME=$(get_crypto_volume)
IS_CRYPTO_USER="false"
if [[ -n "$ADMIN_GUID" && -n "$CRYPTO_VOLUME" ]] \
        && diskutil apfs listCryptoUsers "$CRYPTO_VOLUME" 2>/dev/null | grep -qi "$ADMIN_GUID"; then
    IS_CRYPTO_USER="true"
fi

info "Account:            $ADMIN_USER ($ADMIN_GUID)"
info "macOS:              $(sw_vers -productVersion)"
info "Secure Token:       $TOKEN_BEFORE"
info "FileVault on:       $FILEVAULT_ON"
info "APFS crypto user:   $IS_CRYPTO_USER (volume ${CRYPTO_VOLUME:-unknown})"

# ------------------------------------------------------------------------------
# Change
# ------------------------------------------------------------------------------
CHANGE_METHOD=""
FAILED="false"

if password_works "$ADMIN_USER" "$NEW_PW"; then
    info "The new password already works for $ADMIN_USER. Skipping the change and verifying the rest."
elif password_works "$ADMIN_USER" "$OLD_PW"; then
    change_password || die "Password change failed; $ADMIN_USER still uses the old password. Nothing else was changed."
    info "Login password changed (method: $CHANGE_METHOD)."
else
    die "Neither the old nor the new password works for $ADMIN_USER. Not changing anything: resetting without the current password would break the Secure Token and FileVault unlock. Update '$OLD_PASSWORD_FIELD' to this Mac's current password."
fi

# ------------------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------------------
TOKEN_AFTER=$(secure_token_status "$ADMIN_USER")
info "Secure Token after: $TOKEN_AFTER"
if [[ "$TOKEN_BEFORE" == "ENABLED" && "$TOKEN_AFTER" != "ENABLED" ]]; then
    err "$ADMIN_USER lost its Secure Token during the change."
    FAILED="true"
fi

if [[ "$IS_CRYPTO_USER" == "true" ]]; then
    if ! verify_unlock_password; then
        err "Could not confirm that the new password unlocks FileVault for $ADMIN_USER."
        err "Until this is fixed, the FileVault unlock screen may still need the OLD password. Other FileVault users and the recovery key still work."
        err "To fix it on the Mac: sudo diskutil apfs changePassphrase $CRYPTO_VOLUME -user $ADMIN_GUID (enter the old password, then the new one)."
        FAILED="true"
    fi
else
    info "$ADMIN_USER is not an APFS crypto user, so there is no FileVault unlock password to check."
fi

update_login_keychain

if [[ "$FILEVAULT_ON" == "true" ]]; then
    info "Refreshing the Preboot volume."
    print_output "$(diskutil apfs updatePreboot / 2>&1 | tail -n 3)"
fi

unset OLD_PW NEW_PW

echo "=========================================="
if [[ "$FAILED" == "true" ]]; then
    err "Finished with errors. Review the log above before rebooting this Mac."
    exit 1
fi
if [[ "$IS_CRYPTO_USER" == "true" ]]; then
    info "Done. $ADMIN_USER uses the new password for login, Secure Token and FileVault unlock."
else
    info "Done. $ADMIN_USER uses the new password for login."
fi
exit 0

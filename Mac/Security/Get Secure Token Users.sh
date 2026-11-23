#!/usr/bin/env bash
# ==============================================================================
# .SYNOPSIS
#   Prints the short name of every local macOS user that holds a Secure Token.
#
# .DESCRIPTION
#   Checks every local user account (admin group members plus all accounts with
#   a UID of 500 or higher) with sysadminctl -secureTokenStatus and prints only
#   the accounts where it reports ENABLED, one short name per line, and nothing
#   else on stdout. That makes it safe to capture:
#
#       token_user=$(./"Get Secure Token Users.sh")
#
#   Separately, it reads the disk's own list of cryptographic users
#   (diskutil apfs listUsers /) and matches every local account against it. Those
#   are the accounts whose password unlocks the FileVault disk at startup, whether
#   or not they hold a Secure Token. That list is published to NinjaOne; stdout
#   stays the Secure Token list. Volume ownership (the right to authorize macOS
#   updates and security policy on Apple silicon) cannot be read reliably from
#   the command line, so it is not reported.
#
#   Notes about the output are written to stderr. sysadminctl prints the
#   account's full name rather than its short name, so this script matches on
#   the ENABLED/DISABLED word and prints the short name it looked up itself.
#
# .NOTES
#   Compatible with the stock macOS bash 3.2. Run as root (NinjaOne, or sudo).
#
#   Exit codes:
#     0  at least one user holds a Secure Token
#     1  no user holds a Secure Token (or not a Mac)
#
#   Environment variables / NinjaOne script variables (optional):
#     SECURE_TOKEN_FIELD - NinjaOne custom field to publish the comma-separated
#                          list to. Default secureTokenUsers. Set to an empty
#                          string to skip publishing.
#     UNLOCK_USERS_FIELD - NinjaOne custom field for the accounts that can unlock
#                          the disk. Default fileVaultUnlockUsers.
#                          Set to an empty string to skip publishing.
# ==============================================================================

NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"
NINJA_CUSTOM_FIELD="${SECURE_TOKEN_FIELD-secureTokenUsers}"
NINJA_UNLOCK_FIELD="${UNLOCK_USERS_FIELD-fileVaultUnlockUsers}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "This script only runs on macOS." >&2
    exit 1
fi

# Candidate accounts: admin group members plus every real (UID >= 500) user.
# Service accounts such as root and _spotlight are skipped.
candidates=$(
    {
        dscl . -read /Groups/admin GroupMembership 2>/dev/null | cut -d " " -f 2-
        dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 500 { print $1 }'
    } | tr ' ' '\n' | grep -v -e '^$' -e '^root$' -e '^_' | sort -u
)

token_users=()
for u in $candidates; do
    # sysadminctl writes its result to stderr
    status=$(sysadminctl -secureTokenStatus "$u" 2>&1)
    if [[ "$status" == *"ENABLED"* ]]; then
        token_users+=("$u")
    fi
done

if [[ ${#token_users[@]} -eq 0 ]]; then
    echo "No local user holds a Secure Token." >&2
    exit 1
fi

printf '%s\n' "${token_users[@]}"

# Every local account whose GeneratedUID is an APFS cryptographic user of the boot
# volume. Other entries (recovery keys, iCloud) have no local account and are
# only counted.
crypto_users=$(diskutil apfs listUsers / 2>/dev/null)
unlock_users=()
while read -r name guid; do
    if [[ -n "$guid" && "$name" != "root" && "$crypto_users" == *"$guid"* ]]; then
        unlock_users+=("$name")
    fi
done < <(dscl . -list /Users GeneratedUID 2>/dev/null)
echo "Can unlock the disk: ${unlock_users[*]:-none}" >&2

# Flag accounts that unlock the disk without a token, or hold a token without
# being able to unlock the disk.
for u in "${unlock_users[@]}"; do
    case " ${token_users[*]} " in *" $u "*) ;; *) echo "Note: $u can unlock the disk but has no Secure Token." >&2 ;; esac
done
for u in "${token_users[@]}"; do
    case " ${unlock_users[*]} " in *" $u "*) ;; *) echo "Note: $u has a Secure Token but cannot unlock the disk." >&2 ;; esac
done

set_ninja_field() {
    local field="$1"; shift
    [[ -n "$field" && -f "$NINJA_CLI" ]] || return 0
    local list
    list=$(printf '%s,' "$@")
    list="${list%,}"
    if ! "$NINJA_CLI" set "$field" "$list" >/dev/null 2>&1; then
        echo "Warning: could not set NinjaOne field '$field' (run as root)." >&2
    fi
}

set_ninja_field "$NINJA_CUSTOM_FIELD" "${token_users[@]}"
if [[ ${#unlock_users[@]} -gt 0 ]]; then
    set_ninja_field "$NINJA_UNLOCK_FIELD" "${unlock_users[@]}"
else
    set_ninja_field "$NINJA_UNLOCK_FIELD" "none"
fi

exit 0

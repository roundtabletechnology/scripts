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
# ==============================================================================

NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"
NINJA_CUSTOM_FIELD="${SECURE_TOKEN_FIELD-secureTokenUsers}"

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

if [[ -n "$NINJA_CUSTOM_FIELD" && -f "$NINJA_CLI" ]]; then
    list=$(printf '%s,' "${token_users[@]}")
    list="${list%,}"
    if ! "$NINJA_CLI" set "$NINJA_CUSTOM_FIELD" "$list" >/dev/null 2>&1; then
        echo "Warning: could not set NinjaOne field '$NINJA_CUSTOM_FIELD' (run as root)." >&2
    fi
fi

exit 0

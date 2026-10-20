#!/bin/bash
# Get installed printers [MAC]
# Lists the printers installed on the Mac (name and device URI - the macOS
# equivalent of a Windows port), skipping fax, PDF, OneNote and NinjaRemote
# queues, prints them to stdout, and publishes them to the Ninja RMM custom
# field "printers".

# Configuration
NINJA_CUSTOM_FIELD="printers"
NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"
EXCLUDE_PATTERN="fax|pdf|onenote|ninjaremote"   # Matched case-insensitively against name and queue

# lpstat's "device for" wording is localized; force English so parsing works
export LC_ALL=C

# Collect "name<TAB>uri" rows. lpstat -v lines look like:
#   device for HP_LaserJet_Pro: ipp://192.168.1.50/ipp/print
rows=""
while IFS= read -r line; do
    [[ "$line" == "device for "* ]] || continue
    rest="${line#device for }"
    queue="${rest%%: *}"
    uri="${rest#*: }"

    # Use the friendly name shown in System Settings; fall back to the queue name
    name=$(lpstat -l -p "$queue" 2>/dev/null | awk -F'Description: ' '/Description: /{print $2; exit}')
    [[ -n "$name" ]] || name="$queue"

    if printf '%s\n%s\n' "$name" "$queue" | grep -qiE "$EXCLUDE_PATTERN"; then
        continue
    fi
    rows+="$name"$'\t'"$uri"$'\n'
done < <(lpstat -v 2>/dev/null)

if [[ -n "$rows" ]]; then
    # Align into two columns, like Format-Table -HideTableHeaders
    printers=$(printf '%s' "$rows" | awk -F'\t' '
        { name[NR] = $1; uri[NR] = $2; if (length($1) > w) w = length($1) }
        END { for (i = 1; i <= NR; i++) printf "%-*s  %s\n", w, name[i], uri[i] }')
else
    printers="No printers installed"
fi
echo "$printers"

if [[ -f "$NINJA_CLI" ]]; then
    # ninjarmm-cli lives in a folder that's inaccessible to non-root users, so
    # writes silently fail unless this script is run as root (SYSTEM, when
    # deployed via NinjaOne; sudo, when run manually for testing).
    if [[ $EUID -ne 0 ]]; then
        echo "Warning: not running as root - ninjarmm-cli set may fail due to permissions."
    fi

    cli_error=$("$NINJA_CLI" set "$NINJA_CUSTOM_FIELD" "$printers" 2>&1 >/dev/null)
    if [[ $? -eq 0 ]]; then
        echo "Published printer list to Ninja custom field: $NINJA_CUSTOM_FIELD"
    else
        echo "Failed to write Ninja custom field '$NINJA_CUSTOM_FIELD': $cli_error"
    fi
else
    echo "ninjarmm-cli not found at $NINJA_CLI - skipping Ninja field write."
fi

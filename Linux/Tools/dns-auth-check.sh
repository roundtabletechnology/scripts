#!/usr/bin/env bash
# dns-auth-check.sh — Fetch SPF, DKIM (common selectors), and DMARC records for a domain.
# Usage: dns-auth-check.sh [--strict] [-s <resolver>] <domain> [extra-selector ...]
#   --strict          Exit non-zero if SPF or DMARC is missing.
#   -s <resolver>      Query a specific DNS resolver (e.g. -s 8.8.8.8) instead of the system default.
#   extra-selector     Additional DKIM selector name(s) to probe beyond the built-in list.

set -euo pipefail

if ! command -v dig >/dev/null 2>&1; then
  echo "Error: 'dig' is not installed (try: apt install dnsutils / dnf install bind-utils)." >&2
  exit 1
fi

usage() {
  echo "Usage: $0 [--strict] [-s <resolver>] <domain> [extra-selector ...]"
}

STRICT=0
RESOLVER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    -s)
      if [[ -z "${2:-}" ]]; then
        echo "Error: -s requires a resolver argument" >&2
        exit 1
      fi
      RESOLVER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  usage
  exit 1
fi
shift
EXTRA_SELECTORS=("$@")

# --- dig helpers (route through the chosen resolver, if any) ---
dig_txt() {
  if [[ -n "$RESOLVER" ]]; then
    dig "@$RESOLVER" +short TXT "$1" 2>/dev/null || true
  else
    dig +short TXT "$1" 2>/dev/null || true
  fi
}

dig_cname() {
  if [[ -n "$RESOLVER" ]]; then
    dig "@$RESOLVER" +short CNAME "$1" 2>/dev/null || true
  else
    dig +short CNAME "$1" 2>/dev/null || true
  fi
}

# Join adjacent quoted TXT string segments and strip the surrounding quotes,
# since a single TXT record >255 chars comes back as "part1" "part2" ...
flatten_txt() {
  sed -e 's/" *"//g' -e 's/^"//' -e 's/"$//' <<< "$1"
}

echo "========================================"
echo " Domain: $DOMAIN"
echo " Date:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
[[ -n "$RESOLVER" ]] && echo " Resolver: $RESOLVER"
echo "========================================"

# --- SPF ---
echo
echo "### SPF (TXT) ###"
SPF_RECORDS=$(dig_txt "$DOMAIN" | grep -i 'v=spf' || true)
SPF_LOOKUP_COUNT=""
if [[ -n "$SPF_RECORDS" ]]; then
  while IFS= read -r line; do
    echo "  $(flatten_txt "$line")"
  done <<< "$SPF_RECORDS"

  SPF_COUNT=$(grep -c '.' <<< "$SPF_RECORDS")
  if [[ "$SPF_COUNT" -gt 1 ]]; then
    echo "  WARNING: ${SPF_COUNT} SPF records found — a domain must have exactly one (RFC 7208)."
  fi

  # Count mechanisms that each cost one DNS lookup against SPF's 10-lookup limit.
  SPF_FIRST=$(flatten_txt "$(head -n1 <<< "$SPF_RECORDS")")
  SPF_LOOKUP_COUNT=0
  read -ra SPF_TOKENS <<< "$SPF_FIRST"
  for tok in "${SPF_TOKENS[@]}"; do
    tok="${tok#[+~?-]}"
    case "$tok" in
      include:*|a|a:*|mx|mx:*|ptr|ptr:*|exists:*|redirect=*)
        SPF_LOOKUP_COUNT=$((SPF_LOOKUP_COUNT + 1))
        ;;
    esac
  done
  if [[ "$SPF_LOOKUP_COUNT" -gt 10 ]]; then
    echo "  WARNING: SPF uses ${SPF_LOOKUP_COUNT} DNS-lookup mechanisms (limit is 10 per RFC 7208) — likely PermError."
  else
    echo "  DNS lookups used: ${SPF_LOOKUP_COUNT}/10"
  fi
else
  echo "  (No SPF record found)"
fi

# --- DKIM (try common selectors) ---
echo
echo "### DKIM ###"
# Common DKIM selectors to probe
SELECTORS=(
  default
  s1
  s2
  google
  k1
  selector1
  selector2
  mail
  dkim
  sendgrid
  amazonses
)
if [[ ${#EXTRA_SELECTORS[@]} -gt 0 ]]; then
  SELECTORS+=("${EXTRA_SELECTORS[@]}")
fi

DKIM_FOUND=0
for sel in "${SELECTORS[@]}"; do
  RECORD_NAME="${sel}._domainkey.${DOMAIN}"
  RESULT=$(dig_txt "$RECORD_NAME")
  if [[ -n "$RESULT" ]]; then
    echo "  Selector: ${sel}._domainkey"
    echo "  Record:   ${RECORD_NAME}"
    CNAME_RESULT=$(dig_cname "$RECORD_NAME")
    if [[ -n "$CNAME_RESULT" ]]; then
      echo "  CNAME:    ${RECORD_NAME} -> ${CNAME_RESULT}"
    fi
    echo "  Value:    $(flatten_txt "$RESULT")"
    echo
    DKIM_FOUND=1
  fi
done

if [[ "$DKIM_FOUND" -eq 0 ]]; then
  echo "  (No DKIM records found with common selectors)"
  echo "  Note: DKIM selectors can't be discovered via DNS — 'not found' only means none of the"
  echo "        probed names matched. Try 'dig TXT <selector>._domainkey.${DOMAIN}' with a known selector."
fi

# --- DMARC ---
echo
echo "### DMARC ###"
DMARC_RECORDS=$(dig_txt "_dmarc.${DOMAIN}")
DMARC_POLICY=""
if [[ -n "$DMARC_RECORDS" ]]; then
  echo "  Record:  _dmarc.${DOMAIN}"
  echo "  Value:   $(flatten_txt "$(head -n1 <<< "$DMARC_RECORDS")")"

  DMARC_COUNT=$(grep -c '.' <<< "$DMARC_RECORDS")
  if [[ "$DMARC_COUNT" -gt 1 ]]; then
    echo "  WARNING: ${DMARC_COUNT} DMARC records found — a domain must have exactly one."
  fi

  DMARC_POLICY=$(flatten_txt "$(head -n1 <<< "$DMARC_RECORDS")" | grep -oiE 'p=[a-z]+' | head -n1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]' || true)
  if [[ -n "$DMARC_POLICY" ]]; then
    echo "  Policy:  p=${DMARC_POLICY}"
    case "$DMARC_POLICY" in
      none)       echo "  Note:    Monitoring only — not enforcing (p=none)." ;;
      quarantine) echo "  Note:    Enforcing — failing mail is quarantined (p=quarantine)." ;;
      reject)     echo "  Note:    Enforcing — failing mail is rejected (p=reject)." ;;
    esac
  fi
else
  echo "  (No DMARC record found at _dmarc.${DOMAIN})"
fi

# --- Summary ---
echo
echo "========================================"
echo " Summary"
echo "========================================"
if [[ -n "$SPF_RECORDS" ]]; then
  echo "  SPF:     FOUND (${SPF_LOOKUP_COUNT}/10 lookups)"
else
  echo "  SPF:     MISSING"
fi
[[ "$DKIM_FOUND" -eq 1 ]] && echo "  DKIM:    FOUND (1+ selectors)" || echo "  DKIM:    NOT FOUND (with common selectors)"
if [[ -n "$DMARC_RECORDS" ]]; then
  if [[ -n "$DMARC_POLICY" ]]; then
    echo "  DMARC:   FOUND (p=${DMARC_POLICY})"
  else
    echo "  DMARC:   FOUND"
  fi
else
  echo "  DMARC:   MISSING"
fi
echo "========================================"

if [[ "$STRICT" -eq 1 ]]; then
  if [[ -z "$SPF_RECORDS" || -z "$DMARC_RECORDS" ]]; then
    exit 1
  fi
fi

exit 0

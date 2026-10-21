#!/usr/bin/env bash
# tls_expiry.sh
# Read-only TLS certificate expiry check for a Mac: PEM files, hosts, and the
# client and identity certificates in the Keychain.
#
# The macOS half of linux/tls_expiry.sh, down to the flags, the verdict
# grammar and the exit codes. Two things differ. macOS has neither GNU date
# nor timeout(1), so the verdict comes from `openssl x509 -checkend` (no date
# parsing at all), the day count from BSD `date -j`, and the host fetch is
# capped with a perl alarm. And a Mac keeps certificates nobody pages on in
# the login Keychain: the mTLS or VPN client identity that expires quietly and
# takes a tunnel with it. --keychain grades those.
#
# It never scans a trust store. --keychain reads the login keychain and, when
# readable, /Library/Keychains/System.keychain, never /System/Library; it
# skips self-signed roots, and exports public certificates only
# (`security find-certificate -p`), so no private key is ever requested and
# no unlock prompt can appear.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold
#   2   preflight failed (not macOS, or openssl missing)
#   3   bad CLI arguments
set -u
set -o pipefail

DAYS=30
FAIL_ON="expired"
QUIET=0
KEYCHAIN=0
FILES=()
HOSTS=()

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); (( QUIET )) || printf "  %s[pass]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
info() { (( QUIET )) || printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
tls_expiry.sh - read-only TLS certificate expiry check for macOS

Reports when a certificate has expired or will expire within --days.
Changes nothing. Does not scan a CA trust store; name each PEM or host, or
pass --keychain for the client and identity certificates in the Keychain.

Usage:
  $(basename "$0") --file CERT.pem [--file 'certs/*.pem']
  $(basename "$0") --host example.com [--host example.com:8443]
  $(basename "$0") --keychain [--days 14] [--fail-on warn]

Options:
  --file PATH         PEM to inspect (repeatable, comma-separable; a quoted
                      glob is expanded; first cert in a bundle)
  --host HOST[:PORT]  Fetch the leaf over TLS (default port 443; repeatable)
  --keychain          Grade the login and System keychain certificates,
                      self-signed roots excepted
  --days N            Warn this many days before expiry (default: $DAYS)
  --fail-on LEVEL     Exit 1 on 'expired' (default), on 'warn' and above,
                      or 'never'
  --quiet             Print only warnings and failures
  --help, -h          Show this help

Exit codes: 0 clean, 1 findings at or above --fail-on, 2 preflight, 3 usage
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

# Expand a --file glob the user quoted, so --file 'certs/*.pem' is usable from
# cron. nullglob is switched on for the loop and back off afterwards by name,
# rather than by evaluating a saved `shopt -p` line.
add_one_file() {
  local item="$1"
  local match found had_nullglob=0
  case "$item" in
    *'*'*|*'?'*|*'['*)
      shopt -q nullglob && had_nullglob=1
      shopt -s nullglob
      found=0
      # Unquoted so the glob in $item expands. Paths with spaces in the
      # directory name will not match; pass those files individually.
      for match in $item; do
        FILES+=("$match")
        found=1
      done
      (( had_nullglob )) || shopt -u nullglob
      (( found )) || FILES+=("$item")
      ;;
    *)
      FILES+=("$item")
      ;;
  esac
}

add_files() {
  local item parts
  IFS=',' read -r -a parts <<< "$1"
  for item in ${parts[@]+"${parts[@]}"}; do
    [[ -n "$item" ]] || continue
    add_one_file "$item"
  done
}

# A host reaches openssl as an argument, so it is held to a host name or an
# IPv4 address (never a leading dash) and a numeric port here, at parse time.
add_hosts() {
  local item parts spec name port
  IFS=',' read -r -a parts <<< "$1"
  for item in ${parts[@]+"${parts[@]}"}; do
    [[ -n "$item" ]] || continue
    spec="${item#https://}"
    spec="${spec%%/*}"
    name="${spec%%:*}"
    port="443"
    [[ "$spec" == *:* ]] && port="${spec#*:}"
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
      err "--host must be HOST or HOST:PORT, got: $item"
      exit 3
    fi
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
      err "--host port must be 1-65535, got: $item"
      exit 3
    fi
    HOSTS+=("$name:$((10#$port))")
  done
}

while (( $# > 0 )); do
  case "$1" in
    --file)      require_value "$1" "${2:-}"; add_files "$2"; shift ;;
    --file=*)    require_value "--file" "${1#*=}"; add_files "${1#*=}" ;;
    --host)      require_value "$1" "${2:-}"; add_hosts "$2"; shift ;;
    --host=*)    require_value "--host" "${1#*=}"; add_hosts "${1#*=}" ;;
    --days)      require_value "$1" "${2:-}"; DAYS="$2"; shift ;;
    --days=*)    DAYS="${1#*=}"; require_value "--days" "$DAYS" ;;
    --fail-on)   require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*) FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --keychain)  KEYCHAIN=1 ;;
    --quiet)     QUIET=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$FAIL_ON" in
  expired|warn|never) ;;
  *) err "--fail-on must be expired, warn or never, got: $FAIL_ON"; exit 3 ;;
esac

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || (( 10#$DAYS > 3650 )); then
  err "--days must be an integer between 0 and 3650, got: $DAYS"
  exit 3
fi
DAYS=$((10#$DAYS))

# Usage before preflight: a missing target stays exit 3 on a machine without
# openssl, the same reason --help is answered before the macOS check.
if (( ${#FILES[@]} == 0 && ${#HOSTS[@]} == 0 && KEYCHAIN == 0 )); then
  err "pass --file PATH, --host HOST or --keychain"
  usage >&2
  exit 3
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS"
  exit 2
fi

if ! command -v openssl >/dev/null 2>&1; then
  err "openssl is required (macOS ships one in /usr/bin; check PATH)"
  exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Certificate text is data: control characters are stripped before it is
# printed.
clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# macOS has no timeout(1). perl ships with it, and alarm survives exec, so
# the command runs as this one process and SIGALRM ends it on time.
with_timeout() {
  local secs="$1"
  shift
  if have perl; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

# Whole days until notAfter, for the human summary only; the verdict comes
# from -checkend. BSD date answers on a Mac, GNU date anywhere else, and each
# answer is accepted only when it is a number.
days_left() {
  local when="$1" epoch now
  epoch="$(date -j -u -f '%b %e %T %Y %Z' "$when" +%s 2>/dev/null)"
  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    epoch="$(date -u -d "$when" +%s 2>/dev/null)"
  fi
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  now="$(date -u +%s)"
  printf '%d\n' $(( (epoch - now) / 86400 ))
}

# The value of one RDN-ish field from `openssl x509 -subject` or -issuer,
# whichever of the OpenSSL and LibreSSL spellings it comes in.
x509_field() {
  printf '%s\n' "$1" | openssl x509 -noout "-$2" 2>/dev/null | head -n 1
}

cn_of() {
  local subject
  subject="$(x509_field "$1" subject)"
  subject="${subject#subject=}"
  case "$subject" in
    *"CN = "*) subject="${subject#*CN = }" ;;
    *"CN="*)   subject="${subject#*CN=}" ;;
    *)         subject="" ;;
  esac
  subject="${subject%%,*}"
  subject="${subject%%/*}"
  clean "$subject"
}

grade_pem() {
  local label="$1" pem="$2" hint="$3"
  local enddate when left summary cn
  enddate="$(x509_field "$pem" enddate)"
  if [[ -z "$enddate" ]]; then
    fail "$label: not a readable X.509 PEM" "inspect it with: openssl x509 -noout -subject -dates"
    return
  fi
  when="$(clean "${enddate#notAfter=}")"
  cn="$(cn_of "$pem")"
  [[ -n "$cn" && "$label" != *"$cn"* ]] && label="$label (CN=$cn)"
  if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    fail "$label expired ($when)" "$hint"
    return
  fi
  if left="$(days_left "$when")"; then
    summary="expires $when (${left}d)"
  else
    summary="expires $when"
  fi
  if printf '%s\n' "$pem" | openssl x509 -noout -checkend "$((DAYS * 86400))" >/dev/null 2>&1; then
    pass "$label $summary"
  else
    warn "$label $summary" "renew before the ${DAYS}d window closes"
  fi
}

fetch_host_pem() {
  local host="$1" port="$2"
  printf '\n' | with_timeout 10 openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null \
    | openssl x509 2>/dev/null
  return 0
}

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

if (( ${#FILES[@]} > 0 )); then
  group "files"
  for f in "${FILES[@]}"; do
    if [[ -d "$f" ]]; then
      fail "$f is a directory" "pass a PEM; this script does not walk a certificate directory"
      continue
    fi
    if [[ ! -r "$f" ]]; then
      fail "$f: not a readable file"
      continue
    fi
    pem="$(openssl x509 -in "$f" 2>/dev/null)" || pem=""
    if [[ -z "$pem" ]]; then
      fail "$f: not a readable X.509 PEM" "openssl x509 -in $f -noout -dates"
      continue
    fi
    grade_pem "$f" "$pem" "replace the certificate; clients already reject it"
  done
fi

if (( ${#HOSTS[@]} > 0 )); then
  group "hosts"
  for spec in "${HOSTS[@]}"; do
    name="${spec%:*}"
    port="${spec##*:}"
    pem="$(fetch_host_pem "$name" "$port")"
    if [[ -z "$pem" ]]; then
      warn "$spec: could not fetch a leaf certificate" \
           "openssl s_client -connect $name:$port -servername $name"
      continue
    fi
    grade_pem "$spec" "$pem" "replace the leaf; clients already reject it"
  done
fi

# Split the concatenated PEM stream from `security find-certificate -a -p` and
# grade each certificate that is not its own issuer.
grade_keychain() {
  local kc="$1" label="$2" line pem="" subject issuer cn graded=0 roots=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    pem="$pem$line"$'\n'
    [[ "$line" == "-----END CERTIFICATE-----" ]] || continue
    subject="$(x509_field "$pem" subject)"
    issuer="$(x509_field "$pem" issuer)"
    if [[ -n "$subject" && "${subject#subject=}" == "${issuer#issuer=}" ]]; then
      roots=$((roots + 1))
    else
      cn="$(cn_of "$pem")"
      grade_pem "${cn:-unnamed certificate} ($label)" "$pem" \
        "renew it, or delete the stale copy in Keychain Access"
      graded=$((graded + 1))
    fi
    pem=""
  done <<< "$(security find-certificate -a -p "$kc" 2>/dev/null)"
  if (( graded == 0 )); then
    info "$label: no certificates to grade"
  fi
  (( roots > 0 )) && info "$label: $roots self-signed root(s) not graded"
  return 0
}

if (( KEYCHAIN )); then
  group "keychain"
  if ! have security; then
    skip "security not found; keychain not read"
  else
    if [[ -n "${HOME:-}" && -r "$HOME/Library/Keychains/login.keychain-db" ]]; then
      grade_keychain "$HOME/Library/Keychains/login.keychain-db" "login keychain"
    else
      skip "no readable login keychain"
    fi
    if [[ -r /Library/Keychains/System.keychain ]]; then
      grade_keychain /Library/Keychains/System.keychain "System keychain"
    else
      skip "System keychain not readable"
    fi
  fi
fi

printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

case "$FAIL_ON" in
  never)   exit 0 ;;
  warn)    (( FAIL_COUNT + WARN_COUNT > 0 )) && exit 1; exit 0 ;;
  expired) (( FAIL_COUNT > 0 )) && exit 1; exit 0 ;;
esac
exit 0

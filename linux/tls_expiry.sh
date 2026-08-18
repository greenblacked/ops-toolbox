#!/usr/bin/env bash
# tls_expiry.sh
# Read-only TLS certificate expiry check for a Linux machine.
#
# The counterpart of mikrotik/cert_expiry_watch.lua. That script watches the
# RouterOS certificate store; this one watches the PEMs and hostnames you
# actually serve. It never scans /etc/ssl/certs — that directory is a CA
# trust store, and paging on a distro root that expires next month is noise.
# Pass every leaf you care about with --file or --host.
#
# openssl is required for the check itself. --help still works without it,
# the same way every other script in this folder answers usage before
# preflight.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold
#   2   preflight failed (not Linux, or openssl missing)
#   3   bad CLI arguments
set -u
set -o pipefail

DAYS=30
FAIL_ON="expired"
QUIET=0
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
tls_expiry.sh - read-only TLS certificate expiry check

Reports when a leaf certificate has expired or will expire within --days.
Changes nothing. Does not scan the CA trust store; name each PEM or hostname.

Usage:
  $(basename "$0") --file CERT.pem [--file CERT2.pem]
  $(basename "$0") --host example.com [--host example.com:8443]
  $(basename "$0") --file CERT.pem --days 14 --fail-on warn

Options:
  --file PATH      PEM to inspect (repeatable; first cert in a bundle)
  --host HOST[:PORT]  Fetch the leaf over TLS (default port 443; repeatable)
  --days N         Warn this many days before expiry (default: $DAYS)
  --fail-on LEVEL  Exit 1 on 'expired' (default), on 'warn' and above, or 'never'
  --quiet          Print only warnings and failures
  --help, -h       Show this help

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

# Expand a --file glob the user quoted, so
# --file '/etc/letsencrypt/live/*/fullchain.pem' is usable from cron.
# Unquoted globs are already expanded by the shell before we see them.
add_one_file() {
  local item="$1"
  local match found saved
  case "$item" in
    *'*'*|*'?'*|*'['*)
      saved="$(shopt -p nullglob)"
      shopt -s nullglob
      found=0
      # Unquoted so the glob in $item expands. Paths with spaces in the
      # directory name will not match; pass those files individually.
      for match in $item; do
        FILES+=("$match")
        found=1
      done
      eval "$saved"
      (( found )) || FILES+=("$item")
      ;;
    *)
      FILES+=("$item")
      ;;
  esac
}

add_files() {
  local raw="$1"
  local item
  local parts
  IFS=',' read -r -a parts <<< "$raw"
  for item in "${parts[@]}"; do
    [[ -n "$item" ]] || continue
    add_one_file "$item"
  done
}

add_hosts() {
  local raw="$1"
  local item
  local parts
  IFS=',' read -r -a parts <<< "$raw"
  for item in "${parts[@]}"; do
    [[ -n "$item" ]] || continue
    HOSTS+=("$item")
  done
}

while (( $# > 0 )); do
  case "$1" in
    --file)      require_value "$1" "${2:-}"; add_files "$2"; shift ;;
    --file=*)    add_files "${1#*=}"; require_value "--file" "${1#*=}" ;;
    --host)      require_value "$1" "${2:-}"; add_hosts "$2"; shift ;;
    --host=*)    add_hosts "${1#*=}"; require_value "--host" "${1#*=}" ;;
    --days)      require_value "$1" "${2:-}"; DAYS="$2"; shift ;;
    --days=*)    DAYS="${1#*=}"; require_value "--days" "$DAYS" ;;
    --fail-on)   require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*) FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
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

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || (( DAYS > 3650 )); then
  err "--days must be an integer between 0 and 3650, got: $DAYS"
  exit 3
fi

# Usage before preflight: a missing --file must stay exit 3 on a machine
# that has no openssl (Fedora's tester image), the same reason --help is
# answered before the Linux check.
if (( ${#FILES[@]} == 0 && ${#HOSTS[@]} == 0 )); then
  err "pass --file PATH or --host HOST"
  usage >&2
  exit 3
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

if ! command -v openssl >/dev/null 2>&1; then
  err "openssl is required (install openssl, then rerun)"
  exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Remaining whole days until notAfter. Negative means already expired.
# GNU date is assumed: this package already targets Debian, Fedora and Arch.
days_left_from_enddate() {
  local raw="$1"
  local when epoch now
  when="${raw#notAfter=}"
  [[ -n "$when" ]] || return 1
  epoch="$(date -d "$when" +%s 2>/dev/null || printf '')"
  [[ -n "$epoch" ]] || return 1
  now="$(date +%s)"
  printf '%d\n' $(( (epoch - now) / 86400 ))
}

cn_from_pem() {
  local subject
  subject="$(printf '%s\n' "$1" | openssl x509 -noout -subject 2>/dev/null || true)"
  subject="${subject#subject=}"
  subject="${subject#*CN = }"
  subject="${subject#*CN=}"
  subject="${subject%%,*}"
  subject="${subject## }"
  printf '%s\n' "$subject"
}

grade_pem() {
  local label="$1"
  local pem="$2"
  local enddate left seconds cn summary
  enddate="$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null || true)"
  if [[ -z "$enddate" ]]; then
    fail "$label: not a readable X.509 PEM" "openssl x509 -in <file> -noout -dates"
    return
  fi
  cn="$(cn_from_pem "$pem")"
  [[ -n "$cn" && "$cn" != "$label" ]] && label="$label (CN=$cn)"
  seconds=$(( DAYS * 86400 ))
  if printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    :
  else
    fail "$label expired (${enddate#notAfter=})" "replace the leaf; clients already reject it"
    return
  fi
  left=""
  if left="$(days_left_from_enddate "$enddate")"; then
    summary="expires ${enddate#notAfter=} (${left}d)"
  else
    summary="expires ${enddate#notAfter=}"
  fi
  if printf '%s\n' "$pem" | openssl x509 -noout -checkend "$seconds" >/dev/null 2>&1; then
    pass "$label $summary"
  else
    warn "$label $summary" "renew before the ${DAYS}d window closes"
  fi
}

split_host_port() {
  local spec="$1"
  spec="${spec#https://}"
  spec="${spec%%/*}"
  if [[ "$spec" == *:* ]]; then
    HOST_NAME="${spec%:*}"
    HOST_PORT="${spec##*:}"
  else
    HOST_NAME="$spec"
    HOST_PORT=443
  fi
}

fetch_host_pem() {
  local host="$1"
  local port="$2"
  local target="${host}:${port}"
  if have timeout; then
    printf '\n' | timeout 10 openssl s_client -connect "$target" -servername "$host" 2>/dev/null \
      | openssl x509 2>/dev/null || true
  else
    printf '\n' | openssl s_client -connect "$target" -servername "$host" 2>/dev/null \
      | openssl x509 2>/dev/null || true
  fi
}

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

if (( ${#FILES[@]} > 0 )); then
  group "files"
  for f in "${FILES[@]}"; do
    if [[ -d "$f" ]]; then
      fail "$f is a directory" "pass a PEM; this script does not walk /etc/ssl/certs"
      continue
    fi
    if [[ ! -r "$f" ]]; then
      fail "$f: not a readable file"
      continue
    fi
    pem="$(openssl x509 -in "$f" 2>/dev/null || true)"
    if [[ -z "$pem" ]]; then
      fail "$f: not a readable X.509 PEM" "openssl x509 -in $f -noout -dates"
      continue
    fi
    grade_pem "$f" "$pem"
  done
fi

if (( ${#HOSTS[@]} > 0 )); then
  group "hosts"
  for spec in "${HOSTS[@]}"; do
    HOST_NAME=""
    HOST_PORT=""
    split_host_port "$spec"
    if [[ -z "$HOST_NAME" || -z "$HOST_PORT" ]] || ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]]; then
      fail "$spec: host must be HOST or HOST:PORT"
      continue
    fi
    pem="$(fetch_host_pem "$HOST_NAME" "$HOST_PORT")"
    if [[ -z "$pem" ]]; then
      warn "$spec: could not fetch a leaf certificate" "openssl s_client -connect ${HOST_NAME}:${HOST_PORT} -servername ${HOST_NAME}"
      continue
    fi
    grade_pem "$spec" "$pem"
  done
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

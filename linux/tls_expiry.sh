#!/usr/bin/env bash
# tls_expiry.sh
# Read-only TLS certificate expiry check for a Linux machine.
#
# The counterpart of mikrotik/features/cert_expiry_watch.lua. That script watches the
# RouterOS certificate store; this one watches the PEMs and hostnames you
# actually serve. It never scans /etc/ssl/certs — that directory is a CA
# trust store, and paging on a distro root that expires next month is noise.
# Pass every leaf you care about with --file, --host or --hosts-file.
#
# Expiry is half of a certificate outage. The other half is a certificate that
# is valid and wrong: served for another name, sent without its intermediate,
# self-signed, or still on a 1024-bit key or a SHA-1 signature. --check-host
# NAME checks the name, and --deep adds the rest. A host's chain is read from
# the same single handshake the expiry check already makes.
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
DEEP=0
CHECK_HOST=""
MIN_KEY_BITS=2048
CAFILE=""
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
  $(basename "$0") --hosts-file endpoints.txt --deep
  $(basename "$0") --file CERT.pem --check-host www.example.com
  $(basename "$0") --file CERT.pem --days 14 --fail-on warn

Options:
  --file PATH      PEM to inspect (repeatable; first cert in a bundle)
  --host HOST[:PORT]  Fetch the leaf over TLS (default port 443; repeatable)
  --hosts-file FILE   One HOST[:PORT] per line, # comments (repeatable)
  --days N         Warn this many days before expiry (default: $DAYS)
  --check-host NAME   Fail when the certificate does not cover NAME (a --host
                   target checks its own name with --deep; this overrides it)
  --deep           Also check the name, the chain (hosts), self-signed issuers,
                   key size and signature algorithm
  --cafile FILE    Trust anchors for the chain check of --host targets (a
                   private CA's root); the system store and directory are
                   dropped (-no-CApath, -no-CAstore) when this openssl
                   supports them, else system trust may still apply
  --min-key-bits N    Smallest RSA/DSA key --deep accepts, 1024-16384 (default: $MIN_KEY_BITS)
  --fail-on LEVEL  Exit 1 on 'expired' (default), on 'warn' and above, or 'never'
  --quiet          Print only warnings and failures
  --help, -h       Show this help

With the default --fail-on expired, a FAIL from --deep or --check-host (wrong
name, provably missing intermediate, weak key or signature) exits 1 as well;
a warning (self-signed, issuer not trusted locally, unusual curve) exits 1
only with --fail-on warn.

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

# Usage errors stay ahead of the openssl preflight, so an unreadable hosts file
# is exit 3 everywhere. Entries are validated later exactly like --host ones,
# and are only ever passed to openssl as arguments.
add_hosts_file() {
  local file="$1"
  local line
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    err "--hosts-file: not a readable file: $file"
    exit 3
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] || continue
    add_hosts "$line"
  done < "$file"
}

while (( $# > 0 )); do
  case "$1" in
    --file)      require_value "$1" "${2:-}"; add_files "$2"; shift ;;
    --file=*)    add_files "${1#*=}"; require_value "--file" "${1#*=}" ;;
    --host)      require_value "$1" "${2:-}"; add_hosts "$2"; shift ;;
    --host=*)    add_hosts "${1#*=}"; require_value "--host" "${1#*=}" ;;
    --hosts-file)   require_value "$1" "${2:-}"; add_hosts_file "$2"; shift ;;
    --hosts-file=*) require_value "--hosts-file" "${1#*=}"; add_hosts_file "${1#*=}" ;;
    --check-host)   require_value "$1" "${2:-}"; CHECK_HOST="$2"; shift ;;
    --check-host=*) CHECK_HOST="${1#*=}"; require_value "--check-host" "$CHECK_HOST" ;;
    --cafile)   require_value "$1" "${2:-}"; CAFILE="$2"; shift ;;
    --cafile=*) CAFILE="${1#*=}"; require_value "--cafile" "$CAFILE" ;;
    --min-key-bits)   require_value "$1" "${2:-}"; MIN_KEY_BITS="$2"; shift ;;
    --min-key-bits=*) MIN_KEY_BITS="${1#*=}"; require_value "--min-key-bits" "$MIN_KEY_BITS" ;;
    --deep)      DEEP=1 ;;
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

if ! [[ "$MIN_KEY_BITS" =~ ^[0-9]+$ ]] || (( ${#MIN_KEY_BITS} > 5 || 10#$MIN_KEY_BITS < 1024 || 10#$MIN_KEY_BITS > 16384 )); then
  err "--min-key-bits must be an integer between 1024 and 16384, got: $MIN_KEY_BITS"
  exit 3
fi
MIN_KEY_BITS=$((10#$MIN_KEY_BITS))

if [[ -n "$CAFILE" && ! -r "$CAFILE" ]]; then
  err "--cafile must be a readable file, got: $CAFILE"
  exit 3
fi

# A name to check is handed to openssl as one argument; it never needs more
# than a DNS name or an address can hold.
if [[ -n "$CHECK_HOST" ]] && ! [[ "$CHECK_HOST" =~ ^[A-Za-z0-9.:*_-]+$ ]]; then
  err "--check-host must be a DNS name or an IP address, got: $CHECK_HOST"
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

# --cafile means "trust this and nothing else". openssl can be told to ignore
# its default directory and store with -no-CApath and -no-CAstore (the latter
# is OpenSSL 3.0+), but only newer builds know them, so each command's help is
# probed once for what it lists (a here-string, so no pipe to a closing grep).
# CA_SC and CA_VF hold the flags to add to s_client and verify;
# CA_EXCLUSIVE=0 means system trust sources may still apply, and the run says
# so.
CA_SC=()
CA_VF=()
CA_EXCLUSIVE=1
if [[ -n "$CAFILE" ]]; then
  ca_help_sc="$(openssl s_client -help 2>&1 || true)"
  ca_help_vf="$(openssl verify -help 2>&1 || true)"
  ca_version="$(openssl version 2>&1 || true)"
  for ca_flag in -no-CApath -no-CAstore; do
    [[ "$ca_help_sc" == *"$ca_flag"* ]] && CA_SC+=("$ca_flag")
    [[ "$ca_help_vf" == *"$ca_flag"* ]] && CA_VF+=("$ca_flag")
  done
  # A build with no -no-CApath cannot be told to drop its directory. One
  # without -no-CAstore is fine only when it predates stores (before 3.0).
  case " ${CA_SC[*]:-} " in *" -no-CApath "*) ;; *) CA_EXCLUSIVE=0 ;; esac
  case " ${CA_VF[*]:-} " in *" -no-CApath "*) ;; *) CA_EXCLUSIVE=0 ;; esac
  case "$ca_version" in
    "OpenSSL 0."*|"OpenSSL 1."*|LibreSSL*) ;;
    *)
      case " ${CA_SC[*]:-} " in *" -no-CAstore "*) ;; *) CA_EXCLUSIVE=0 ;; esac
      case " ${CA_VF[*]:-} " in *" -no-CAstore "*) ;; *) CA_EXCLUSIVE=0 ;; esac
      ;;
  esac
fi

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

# HOST, HOST:PORT, [IPv6] or [IPv6]:PORT. An unbracketed address with more
# than one colon is ambiguous and leaves HOST_NAME empty. HOST_TARGET is the
# host:port form s_client wants (an IPv6 address stays bracketed).
HOST_TARGET=""
split_host_port() {
  local spec="$1" rest
  spec="${spec#https://}"
  spec="${spec%%/*}"
  HOST_NAME=""
  HOST_PORT=""
  HOST_TARGET=""
  if [[ "$spec" == "["* ]]; then
    rest="${spec#\[}"
    [[ "$rest" == *"]"* ]] || return 0
    HOST_NAME="${rest%%\]*}"
    rest="${rest#*\]}"
    if [[ -z "$rest" ]]; then
      HOST_PORT=443
    elif [[ "$rest" == :* ]]; then
      HOST_PORT="${rest#:}"
    else
      HOST_NAME=""
      return 0
    fi
    [[ "$HOST_NAME" == *:* ]] || { HOST_NAME=""; return 0; }
  elif [[ "$spec" == *:*:* ]]; then
    return 0
  elif [[ "$spec" == *:* ]]; then
    HOST_NAME="${spec%:*}"
    HOST_PORT="${spec##*:}"
  else
    HOST_NAME="$spec"
    HOST_PORT=443
  fi
  if [[ "$HOST_NAME" == *:* ]]; then
    HOST_TARGET="[${HOST_NAME}]:${HOST_PORT}"
  else
    HOST_TARGET="${HOST_NAME}:${HOST_PORT}"
  fi
}

# One handshake per host. Its whole output is kept so the leaf (for expiry)
# and the verify result (for --deep) come from the same connection; stdin is a
# single newline so s_client never waits for input, and timeout bounds it.
HOST_PEM=""
HOST_LAST_PEM=""
HOST_VERIFY=""
fetch_host() {
  local host="$1"
  local port="$2"
  local target="${host}:${port}"
  [[ "$host" == *:* ]] && target="[${host}]:${port}"
  local out
  local args=(s_client -connect "$target" -servername "$host" -showcerts)
  [[ -n "$CAFILE" ]] && args+=(-CAfile "$CAFILE" ${CA_SC[@]+"${CA_SC[@]}"})
  if have timeout; then
    out="$(printf '\n' | timeout 10 openssl "${args[@]}" 2>/dev/null)"
  else
    out="$(printf '\n' | openssl "${args[@]}" 2>/dev/null)"
  fi
  HOST_PEM="$(openssl x509 2>/dev/null <<<"$out" || true)"
  # The last certificate the server sent, to tell a missing intermediate from
  # a trust anchor this machine simply does not have.
  HOST_LAST_PEM="$(awk '/-----BEGIN CERTIFICATE-----/ { buf = "" ; on = 1 }
    on { buf = buf $0 "\n" }
    /-----END CERTIFICATE-----/ { on = 0; last = buf }
    END { printf "%s", last }' <<<"$out")"
  HOST_VERIFY="$(awk '/Verify return code:/ { sub(/^.*Verify return code: */, ""); print; exit }' <<<"$out")"
}

# --check-host, and the name part of --deep. -checkhost needs OpenSSL 1.0.2;
# an address is matched against the IP entries with -checkip instead.
CHECKHOST_SKIPPED=0
grade_name() {
  local label="$1" pem="$2" name="$3" out flag="-checkhost"
  name="${name#[}"
  name="${name%]}"
  if [[ "$name" =~ ^[0-9.]+$ || "$name" == *:* ]]; then
    flag="-checkip"
  fi
  out="$(printf '%s\n' "$pem" | openssl x509 -noout "$flag" "$name" 2>&1)"
  case "$out" in
    *"does NOT match"*)
      fail "$label: certificate does not cover $name" "served SANs: openssl x509 -noout -ext subjectAltName"
      ;;
    *"does match"*)
      pass "$label covers $name"
      ;;
    *)
      if (( CHECKHOST_SKIPPED == 0 )); then
        skip "this openssl cannot check names ($flag needs OpenSSL 1.0.2 or newer)"
        CHECKHOST_SKIPPED=1
      fi
      ;;
  esac
}

# Codes 20 and 21 mean OpenSSL found no issuer for the last certificate it
# had, which is also what a private root that is merely absent here looks
# like. Call the intermediate missing only when the last certificate the
# server sent is not self-signed, is not a CA (the server sent no CA
# certificate at all), and its issuer is not in the trust store used.
chain_lacks_intermediate() {
  local pem="$1" subject issuer vout
  [[ -n "$pem" ]] || return 1
  subject="$(printf '%s\n' "$pem" | openssl x509 -noout -subject 2>/dev/null || true)"
  issuer="$(printf '%s\n' "$pem" | openssl x509 -noout -issuer 2>/dev/null || true)"
  [[ -n "$subject" && "${subject#subject=}" != "${issuer#issuer=}" ]] || return 1
  if printf '%s\n' "$pem" | openssl x509 -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
    return 1
  fi
  if [[ -n "$CAFILE" ]]; then
    vout="$(printf '%s\n' "$pem" | openssl verify -CAfile "$CAFILE" ${CA_VF[@]+"${CA_VF[@]}"} 2>&1 || true)"
  else
    vout="$(printf '%s\n' "$pem" | openssl verify 2>&1 || true)"
  fi
  grep -qE 'error (2|20) at' <<<"$vout"
}

# The verify code from the handshake. 10 (expired) is the expiry check's
# finding already and is not counted twice.
grade_chain() {
  local label="$1" verify="$2" last_pem="${3:-}" code
  if [[ -z "$verify" ]]; then
    skip "$label: the handshake printed no verify result"
    return
  fi
  code="${verify%% *}"
  case "$code" in
    0)     pass "$label chain verifies against the system trust store" ;;
    18|19) warn "$label: self-signed certificate ($verify)" "clients trust it only if they pin it or its CA" ;;
    20|21)
      if chain_lacks_intermediate "$last_pem"; then
        fail "$label: incomplete chain: the server sent no CA certificate and the issuer is not in the trust store ($verify)" "serve fullchain.pem rather than cert.pem, or pass the private CA's root with --cafile"
      else
        warn "$label: issuer not trusted locally: private CA or missing intermediate ($verify)" "if it is a private CA, pass its root with --cafile; else: openssl s_client -connect ${HOST_TARGET} -servername ${HOST_NAME} -showcerts"
      fi
      ;;
    10)    : ;;
    *)     warn "$label: chain does not verify ($verify)" "openssl s_client -connect ${HOST_TARGET} -servername ${HOST_NAME} -showcerts" ;;
  esac
}

# A file has no handshake to verify, but a leaf that issued itself is visible
# from the certificate alone.
grade_self_signed() {
  local label="$1" pem="$2" subject issuer
  subject="$(printf '%s\n' "$pem" | openssl x509 -noout -subject 2>/dev/null || true)"
  issuer="$(printf '%s\n' "$pem" | openssl x509 -noout -issuer 2>/dev/null || true)"
  subject="${subject#subject=}"
  issuer="${issuer#issuer=}"
  if [[ -n "$subject" && "$subject" == "$issuer" ]]; then
    warn "$label: self-signed certificate (subject is its own issuer)" "clients trust it only if they pin it or its CA"
  else
    pass "$label is issued by another certificate"
  fi
}

# Key size and signature algorithm from the text dump. RSA and DSA are graded
# by bits against --min-key-bits, EC by curve, Ed25519/Ed448 always pass. MD5
# and SHA-1 signatures fail; "sha1" is matched as a whole name so SHA-256
# never is.
grade_strength() {
  local label="$1" pem="$2" text bits algo curve sig kind weak=0
  text="$(printf '%s\n' "$pem" | openssl x509 -noout -text 2>/dev/null || true)"
  if [[ -z "$text" ]]; then
    skip "$label: openssl could not print the certificate text"
    return
  fi
  bits="$(awk 'match($0, /Public-Key: \([0-9]+ bit\)/) { s = substr($0, RSTART + 13); sub(/ bit.*/, "", s); print s; exit }' <<<"$text")"
  algo="$(awk -F': ' '/Public Key Algorithm:/ { print $2; exit }' <<<"$text")"
  curve="$(awk '/ASN1 OID:/ { print $3; exit }' <<<"$text")"
  sig="$(awk '/Signature Algorithm:/ { sub(/^.*Signature Algorithm: */, ""); print; exit }' <<<"$text")"
  case "$algo" in
    id-ecPublicKey)
      kind="EC ${curve:-unknown curve}"
      case "$curve" in
        prime256v1|secp384r1|secp521r1) ;;
        *) warn "$label: EC key on ${curve:-an unknown curve}" "reissue on prime256v1 or secp384r1"; weak=1 ;;
      esac
      ;;
    ED25519|ED448)
      kind="$algo"
      ;;
    *)
      kind="RSA"
      [[ "$algo" == dsaEncryption ]] && kind="DSA"
      if [[ "$bits" =~ ^[0-9]+$ ]] && (( bits < MIN_KEY_BITS )); then
        fail "$label: $kind key is $bits bits (minimum $MIN_KEY_BITS)" "reissue with a key of at least $MIN_KEY_BITS bits, or an EC key"
        weak=1
      fi
      ;;
  esac
  if grep -qiE '(md2|md5|sha1)([^0-9]|$)' <<<"$sig"; then
    fail "$label: signed with $sig" "reissue: clients reject MD5 and SHA-1 signatures"
    weak=1
  fi
  (( weak )) || pass "$label strength: ${bits:+$bits bit }$kind, ${sig:-unknown signature}"
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
    [[ -n "$CHECK_HOST" ]] && grade_name "$f" "$pem" "$CHECK_HOST"
    if (( DEEP )); then
      grade_self_signed "$f" "$pem"
      grade_strength "$f" "$pem"
    fi
  done
fi

if (( ${#HOSTS[@]} > 0 )); then
  group "hosts"
  if [[ -n "$CAFILE" ]] && (( ! CA_EXCLUSIVE )); then
    info "--cafile: this openssl cannot ignore its default trust sources, so system trust sources may still apply"
  fi
  for spec in "${HOSTS[@]}"; do
    split_host_port "$spec"
    if [[ -z "$HOST_NAME" || -z "$HOST_PORT" ]] || ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]]; then
      fail "$spec: host must be HOST, HOST:PORT, [IPv6] or [IPv6]:PORT (an IPv6 address needs brackets)"
      continue
    fi
    fetch_host "$HOST_NAME" "$HOST_PORT"
    pem="$HOST_PEM"
    if [[ -z "$pem" ]]; then
      warn "$spec: could not fetch a leaf certificate" "openssl s_client -connect ${HOST_TARGET} -servername ${HOST_NAME}"
      continue
    fi
    grade_pem "$spec" "$pem"
    if (( DEEP )) || [[ -n "$CHECK_HOST" ]]; then
      grade_name "$spec" "$pem" "${CHECK_HOST:-$HOST_NAME}"
    fi
    if (( DEEP )); then
      grade_chain "$spec" "$HOST_VERIFY" "$HOST_LAST_PEM"
      grade_strength "$spec" "$pem"
    fi
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

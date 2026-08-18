#!/usr/bin/env bash
# ssh_client_doctor.sh
# Read-only check of this user's OpenSSH client directory.
#
# hardening_audit.sh grades sshd. git/git_ssh_doctor.py asks ssh -G why a
# git remote will not accept a key. Neither looks at ~/.ssh itself: a
# directory that is group-readable, a private key at 644, or an IdentityFile
# that points at a path that does not exist. Those are the three reasons
# ssh refuses a key with a message that names none of them.
#
# This script does not reimplement ssh_config parsing. Include globs,
# host-specific IdentityFile selection and agent offering stay in
# git_ssh_doctor.py, which asks OpenSSH. Here the questions are local:
# modes, missing files, and IdentityFile paths written in ~/.ssh/config.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
set -u
set -o pipefail

FAIL_ON="fail"
QUIET=0
SSH_DIR=""

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
ssh_client_doctor.sh - read-only OpenSSH client directory check

Reports permission and IdentityFile problems under ~/.ssh. Changes nothing.
Does not parse ssh -G; use git/git_ssh_doctor.py for effective config.

Usage:
  $(basename "$0") [--ssh-dir DIR] [--fail-on warn|fail] [--quiet]

Options:
  --ssh-dir DIR    Directory to inspect (default: ~/.ssh)
  --fail-on LEVEL  Exit 1 on 'fail' (default) or on 'warn' and above
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

while (( $# > 0 )); do
  case "$1" in
    --ssh-dir)   require_value "$1" "${2:-}"; SSH_DIR="$2"; shift ;;
    --ssh-dir=*) SSH_DIR="${1#*=}"; require_value "--ssh-dir" "$SSH_DIR" ;;
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
  warn|fail) ;;
  *) err "--fail-on must be warn or fail, got: $FAIL_ON"; exit 3 ;;
esac

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

if [[ -z "$SSH_DIR" ]]; then
  if [[ -z "${HOME:-}" ]]; then
    err "\$HOME is not set; pass --ssh-dir DIR"
    exit 2
  fi
  SSH_DIR="$HOME/.ssh"
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# OpenSSH refuses a private key (and ~/.ssh itself) when group or other have
# any permission bit set. Owner bits can be 7/6/5/4; the last two digits
# must be 0.
mode_private() {
  local mode="$1"
  [[ "$mode" =~ ^[0-7]00$ ]]
}

# Config, authorized_keys and known_hosts may be 644; group- or world-writable
# is the usual accident OpenSSH will still read, and that we still flag.
mode_publicish() {
  local mode="$1"
  local group other
  [[ "$mode" =~ ^[0-7][0-7][0-7]$ ]] || return 1
  group="${mode:1:1}"
  other="${mode:2:1}"
  # OpenSSH objects to these files being *writable* by group or other, not to
  # them being readable or traversable. Enumerating 0 and 4 also rejected 5
  # (r-x) and 1 (--x), so a directory-ish 755 config failed against a hint that
  # said "group/other write is not [accepted]" — naming a bit 755 does not set.
  # Test the write bit, which is what the hint always claimed to be testing.
  (( (group & 2) == 0 )) || return 1
  (( (other & 2) == 0 )) || return 1
  return 0
}

is_private_key() {
  local path="$1"
  local base
  base="$(basename "$path")"
  case "$base" in
    *.pub|config|known_hosts|known_hosts.old|known_hosts2|authorized_keys|authorized_keys2|rc|environment|agent)
      return 1
      ;;
    id_rsa|id_ed25519|id_ecdsa|id_dsa|id_ecdsa_sk|id_ed25519_sk)
      return 0
      ;;
  esac
  [[ -f "$path" ]] || return 1
  grep -q -E -- '-----BEGIN .*PRIVATE KEY-----' "$path" 2>/dev/null
}

expand_identity() {
  local raw="$1"
  local home="${HOME:-}"
  raw="${raw#\"}"
  raw="${raw%\"}"
  raw="${raw#\'}"
  raw="${raw%\'}"
  case "$raw" in
    %h*|%r*|%u*|%l*)
      printf '\n'
      return 0
      ;;
    %d*)
      raw="${home}${raw#%d}"
      ;;
    "~/"*)
      raw="${home}${raw#\~}"
      ;;
    "~")
      raw="$home"
      ;;
  esac
  printf '%s\n' "$raw"
}

if [[ ! -e "$SSH_DIR" ]]; then
  group "ssh-dir"
  skip "$SSH_DIR does not exist (no client keys on this account)"
  printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
  printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
    "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
    "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
    "$C_RED" "$FAIL_COUNT" "$C_RESET" \
    "$C_DIM" "$SKIP_COUNT" "$C_RESET"
  exit 0
fi

if [[ ! -d "$SSH_DIR" ]]; then
  err "$SSH_DIR is not a directory"
  exit 2
fi

group "directory"
dir_mode="$(stat -c '%a' "$SSH_DIR" 2>/dev/null || printf '')"
if [[ -z "$dir_mode" ]]; then
  skip "could not read mode of $SSH_DIR"
elif mode_private "$dir_mode"; then
  pass "$SSH_DIR mode $dir_mode"
else
  fail "$SSH_DIR mode $dir_mode" "OpenSSH ignores keys here unless group/other bits are clear: chmod 700 $SSH_DIR"
fi

group "files"
found_key=0
found_pub=0
shopt -s nullglob
for path in "$SSH_DIR"/*; do
  [[ -e "$path" ]] || continue
  [[ -f "$path" ]] || continue
  base="$(basename "$path")"
  mode="$(stat -c '%a' "$path" 2>/dev/null || printf '')"
  [[ -n "$mode" ]] || continue
  if is_private_key "$path"; then
    found_key=1
    if mode_private "$mode"; then
      pass "$base mode $mode"
    else
      fail "$base mode $mode" "private keys must not be group- or world-accessible: chmod 600 $path"
    fi
  else
    case "$base" in
      *.pub) found_pub=1 ;;
    esac
    case "$base" in
      config|authorized_keys|authorized_keys2|known_hosts|known_hosts.old|known_hosts2)
        if mode_publicish "$mode"; then
          pass "$base mode $mode"
        else
          fail "$base mode $mode" "chmod 600 $path (644 is accepted; group/other write is not)"
        fi
        ;;
    esac
  fi
done
shopt -u nullglob

(( found_key )) || info "no private keys under $SSH_DIR"
(( found_pub )) || info "no public keys under $SSH_DIR"

group "config"
config="$SSH_DIR/config"
if [[ ! -f "$config" ]]; then
  skip "no config file (OpenSSH defaults apply)"
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      ''|\#*) continue ;;
    esac
    # Host-specific IdentityFile still matters: a missing path is a missing
    # path even if this script does not know which Host block it belongs to.
    key=""
    rest=""
    read -r key rest <<< "$trimmed"
    key_lc="$(printf '%s\n' "$key" | tr '[:upper:]' '[:lower:]')"
    [[ "$key_lc" == "identityfile" ]] || continue
    ident="$(expand_identity "$rest")"
    [[ -n "$ident" ]] || { info "IdentityFile $rest uses a remote token; not checked here"; continue; }
    if [[ "$ident" != /* ]]; then
      if [[ -f "$SSH_DIR/$ident" ]]; then
        ident="$SSH_DIR/$ident"
      elif [[ -n "${HOME:-}" && -f "$HOME/$ident" ]]; then
        ident="$HOME/$ident"
      fi
    fi
    if [[ -f "$ident" ]]; then
      pass "IdentityFile $rest"
    else
      warn "IdentityFile $rest does not exist" "ssh will skip this key with no useful error: $ident"
    fi
  done < "$config"
fi

printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

case "$FAIL_ON" in
  warn) (( FAIL_COUNT + WARN_COUNT > 0 )) && exit 1; exit 0 ;;
  fail) (( FAIL_COUNT > 0 )) && exit 1; exit 0 ;;
esac
exit 0

#!/usr/bin/env bash
# ssh_client_doctor.sh
# Read-only check of this user's OpenSSH client directory on a Mac.
#
# The macOS half of linux/ssh_client_doctor.sh, down to the flags, the verdict
# grammar and the exit codes, plus what a Mac adds: key strength, a private
# key with no passphrase, and the Keychain options that keep a passphrase
# from being asked for on every connection.
#
# ssh refuses a key with "Permission denied (publickey)" and names the reason
# only at -v: ~/.ssh is group-readable, a private key is 644, an IdentityFile
# points at a path that is gone. workstation_doctor.sh lists which public keys
# exist; hardening_audit.sh grades Remote Login; git/git_ssh_doctor.py asks
# ssh -G about one git remote. None of them looks at ~/.ssh itself.
#
# This script does not reimplement ssh_config. It reads ~/.ssh/config line by
# line, never follows Include and never evaluates Match; ssh -G (and
# git/git_ssh_doctor.py) is the tool for the effective configuration.
#
# It never changes a mode: every fix is printed, not run. ssh-keygen is asked
# about private keys with stdin from /dev/null, an empty -P so it can never
# prompt, and its output discarded, so no key material reaches the terminal.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold
#   2   preflight failed (not macOS, or HOME unset without --ssh-dir)
#   3   bad CLI arguments
set -u
set -o pipefail

FAIL_ON="fail"
QUIET=0
SSH_DIR=""
ONLY=""
LIST_GROUPS=0

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

ALL_GROUPS="dir files keys config"

usage() {
  cat <<EOF
ssh_client_doctor.sh - read-only OpenSSH client directory check for macOS

Reports permission, key and ~/.ssh/config problems, each with the command
that fixes it. Changes nothing. Does not evaluate Include or Match; use
git/git_ssh_doctor.py (ssh -G) for the effective configuration.

Usage:
  $(basename "$0") [--ssh-dir DIR] [--only GROUPS] [--fail-on warn|fail] [--quiet]

Options:
  --ssh-dir DIR    Directory to inspect (default: ~/.ssh)
  --only GROUPS    Comma-separated subset (see --list-groups)
  --fail-on LEVEL  Exit 1 on 'fail' (default) or on 'warn' and above
  --quiet          Print only warnings and failures
  --list-groups    Print the group names and exit
  --help, -h       Show this help

Groups:
  dir      the directory's own mode
  files    private keys 600, config/known_hosts/authorized_keys not writable
  keys     DSA and short RSA keys, private keys with no passphrase
  config   missing IdentityFile paths, risky options under Host *, Keychain

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
    --only)      require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)    ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --fail-on)   require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*) FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --quiet)     QUIET=1 ;;
    --list-groups) LIST_GROUPS=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( LIST_GROUPS )); then
  # shellcheck disable=SC2086  # the group list is split on purpose
  printf '%s\n' $ALL_GROUPS
  exit 0
fi

case "$FAIL_ON" in
  warn|fail) ;;
  *) err "--fail-on must be warn or fail, got: $FAIL_ON"; exit 3 ;;
esac

if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a requested <<< "$ONLY"
  for g in ${requested[@]+"${requested[@]}"}; do
    case " $ALL_GROUPS " in
      *" $g "*) ;;
      *) err "unknown group: $g (see --list-groups)"; exit 3 ;;
    esac
  done
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS"
  exit 2
fi

if [[ -z "$SSH_DIR" ]]; then
  if [[ -z "${HOME:-}" ]]; then
    err "\$HOME is not set; pass --ssh-dir DIR"
    exit 2
  fi
  SSH_DIR="$HOME/.ssh"
fi

want() {
  [[ -z "$ONLY" ]] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

summary() {
  printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
  printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
    "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
    "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
    "$C_RED" "$FAIL_COUNT" "$C_RESET" \
    "$C_DIM" "$SKIP_COUNT" "$C_RESET"
}

# Config text is data: control characters are stripped before it is printed.
clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# Permission bits of a path as octal. BSD stat answers on a Mac; GNU stat
# answers in the Linux test container. GNU `stat -f` means --file-system and
# prints filesystem details on stdout as well as failing, so each answer is
# accepted only when it looks like a mode.
file_mode() {
  local m
  m="$(stat -f '%Lp' "$1" 2>/dev/null)"
  if [[ ! "$m" =~ ^[0-7]{3,4}$ ]]; then
    m="$(stat -c '%a' "$1" 2>/dev/null)"
  fi
  [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
  printf '%s\n' "$m"
}

# OpenSSH refuses a private key (and ~/.ssh itself) when group or other have
# any permission bit set. Owner bits can be 7/6/5/4; the last two digits
# must be 0.
mode_private() {
  local mode="$1"
  [[ "$mode" =~ ^0?[0-7]00$ ]]
}

# Config, authorized_keys and known_hosts may be 644; group- or world-writable
# is the usual accident OpenSSH will still read, and that we still flag. The
# write bit is what is tested, as in linux/ssh_client_doctor.sh.
mode_publicish() {
  local mode="$1"
  local group other
  mode="${mode#0}"
  [[ "$mode" =~ ^[0-7][0-7][0-7]$ ]] || return 1
  group="${mode:1:1}"
  other="${mode:2:1}"
  (( (group & 2) == 0 )) || return 1
  (( (other & 2) == 0 )) || return 1
  return 0
}

is_private_key() {
  local path="$1"
  local base head5
  base="$(basename "$path")"
  case "$base" in
    *.pub|config|known_hosts|known_hosts.old|known_hosts2|authorized_keys|authorized_keys2|rc|environment|agent)
      return 1
      ;;
    id_rsa|id_ed25519|id_ecdsa|id_dsa|id_ecdsa_sk|id_ed25519_sk|*_sk)
      return 0
      ;;
  esac
  [[ -f "$path" ]] || return 1
  head5="$(head -n 5 "$path" 2>/dev/null | tr -d '\000')"
  grep -q -E -- '-----BEGIN .*PRIVATE KEY-----' <<< "$head5"
}

# Does this private key open with an empty passphrase? -P "" makes ssh-keygen
# non-interactive and stdin is /dev/null besides; the public key it prints on
# success is discarded with everything else. Exit 0 means "no passphrase".
key_unencrypted() {
  ssh-keygen -y -P "" -f "$1" </dev/null >/dev/null 2>&1
}

expand_identity() {
  local raw="$1"
  local home="${HOME:-}"
  raw="${raw#\"}"
  raw="${raw%\"}"
  raw="${raw#\'}"
  raw="${raw%\'}"
  # shellcheck disable=SC2088  # a literal ~ in the config is matched, not expanded
  case "$raw" in
    %h*|%r*|%u*|%l*|*%h*|*%r*|*%u*|*%l*|*%n*|*%C*)
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
  summary
  exit 0
fi

if [[ ! -d "$SSH_DIR" ]]; then
  err "$SSH_DIR is not a directory"
  exit 2
fi

HAVE_KEYGEN=0
command -v ssh-keygen >/dev/null 2>&1 && HAVE_KEYGEN=1

# Private keys found in the directory, newline-separated, for the keys group.
PRIVATE_KEYS=""
shopt -s nullglob
for path in "$SSH_DIR"/*; do
  [[ -f "$path" ]] || continue
  is_private_key "$path" && PRIVATE_KEYS="$PRIVATE_KEYS$path"$'\n'
done
shopt -u nullglob

# --- dir ---------------------------------------------------------------------
if want dir; then
  group "dir"
  dir_mode="$(file_mode "$SSH_DIR")" || dir_mode=""
  if [[ -z "$dir_mode" ]]; then
    skip "could not read mode of $SSH_DIR"
  elif mode_private "$dir_mode"; then
    pass "$SSH_DIR mode $dir_mode"
  else
    fail "$SSH_DIR mode $dir_mode" "OpenSSH ignores keys here unless group/other bits are clear: chmod 700 $SSH_DIR"
  fi
fi

# --- files -------------------------------------------------------------------
if want files; then
  group "files"
  found_pub=0
  shopt -s nullglob
  for path in "$SSH_DIR"/*; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path")"
    mode="$(file_mode "$path")" || continue
    if is_private_key "$path"; then
      if mode_private "$mode"; then
        pass "$base mode $mode"
      else
        fail "$base mode $mode" "private keys must not be group- or world-accessible: chmod 600 $path"
      fi
    else
      case "$base" in
        *.pub) found_pub=1 ;;
        config|authorized_keys|authorized_keys2|known_hosts|known_hosts.old|known_hosts2)
          if mode_publicish "$mode"; then
            pass "$base mode $mode"
          else
            warn "$base mode $mode" "chmod 600 $path (644 is accepted; group/other write is not)"
          fi
          ;;
      esac
    fi
  done
  shopt -u nullglob
  [[ -n "$PRIVATE_KEYS" ]] || info "no private keys under $SSH_DIR"
  (( found_pub )) || info "no public keys under $SSH_DIR"
fi

# --- keys --------------------------------------------------------------------
# Strength comes from the private key (ssh-keygen -l -f KEY); the .pub is
# only compared against it, and used when the private key cannot be read.
# DSA has been refused by OpenSSH since 7.0; RSA under 3072 bits is below what
# NIST and OpenSSH's own default have asked for since 2020.
if want keys; then
  group "keys"
  if (( HAVE_KEYGEN == 0 )); then
    skip "ssh-keygen not found; key strength and passphrases not checked"
  elif [[ -z "$PRIVATE_KEYS" ]]; then
    skip "no private keys to grade"
  else
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      base="$(basename "$key")"
      ktype=""
      # The private key is the truth. A .pub beside it can be stale, copied
      # from another key or hand-edited, so strength is read from the private
      # file; -P "" and a closed stdin make an encrypted old-format key fail
      # at once instead of prompting. Only if that fails is the .pub used.
      fp="$(ssh-keygen -l -P "" -f "$key" </dev/null 2>/dev/null | head -n 1)"
      src="$base"
      pub_fp=""
      if [[ -f "$key.pub" ]]; then
        pub_fp="$(ssh-keygen -l -f "$key.pub" </dev/null 2>/dev/null | head -n 1)"
      fi
      if [[ -z "$fp" && -n "$pub_fp" ]]; then
        fp="$pub_fp"
        src="$base.pub"
        info "$base: could not read the private key, strength taken from $base.pub"
      fi
      if [[ -n "$fp" ]]; then
        bits="${fp%% *}"
        ktype="${fp##*(}"
        ktype="${ktype%)*}"
        ktype="$(clean "$ktype")"
        if [[ ! "$bits" =~ ^[0-9]+$ ]]; then
          skip "$base: could not read the key type from $src"
        elif [[ "$ktype" == "DSA" ]]; then
          fail "$base is a DSA key" "OpenSSH refuses DSA keys; make a new one: ssh-keygen -t ed25519"
        elif [[ "$ktype" == "RSA" ]] && (( bits < 3072 )); then
          warn "$base is a ${bits}-bit RSA key" "under 3072 bits is weak; make a new one: ssh-keygen -t ed25519"
        else
          pass "$base: $ktype $bits"
        fi
        # Compare the fingerprint field (the second word) of both halves.
        if [[ "$src" == "$base" && -n "$pub_fp" ]]; then
          priv_hash="${fp#* }"
          priv_hash="${priv_hash%% *}"
          pub_hash="${pub_fp#* }"
          pub_hash="${pub_hash%% *}"
          if [[ -n "$priv_hash" && -n "$pub_hash" && "$priv_hash" != "$pub_hash" ]]; then
            warn "$base.pub does not match $base (fingerprints differ)" \
                 "the public file is stale or from another key; regenerate it: ssh-keygen -y -f $key > $key.pub"
          fi
        fi
      else
        skip "$base: could not read the key type (no readable private key or $base.pub)"
      fi
      # A security-key (FIDO) private file is a handle, not a secret, and opens
      # without a passphrase by design.
      case "$base:$ktype" in
        *_sk:*|*:*-SK) continue ;;
      esac
      # ssh-keygen refuses to open a key whose mode is too open, which would
      # read as "has a passphrase". The files group already failed that mode.
      kmode="$(file_mode "$key")" || kmode=""
      if [[ -z "$kmode" ]] || ! mode_private "$kmode"; then
        skip "$base: passphrase not checked until its mode is 600"
      elif key_unencrypted "$key"; then
        warn "unencrypted private key: $base" \
             "ssh-keygen -p -f $key, then store it with ssh-add --apple-use-keychain $key"
      else
        pass "$base is passphrase-protected"
      fi
    done <<< "$PRIVATE_KEYS"
  fi
fi

# --- config ------------------------------------------------------------------
# Options before the first Host line, and under a Host line whose patterns
# include a bare *, apply to every host this account connects to. The same
# options under one named host are a deliberate choice and only noted.
if want config; then
  group "config"
  config="$SSH_DIR/config"
  if [[ ! -f "$config" ]]; then
    skip "no config file (OpenSSH defaults apply)"
  else
    all_hosts=1
    host_label="(before any Host line)"
    has_keychain=0
    protected_identity=""
    include_noted=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      trimmed="${line#"${line%%[![:space:]]*}"}"
      case "$trimmed" in
        ''|\#*) continue ;;
      esac
      # Both "Key value" and "Key=value" are ssh_config syntax.
      key="${trimmed%%[[:space:]=]*}"
      rest="${trimmed#"$key"}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      rest="${rest#=}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      rest="${rest%"${rest##*[![:space:]]}"}"
      key_lc="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
      val_lc="$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')"
      shown="$(clean "$rest")"
      case "$key_lc" in
        host)
          all_hosts=0
          # read -a splits without globbing, so "Host *" stays a pattern.
          read -r -a host_patterns <<< "$rest"
          for pat in ${host_patterns[@]+"${host_patterns[@]}"}; do
            [[ "$pat" == "*" ]] && all_hosts=1
          done
          host_label="Host $shown"
          ;;
        match)
          all_hosts=0
          host_label="Match $shown"
          ;;
        include)
          if (( include_noted == 0 )); then
            info "Include is not followed here; git/git_ssh_doctor.py asks ssh -G for the effective config"
            include_noted=1
          fi
          ;;
        usekeychain|addkeystoagent)
          [[ "$val_lc" == "yes" || "$val_lc" == "confirm" || "$val_lc" == "ask" ]] && has_keychain=1
          ;;
        forwardagent)
          if [[ "$val_lc" == "yes" ]]; then
            if (( all_hosts )); then
              warn "ForwardAgent yes applies to every host ($host_label)" \
                   "anyone with root on any server you reach can use your keys; set it under the one Host that needs it"
            else
              info "ForwardAgent yes under $host_label"
            fi
          fi
          ;;
        stricthostkeychecking)
          if [[ "$val_lc" == "no" ]]; then
            if (( all_hosts )); then
              warn "StrictHostKeyChecking no applies to every host ($host_label)" \
                   "host keys are never verified, so a man in the middle is accepted; set it under the one Host that needs it"
            else
              info "StrictHostKeyChecking no under $host_label"
            fi
          fi
          ;;
        userknownhostsfile)
          if [[ "$rest" == "/dev/null" ]]; then
            if (( all_hosts )); then
              warn "UserKnownHostsFile /dev/null applies to every host ($host_label)" \
                   "no host key is ever remembered, so none is ever checked; set it under the one Host that needs it"
            else
              info "UserKnownHostsFile /dev/null under $host_label"
            fi
          fi
          ;;
        identityfile)
          ident="$(expand_identity "$rest")"
          if [[ -z "$ident" ]]; then
            info "IdentityFile $shown uses a per-connection token; not checked here"
            continue
          fi
          if [[ "$ident" != /* ]]; then
            if [[ -f "$SSH_DIR/$ident" ]]; then
              ident="$SSH_DIR/$ident"
            elif [[ -n "${HOME:-}" && -f "$HOME/$ident" ]]; then
              ident="$HOME/$ident"
            fi
          fi
          if [[ -f "$ident" ]]; then
            pass "IdentityFile $shown"
            if (( HAVE_KEYGEN )) && [[ -z "$protected_identity" ]] && ! key_unencrypted "$ident"; then
              protected_identity="$shown"
            fi
          else
            warn "IdentityFile $shown does not exist" \
                 "ssh will skip this key with no useful error: $(clean "$ident")"
          fi
          ;;
      esac
    done < "$config"
    if [[ -n "$protected_identity" ]] && (( has_keychain == 0 )); then
      info "$protected_identity has a passphrase and the config sets neither UseKeychain nor AddKeysToAgent"
      info "since macOS Sierra the agent forgets keys at reboot; add 'UseKeychain yes' and 'AddKeysToAgent yes' under Host *"
    fi
  fi
fi

summary

case "$FAIL_ON" in
  warn) (( FAIL_COUNT + WARN_COUNT > 0 )) && exit 1; exit 0 ;;
  fail) (( FAIL_COUNT > 0 )) && exit 1; exit 0 ;;
esac
exit 0

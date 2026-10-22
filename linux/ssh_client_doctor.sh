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
# Past "will ssh use this key" is "should it": a private key with no
# passphrase, a DSA or short RSA key, a key years old, known_hosts entries in
# the clear or in conflict, duplicate authorized_keys lines, a `Host *` block
# that turns off host key checking or forwards the agent everywhere, and an
# SSH_AUTH_SOCK that points at a dead agent. Those are the keys, known_hosts,
# authorized_keys, risks and agent groups; --only picks groups.
#
# Read-only. The only commands run are `ssh-keygen -l` on public keys,
# `ssh-keygen -y -P ''` on private keys with stdin closed (it derives the
# public half to /dev/null and fails on an encrypted key, so it can never
# prompt), and `ssh-add -l`, which lists the agent. Key material is never
# printed: only paths, types, sizes and fingerprints. Commands that would
# change something (ssh-keygen -p, -H, -R) are printed as hints.
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
ONLY=""
MAX_KEY_AGE=730

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
  $(basename "$0") [--ssh-dir DIR] [--only GROUPS] [--max-key-age DAYS]
                       [--fail-on warn|fail] [--quiet]

Options:
  --ssh-dir DIR    Directory to inspect (default: ~/.ssh)
  --only GROUPS    Comma-separated subset (see --list-groups)
  --list-groups    Print the group names and exit
  --max-key-age DAYS  Warn on private keys older than this, 0 to disable (default: $MAX_KEY_AGE)
  --fail-on LEVEL  Exit 1 on 'fail' (default) or on 'warn' and above
  --quiet          Print only warnings and failures
  --help, -h       Show this help

Groups:
  directory        mode of the directory itself
  files            modes of private keys, config, known_hosts, authorized_keys
  config           IdentityFile paths that do not exist
  keys             no passphrase, DSA or short RSA keys, key age, duplicates
  known_hosts      unhashed entries, ssh-dss keys, conflicting keys for a host
  authorized_keys  duplicate keys, ssh-dss keys, keys with no restrictions
  risks            Host * settings that weaken every connection
  agent            whether SSH_AUTH_SOCK reaches a live agent, and how many keys it offers

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

ALL_GROUPS="directory files config keys known_hosts authorized_keys risks agent"

while (( $# > 0 )); do
  case "$1" in
    --ssh-dir)   require_value "$1" "${2:-}"; SSH_DIR="$2"; shift ;;
    --ssh-dir=*) SSH_DIR="${1#*=}"; require_value "--ssh-dir" "$SSH_DIR" ;;
    --only)      require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)    ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --max-key-age)   require_value "$1" "${2:-}"; MAX_KEY_AGE="$2"; shift ;;
    --max-key-age=*) MAX_KEY_AGE="${1#*=}"; require_value "--max-key-age" "$MAX_KEY_AGE" ;;
    --list-groups) printf '%s\n' $ALL_GROUPS; exit 0 ;;
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

if ! [[ "$MAX_KEY_AGE" =~ ^[0-9]+$ ]] || (( ${#MAX_KEY_AGE} > 5 )); then
  err "--max-key-age must be a number of days (0 disables), got: $MAX_KEY_AGE"
  exit 3
fi
MAX_KEY_AGE=$((10#$MAX_KEY_AGE))

if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a requested <<< "$ONLY"
  for g in "${requested[@]+"${requested[@]}"}"; do
    case " $ALL_GROUPS " in
      *" $g "*) ;;
      *) err "unknown group: $g (see --list-groups)"; exit 3 ;;
    esac
  done
fi

want() {
  [[ -z "$ONLY" ]] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

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

if want directory; then
  group "directory"
  dir_mode="$(stat -c '%a' "$SSH_DIR" 2>/dev/null || printf '')"
  if [[ -z "$dir_mode" ]]; then
    skip "could not read mode of $SSH_DIR"
  elif mode_private "$dir_mode"; then
    pass "$SSH_DIR mode $dir_mode"
  else
    fail "$SSH_DIR mode $dir_mode" "OpenSSH ignores keys here unless group/other bits are clear: chmod 700 $SSH_DIR"
  fi
fi

if want files; then
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
fi

# Drops an end-of-line "# comment": a # that is outside quotes and starts the
# line or follows whitespace. A quoted # and one inside a word (a#b) stay.
# Trailing whitespace goes with it.
strip_comment() {
  awk '{
    out = ""; q = ""; n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q != "") { if (c == q) q = "" }
      else if (c == "\"" || c == "\047") q = c
      else if (c == "#" && (i == 1 || substr($0, i - 1, 1) ~ /[ \t]/)) break
      out = out c
    }
    sub(/[ \t]+$/, "", out)
    print out
  }'
}

if want config; then
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
      trimmed="$(strip_comment <<<"$trimmed")"
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
fi

have()  { command -v "$1" >/dev/null 2>&1; }

# Host names, comments and config values are whatever someone wrote into a
# file or a server sent; control characters go before any of it is printed.
clean() { tr -d '\000-\010\013-\037'; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- keys ------------------------------------------------------------------
if want keys; then
  group "keys"
  if ! have ssh-keygen; then
    skip "ssh-keygen not installed; keys not graded"
  else
    fps=""
    n_keys=0
    shopt -s nullglob
    for path in "$SSH_DIR"/*; do
      [[ -f "$path" ]] || continue
      is_private_key "$path" || continue
      n_keys=$((n_keys + 1))
      base="$(basename "$path")"
      # -P '' answers the passphrase prompt with an empty one and stdin is
      # closed, so this cannot wait for input: it derives the public key and
      # succeeds only when no passphrase protects the private one.
      if ssh-keygen -y -P '' -f "$path" </dev/null >/dev/null 2>&1; then
        warn "$base has no passphrase" "ssh-keygen -p -f $path  (fine for a CI deploy key, not for a personal one)"
      else
        pass "$base is passphrase-protected (or unreadable)"
      fi
      # Type and size need no passphrase: ssh-keygen -l reads the public part
      # of an OpenSSH-format private key directly. The .pub beside it is the
      # fallback for formats that hide it, and the check is skipped only
      # when neither answers.
      fp_line="$(ssh-keygen -l -P '' -f "$path" </dev/null 2>/dev/null | clean | head -n 1)"
      if [[ -z "$fp_line" && -f "$path.pub" ]]; then
        fp_line="$(ssh-keygen -l -f "$path.pub" </dev/null 2>/dev/null | clean | head -n 1)"
      fi
      if [[ -z "$fp_line" ]]; then
        skip "$base: ssh-keygen could not read its public part; type and size not checked"
      else
        bits="${fp_line%% *}"
        ktype="${fp_line##* }"
        ktype="${ktype#(}"
        ktype="${ktype%)}"
        fp="$(awk '{ print $2 }' <<<"$fp_line")"
        [[ -n "$fp" ]] && fps="${fps}${fp} ${base}"$'\n'
        [[ "$bits" =~ ^[0-9]+$ ]] || bits=0
        case "$ktype" in
          DSA)
            fail "$base is a DSA key" "OpenSSH refuses DSA by default since 7.0: ssh-keygen -t ed25519, then replace it on each server"
            ;;
          RSA)
            if (( bits < 2048 )); then
              fail "$base is a $bits-bit RSA key" "too short to trust: ssh-keygen -t ed25519, then replace it on each server"
            elif (( bits < 3072 )); then
              warn "$base is a $bits-bit RSA key" "3072 bits or Ed25519 for anything new: ssh-keygen -t ed25519"
            else
              pass "$base is a $bits-bit RSA key"
            fi
            ;;
          ECDSA|ECDSA-SK) info "$base is an $ktype key ($bits bits)" ;;
          ED25519|ED25519-SK) pass "$base is an $ktype key" ;;
          *) skip "$base: could not read a key type" ;;
        esac
      fi
      # The file's age stands in for the key's. A key copied to a new machine
      # looks young; one that has followed you for years does not.
      if (( MAX_KEY_AGE > 0 )); then
        mtime="$(stat -c %Y "$path" 2>/dev/null || printf '')"
        if [[ "$mtime" =~ ^[0-9]+$ ]]; then
          age=$(( ($(date +%s) - mtime) / 86400 ))
          if (( age > MAX_KEY_AGE )); then
            warn "$base is $age days old; consider rotating" "ssh-keygen -t ed25519 -f <new key>, install it everywhere, then retire $base"
          fi
        fi
      fi
    done
    shopt -u nullglob
    (( n_keys > 0 )) || info "no private keys to grade"
    dups="$(awk 'NF == 2 { print $1 }' <<<"$fps" | sort | uniq -d)"
    while read -r fp; do
      [[ -n "$fp" ]] || continue
      info "the same key is in more than one file: $(awk -v f="$fp" '$1 == f { printf "%s ", $2 }' <<<"$fps")"
    done <<< "$dups"
  fi
fi

# --- known_hosts -----------------------------------------------------------
if want known_hosts; then
  group "known_hosts"
  kh="$SSH_DIR/known_hosts"
  if [[ ! -f "$kh" ]]; then
    skip "no known_hosts file"
  else
    # One pass: totals, then one CONFLICT line per host token that holds two
    # different keys of the same type. Hashed entries cannot be compared, and
    # a marker line (@revoked, @cert-authority) is not an ordinary entry.
    kh_out="$(clean < "$kh" | awk '
      /^[ \t]*(#|$)/ { next }
      {
        marker = ""; h = 1
        if ($1 ~ /^@/) { marker = $1; h = 2 }
        host = $h; type = $(h + 1); blob = $(h + 2)
        total++
        if (marker == "@revoked") revoked++
        if (host !~ /^\|1\|/) unhashed++
        if (type ~ /^ssh-dss/) dss++
        if (marker == "" && host !~ /^\|1\|/) {
          # The host field is a comma-separated alias list; every alias is
          # its own key. Negated patterns are not hosts, [host]:22 is host,
          # and host names compare case-insensitively.
          n = split(host, alias, ",")
          for (a = 1; a <= n; a++) {
            h1 = tolower(alias[a])
            if (h1 == "" || h1 ~ /^!/) continue
            if (h1 ~ /^\[.*\]:22$/) h1 = substr(h1, 2, length(h1) - 5)
            k = h1 " " type
            if (!(k in first)) first[k] = blob
            else if (first[k] != blob && !(k in told)) { told[k] = 1; print "CONFLICT", h1, type }
          }
        }
      }
      END { printf "STATS %d %d %d %d\n", total, unhashed, dss, revoked }')"
    read -r _ kh_total kh_unhashed kh_dss kh_revoked <<< "$(grep '^STATS ' <<<"$kh_out")"
    if (( ${kh_total:-0} == 0 )); then
      info "known_hosts has no entries"
    else
      if (( kh_unhashed > 0 )); then
        info "$kh_unhashed of $kh_total entries are unhashed: the file lists every host you reach" \
          "ssh-keygen -H -f $kh (then remove $kh.old), and HashKnownHosts yes in the config"
      else
        pass "all $kh_total known_hosts entries are hashed"
      fi
      if (( kh_dss > 0 )); then
        fail "$kh_dss ssh-dss host key(s) in known_hosts" "DSA host keys are refused by current OpenSSH: ssh-keygen -R <host> -f $kh, then reconnect"
      else
        pass "no ssh-dss host keys in known_hosts"
      fi
      conflicts=0
      while read -r _ host type; do
        [[ -n "${host:-}" ]] || continue
        conflicts=$((conflicts + 1))
        (( conflicts <= 5 )) || continue
        warn "host ${host:0:64} has conflicting $type keys" "ssh-keygen -R '${host:0:64}' -f $kh, then reconnect and verify the fingerprint"
      done <<< "$(grep '^CONFLICT ' <<<"$kh_out")"
      (( conflicts > 5 )) && info "and $(( conflicts - 5 )) more host(s) with conflicting keys"
      (( conflicts == 0 )) && pass "no host has two different keys of one type"
      (( kh_revoked > 0 )) && info "$kh_revoked @revoked key(s) listed"
    fi
  fi
fi

# --- authorized_keys -------------------------------------------------------
if want authorized_keys; then
  group "authorized_keys"
  ak="$SSH_DIR/authorized_keys"
  if [[ ! -f "$ak" ]]; then
    skip "no authorized_keys file"
  else
    # The key type is the field followed by a base64 blob (every key blob
    # starts AAAA); anything before it is options, which may contain spaces.
    ak_out="$(clean < "$ak" | awk '
      /^[ \t]*(#|$)/ { next }
      {
        t = 0
        for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-sha2-|sk-)/ && $(i + 1) ~ /^AAAA/) { t = i; break }
        if (!t) { bad++; next }
        total++
        if ($t ~ /^ssh-dss/) dss++
        if (t == 1) plain++
        if (seen[$(t + 1)]++) dup++
      }
      END { printf "%d %d %d %d %d\n", total, dup, dss, plain, bad }')"
    read -r ak_total ak_dup ak_dss ak_plain ak_bad <<< "$ak_out"
    if (( ${ak_total:-0} == 0 )); then
      info "authorized_keys has no keys"
    else
      if (( ak_dup > 0 )); then
        warn "$ak_dup duplicate key line(s) in authorized_keys" "remove the repeats: sshd uses the first matching line, options and all"
      else
        pass "no duplicate keys in authorized_keys"
      fi
      if (( ak_dss > 0 )); then
        fail "$ak_dss ssh-dss key(s) in authorized_keys" "current OpenSSH refuses them; replace with Ed25519 keys"
      fi
      (( ak_plain > 0 )) && info "$ak_plain of $ak_total key(s) carry no options (from=, command=, restrict)"
    fi
    (( ${ak_bad:-0} > 0 )) && info "${ak_bad} line(s) in authorized_keys are not a key this script recognises"
  fi
fi

# --- risks -----------------------------------------------------------------
# Settings that weaken every connection when they apply to every host. The
# scope is tracked as the file is read: lines before the first Host or Match,
# a Host whose patterns include a bare *, and Match all apply everywhere. The
# same setting under a narrower Host is somebody's deliberate exception and is
# noted, not graded. A keyword already set by an earlier block is not
# universal in a later one (first value wins). Include is not modelled.
if want risks; then
  group "risks"
  config="$SSH_DIR/config"
  if [[ ! -f "$config" ]]; then
    skip "no config file (OpenSSH defaults apply)"
  else
    risks_before=$((WARN_COUNT + FAIL_COUNT))
    scope="before any Host"
    scope_all=1
    scope_only="only for ${scope:0:60}"
    ln=0
    global_ids=0
    global_only=0
    seen_keys=","
    seen_vals=""
    # Succeeds when an earlier line set KEY to something other than VALUE.
    earlier_value_differs() {
      local want_key="$1" want_val="$2" line
      while IFS= read -r line; do
        [[ "$line" == "$want_key="* ]] || continue
        [[ "${line#*=}" == "$want_val" ]] || return 0
      done <<< "$seen_vals"
      return 1
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
      ln=$((ln + 1))
      trimmed="${line#"${line%%[![:space:]]*}"}"
      case "$trimmed" in
        ''|\#*) continue ;;
      esac
      trimmed="$(clean <<<"$trimmed" | strip_comment)"
      [[ -n "$trimmed" ]] || continue
      key=""
      rest=""
      if [[ "$trimmed" =~ ^([A-Za-z0-9]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
      else
        read -r key rest <<< "$trimmed"
      fi
      key_lc="$(lower "$key")"
      val_lc="$(lower "$rest")"
      # OpenSSH reads true as yes and false as no for these keywords, and
      # StrictHostKeyChecking alone also takes off (as no); grade the
      # canonical word rather than the spelling. OpenSSH does not accept
      # "on" here; it is mapped to yes only so it is not misreported.
      case "$key_lc" in
        stricthostkeychecking)
          case "$val_lc" in
            false|off) val_lc="no" ;;
            true|on) val_lc="yes" ;;
          esac
          ;;
        forwardagent|forwardx11|forwardx11trusted|passwordauthentication|identitiesonly|hashknownhosts)
          case "$val_lc" in
            false) val_lc="no" ;;
            true) val_lc="yes" ;;
          esac
          ;;
      esac
      case "$key_lc" in
        host)
          scope="Host $rest"
          scope_all=0
          has_star=0
          negated=""
          # read -a, not an unquoted loop: a bare * must not glob.
          read -r -a pats <<< "$rest"
          for pat in "${pats[@]+"${pats[@]}"}"; do
            [[ "$pat" == "*" ]] && has_star=1
            [[ "$pat" == '!'* ]] && negated="${negated:+$negated }$pat"
          done
          scope_only="only for ${scope:0:60}"
          if (( has_star )); then
            if [[ -z "$negated" ]]; then
              scope_all=1
            else
              # A negated pattern carves hosts out, so it is not global.
              scope_only="for all hosts except ${negated:0:60}"
            fi
          fi
          continue
          ;;
        match)
          scope="Match $rest"
          scope_all=0
          scope_only="only for ${scope:0:60}"
          [[ "$val_lc" == "all" ]] && scope_all=1
          # "Match host *" is the same as Match all, as long as it is the only
          # criterion and no pattern in the list excludes a host.
          if [[ "$val_lc" =~ ^host[[:space:]]+([^[:space:]]+)$ ]]; then
            m_list="${BASH_REMATCH[1]}"
            if [[ ",$m_list," == *,\*,* && "$m_list" != *'!'* ]]; then
              scope_all=1
            fi
          fi
          continue
          ;;
      esac
      where="line $ln, $scope"
      # OpenSSH keeps the first value it obtains for a keyword, so a value
      # under a later Host * or Match all only reaches the hosts that no
      # earlier block set that keyword for.
      line_all=$scope_all
      line_only="$scope_only"
      case "$key_lc" in
        stricthostkeychecking|userknownhostsfile|forwardagent|forwardx11|forwardx11trusted|passwordauthentication|identitiesonly)
          # Same value earlier: every host ends up with it, so a Host * line
          # stays universal. Only a different earlier value demotes it.
          if [[ "$seen_keys" == *",$key_lc,"* ]] && earlier_value_differs "$key_lc" "$val_lc"; then
            line_all=0
            line_only="for hosts not matched by an earlier block that sets it"
          fi
          ;;
      esac
      case "$key_lc" in
        stricthostkeychecking)
          case "$val_lc" in
            no)
              if (( line_all )); then
                fail "StrictHostKeyChecking $rest for every host ($where)" "host keys are never verified, so any server can claim to be any host: use 'StrictHostKeyChecking accept-new'"
              else
                info "StrictHostKeyChecking $rest $line_only (line $ln)"
              fi
              ;;
          esac
          ;;
        userknownhostsfile)
          if [[ "$val_lc" == "/dev/null" ]]; then
            if (( line_all )); then
              warn "UserKnownHostsFile /dev/null for every host ($where)" "no host key is ever remembered, so none can be checked: remove the line"
            else
              info "UserKnownHostsFile /dev/null $line_only (line $ln)"
            fi
          fi
          ;;
        forwardagent|forwardx11|forwardx11trusted|passwordauthentication)
          if [[ "$val_lc" == "yes" ]]; then
            if (( line_all )); then
              case "$key_lc" in
                forwardagent) hint="root on any server you reach can use your keys while you are connected: forward only where needed, or use ProxyJump" ;;
                passwordauthentication) hint="keys only, where the servers allow it: 'PasswordAuthentication no' under Host *" ;;
                *) hint="a server you reach can reach back into your display: set it only for the hosts that need it" ;;
              esac
              warn "$key yes for every host ($where)" "$hint"
            else
              info "$key yes $line_only (line $ln)"
            fi
          fi
          ;;
        protocol)
          [[ "$val_lc" == *1* ]] && warn "Protocol $rest ($where)" "SSH protocol 1 is broken and long removed: delete the line"
          ;;
        ciphers)
          # A leading - removes the names from the default list, so naming a
          # weak cipher there is the fix, not the problem. A leading + or ^
          # adds to the defaults and no prefix replaces them: all three can
          # enable one. A per-line reading, not ssh -G: the line may sit in a
          # Host block that one -G run would not reach.
          cipher_list="${val_lc#[\"\']}"
          if [[ "$cipher_list" != -* && ( "$cipher_list" == *cbc* || "$cipher_list" == *arcfour* ) ]]; then
            warn "Ciphers enables CBC or arcfour ($where)" "remove those names; the OpenSSH defaults are better"
          fi
          ;;
        hashknownhosts)
          [[ "$val_lc" == "no" ]] && info "HashKnownHosts no (line $ln): known_hosts lists every host by name"
          ;;
        identityfile)
          (( line_all )) && global_ids=$((global_ids + 1))
          ;;
        identitiesonly)
          (( line_all )) && [[ "$val_lc" == "yes" ]] && global_only=1
          ;;
      esac
      seen_keys="${seen_keys}${key_lc},"
      seen_vals="${seen_vals}${key_lc}=${val_lc}"$'\n'
    done < "$config"
    if (( global_ids >= 2 && global_only == 0 )); then
      info "ssh offers every key to every server: $global_ids IdentityFile lines apply to all hosts and IdentitiesOnly is not yes"
    fi
    (( WARN_COUNT + FAIL_COUNT == risks_before )) && pass "no config setting weakens every connection"
  fi
fi

# --- agent -----------------------------------------------------------------
if want agent; then
  group "agent"
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    skip "SSH_AUTH_SOCK is not set; no agent in this session"
  elif ! have ssh-add; then
    skip "ssh-add not installed; agent not checked"
  else
    # ssh-add -l lists; it adds nothing. 0 keys listed, 1 none loaded, 2 no
    # agent answered.
    if have timeout; then
      agent_out="$(timeout 5 ssh-add -l 2>/dev/null)"; agent_rc=$?
    else
      agent_out="$(ssh-add -l 2>/dev/null)"; agent_rc=$?
    fi
    case "$agent_rc" in
      0)
        agent_n="$(grep -c . <<<"$agent_out" || true)"
        if (( agent_n > 5 )); then
          warn "the agent offers $agent_n keys to every server" "many keys offered; servers stop at MaxAuthTries: IdentitiesOnly yes and one IdentityFile per host"
        else
          info "the agent holds $agent_n key(s)"
        fi
        ;;
      1) pass "the agent answers and holds no keys" ;;
      2) warn "SSH_AUTH_SOCK points at a dead agent" "unset SSH_AUTH_SOCK, or start one: eval \"\$(ssh-agent -s)\"" ;;
      *) skip "ssh-add -l exited $agent_rc" ;;
    esac
  fi
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

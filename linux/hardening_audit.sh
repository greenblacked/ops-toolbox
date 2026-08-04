#!/usr/bin/env bash
# hardening_audit.sh
# Read-only security audit of a Linux machine.
#
# Reports; never changes anything. There is no --apply and no --fix, and that
# is deliberate: every finding below has a context where the "insecure" answer
# is the correct one — a bastion with password auth behind a VPN, a container
# with no firewall because the host has one. A script that auto-hardened would
# be wrong often enough to be dangerous, so this one hands you the finding and
# the command, and you decide.
#
# Checks are grouped; use --only to run a subset and --list-groups to see them.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

ONLY=""
FAIL_ON="fail"
QUIET=0

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# A finding is one line: verdict, what was checked, and — when it is not a
# pass — what to do about it. The fix is printed rather than run.
pass() { PASS_COUNT=$((PASS_COUNT + 1)); (( QUIET )) || printf "  %s[pass]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }

usage() {
  cat <<EOF
hardening_audit.sh - read-only security audit of a Linux machine

Reports findings and the command that would fix each one. Changes nothing.

Usage:
  $(basename "$0") [--only GROUPS] [--fail-on warn|fail] [--quiet]

Options:
  --only GROUPS    Comma-separated subset (see --list-groups)
  --fail-on LEVEL  Exit 1 on 'fail' (default) or on 'warn' and above
  --quiet          Print only warnings and failures
  --list-groups    Print the group names and exit
  --help, -h       Show this help

Groups:
  ssh        sshd_config: root login, password auth, empty passwords
  accounts   UID 0 accounts, empty password hashes, sudo NOPASSWD
  network    listening sockets bound to all interfaces, firewall present
  files      world-writable files in /etc, permissions on key files
  updates    unattended upgrades configured, reboot pending

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

ALL_GROUPS="ssh accounts network files updates"

while (( $# > 0 )); do
  case "$1" in
    --only)      require_value "$1" "${2:-}"; shift; ONLY="$1" ;;
    --only=*)    ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --fail-on)   require_value "$1" "${2:-}"; shift; FAIL_ON="$1" ;;
    --fail-on=*) FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --quiet)     QUIET=1 ;;
    --list-groups) printf '%s\n' $ALL_GROUPS; exit 0 ;;
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

if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a requested <<< "$ONLY"
  for g in "${requested[@]}"; do
    case " $ALL_GROUPS " in
      *" $g "*) ;;
      *) err "unknown group: $g (see --list-groups)"; exit 3 ;;
    esac
  done
fi

# --help and --list-groups are handled above so they work anywhere; the checks
# themselves read Linux-specific paths.
if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

want() {
  [[ -z "$ONLY" ]] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# Effective sshd setting. Reads the merged config where sshd supports it, since
# a value in an Include'd file beats sshd_config and grepping the main file
# alone reports the wrong answer.
sshd_value() {
  local key="$1" out=""
  if command -v sshd >/dev/null 2>&1; then
    out="$(sshd -T 2>/dev/null | awk -v k="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" \
      'tolower($1) == k { print $2; exit }')"
  fi
  if [[ -z "$out" && -r /etc/ssh/sshd_config ]]; then
    out="$(grep -ivE '^\s*#' /etc/ssh/sshd_config 2>/dev/null \
      | awk -v k="$key" 'tolower($1) == tolower(k) { print $2; exit }')"
  fi
  printf '%s' "$out"
}

# --- ssh -------------------------------------------------------------------
if want ssh; then
  group "ssh"
  if [[ ! -r /etc/ssh/sshd_config ]] && ! command -v sshd >/dev/null 2>&1; then
    skip "no sshd on this machine"
  else
    v="$(sshd_value PermitRootLogin)"
    case "${v:-unset}" in
      no|forced-commands-only) pass "PermitRootLogin=$v" ;;
      unset) warn "PermitRootLogin not set; the default has changed between OpenSSH releases" \
                  "set it explicitly: PermitRootLogin no" ;;
      *) fail "PermitRootLogin=$v" "set 'PermitRootLogin no' in /etc/ssh/sshd_config, then: sshd -t && systemctl reload sshd" ;;
    esac

    v="$(sshd_value PasswordAuthentication)"
    case "${v:-unset}" in
      no) pass "PasswordAuthentication=no" ;;
      unset) warn "PasswordAuthentication not set explicitly" "set 'PasswordAuthentication no' once keys are working" ;;
      *) warn "PasswordAuthentication=$v" "keys only is safer: PasswordAuthentication no (confirm your key works first)" ;;
    esac

    v="$(sshd_value PermitEmptyPasswords)"
    case "${v:-no}" in
      no) pass "PermitEmptyPasswords=no" ;;
      *) fail "PermitEmptyPasswords=$v" "set 'PermitEmptyPasswords no' in /etc/ssh/sshd_config" ;;
    esac
  fi
fi

# --- accounts --------------------------------------------------------------
if want accounts; then
  group "accounts"
  if [[ -r /etc/passwd ]]; then
    uid0="$(awk -F: '$3 == 0 { print $1 }' /etc/passwd | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$uid0" == "root" ]]; then
      pass "root is the only UID 0 account"
    else
      fail "more than one UID 0 account: $uid0" "a second UID 0 account is a full root equivalent; remove it or change its uid"
    fi
  else
    skip "/etc/passwd unreadable"
  fi

  if [[ -r /etc/shadow ]]; then
    empty="$(awk -F: '$2 == "" { print $1 }' /etc/shadow | tr '\n' ' ' | sed 's/ $//')"
    if [[ -z "$empty" ]]; then
      pass "no accounts with an empty password hash"
    else
      fail "accounts with an empty password: $empty" "lock them: passwd -l <user>"
    fi
  else
    skip "/etc/shadow unreadable (needs root)"
  fi

  nopass=""
  for f in /etc/sudoers /etc/sudoers.d/*; do
    [[ -r "$f" ]] || continue
    if grep -qE '^[^#]*NOPASSWD' "$f" 2>/dev/null; then
      nopass="$nopass $f"
    fi
  done
  if [[ -z "$nopass" ]]; then
    pass "no NOPASSWD sudo rules"
  else
    warn "NOPASSWD sudo rules in:$nopass" "intentional for automation, worth confirming nothing else inherits it"
  fi
fi

# --- network ---------------------------------------------------------------
if want network; then
  group "network"
  if command -v ss >/dev/null 2>&1; then
    # ss is run on its own first so its exit status is visible. Folding it into
    # the pipeline below would turn a failed ss — -H is not in older iproute2 —
    # into empty output, and empty output reads as "nothing is listening": a
    # clean bill of health for a check that never ran.
    sockets="$(ss -tulnH 2>/dev/null)"; ss_rc=$?
    # Bound to all interfaces rather than loopback. Not wrong by itself; it is
    # the list worth knowing, because everything on it is reachable from
    # wherever this machine is routable.
    listening="$(printf '%s\n' "$sockets" | awk '$5 ~ /^(0\.0\.0\.0|\*|\[::\]):/ { print $1, $5 }' | sort -u)"
    if (( ss_rc != 0 )); then
      skip "ss failed (exit $ss_rc); listening sockets not checked"
    elif [[ -z "$listening" ]]; then
      pass "nothing listening on all interfaces"
    else
      count="$(printf '%s\n' "$listening" | grep -c .)"
      warn "$count socket(s) listening on all interfaces" "review: ss -tulnp"
      (( QUIET )) || printf '%s\n' "$listening" | sed 's/^/           /'
    fi
  else
    skip "ss not available"
  fi

  # Each probe captures its output and then matches, rather than piping into
  # `grep -q`. grep -q stops reading at its first match, the producer dies of
  # SIGPIPE, and under `set -o pipefail` the pipeline reports 141 — so a large
  # nftables ruleset would be read as "no firewall". A false all-clear is the
  # worst thing this script can print.
  fw="none"
  if command -v ufw >/dev/null 2>&1; then
    case "$(ufw status 2>/dev/null || true)" in *"Status: active"*) fw="ufw" ;; esac
  fi
  if [[ "$fw" == "none" ]] && command -v firewall-cmd >/dev/null 2>&1; then
    case "$(firewall-cmd --state 2>/dev/null || true)" in *running*) fw="firewalld" ;; esac
  fi
  if [[ "$fw" == "none" ]] && command -v nft >/dev/null 2>&1; then
    rules="$(nft list ruleset 2>/dev/null || true)"
    [[ -n "${rules//[[:space:]]/}" ]] && fw="nftables"
  fi
  if [[ "$fw" == "none" ]] && command -v iptables >/dev/null 2>&1; then
    rules="$(iptables -S 2>/dev/null || true)"
    # grep -c reads to EOF, so it has none of the early-exit problem above.
    non_default="$(printf '%s\n' "$rules" | grep -cvE '^(-P (INPUT|FORWARD|OUTPUT) ACCEPT)?$' || true)"
    [[ -n "$rules" ]] && [[ "${non_default:-0}" != "0" ]] && fw="iptables"
  fi
  if [[ "$fw" == "none" ]]; then
    # Reading rules needs root; without it this cannot tell "no firewall" from
    # "not allowed to look", and saying so beats implying the machine is bare.
    if [[ "$(id -u)" != "0" ]]; then
      skip "no firewall detected, but reading rules needs root — rerun with sudo"
    else
      warn "no active host firewall detected" "fine if the network filters for you; otherwise: ufw enable, or firewall-cmd --state"
    fi
  else
    pass "host firewall active ($fw)"
  fi
fi

# --- files -----------------------------------------------------------------
if want files; then
  group "files"
  if [[ -d /etc ]]; then
    # -maxdepth keeps this to about a second; a full-filesystem walk would make
    # the script one nobody runs.
    ww="$(find /etc -maxdepth 2 -type f -perm -0002 2>/dev/null | head -20)"
    if [[ -z "$ww" ]]; then
      pass "no world-writable files in /etc (depth 2)"
    else
      count="$(printf '%s\n' "$ww" | grep -c .)"
      fail "$count world-writable file(s) in /etc" "chmod o-w on each; anyone on the box can rewrite them"
      (( QUIET )) || printf '%s\n' "$ww" | sed 's/^/           /'
    fi
  fi

  for f in /etc/shadow /etc/gshadow; do
    [[ -e "$f" ]] || continue
    mode="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
    [[ -z "$mode" ]] && continue
    if [[ "$mode" =~ ^[0-6][04]0$ ]]; then
      pass "$f mode $mode"
    else
      fail "$f mode $mode" "expected owner-read plus at most group-read, and never executable: chmod 640 $f"
    fi
  done
fi

# --- updates ---------------------------------------------------------------
if want updates; then
  group "updates"
  if [[ -f /var/run/reboot-required ]]; then
    warn "a reboot is pending" "packages were updated but the running kernel or libraries are stale"
  elif command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r >/dev/null 2>&1; then
      pass "no reboot pending"
    else
      warn "a reboot is pending" "needs-restarting -r reports services or the kernel need a restart"
    fi
  else
    pass "no reboot marker present"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] &&
       grep -q '"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
      pass "unattended-upgrades configured"
    else
      warn "unattended security upgrades not configured" "apt-get install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1; then
      pass "dnf-automatic enabled"
    else
      warn "automatic updates not enabled" "dnf install dnf-automatic && systemctl enable --now dnf-automatic.timer"
    fi
  else
    skip "no apt or dnf; automatic updates not checked"
  fi
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

if (( SKIP_COUNT > 0 )) && [[ "$(id -u)" != "0" ]]; then
  info "some checks need root; rerun with sudo for the full picture"
fi

if [[ "$FAIL_ON" == "warn" ]] && (( WARN_COUNT + FAIL_COUNT > 0 )); then
  exit 1
fi
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0

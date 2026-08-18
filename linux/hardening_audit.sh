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

# The SSH checks read a real directory, which made them the one part of this
# audit no test could reach: the tester images do not install openssh-server,
# so the host-key grader was never executed by anything. It shipped a rule that
# failed every stock Fedora host, and then a rule that passed a host whose
# ssh_keys group had members — two opposite bugs, both in code the suite could
# not run. This is the same seam SYSCTL_D and PROC_SYS give sysctl_defaults.sh,
# and it is deliberately an environment variable rather than a flag: it exists
# for the suite, not for the command line.
ETC_SSH="${ETC_SSH:-/etc/ssh}"

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
  files      world-writable files in /etc, permissions on key files and SSH host keys
  updates    unattended upgrades configured and recently stamped, reboot pending
  kernel     ASLR, kernel pointer/log exposure, protected links, unprivileged BPF, LSM enforcing

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

ALL_GROUPS="ssh accounts network files updates kernel"

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

# Read one kernel tunable through procfs. That stays read-only, works without
# sysctl(8), and avoids a command whose output format differs between distros.
kernel_value() {
  local path="/proc/sys/${1//./\/}"
  [[ -r "$path" ]] || return 1
  tr -d '[:space:]' < "$path"
}

# Duplicated from system_doctor.sh on purpose (see CONTRIBUTING.md).
days_since() {
  local mtime now
  mtime="$(stat -c '%Y' "$1" 2>/dev/null || printf '')"
  [[ -z "$mtime" ]] && return 1
  now="$(date +%s)"
  printf '%d\n' $(( (now - mtime) / 86400 ))
}

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
  if [[ -z "$out" && -r "$ETC_SSH/sshd_config" ]]; then
    out="$(grep -ivE '^\s*#' "$ETC_SSH/sshd_config" 2>/dev/null \
      | awk -v k="$key" 'tolower($1) == tolower(k) { print $2; exit }')"
  fi
  printf '%s' "$out"
}

# --- ssh -------------------------------------------------------------------
if want ssh; then
  group "ssh"
  if [[ ! -r "$ETC_SSH/sshd_config" ]] && ! command -v sshd >/dev/null 2>&1; then
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

  # Private host keys, not the .pub files: the glob ends in _key. Group or
  # world access is a copy of the host identity; 600 (or 400) is the bar.
  host_keys=0
  for f in "$ETC_SSH"/ssh_host_*_key; do
    [[ -e "$f" && -f "$f" ]] || continue
    host_keys=$((host_keys + 1))
    mode="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
    if [[ -z "$mode" ]]; then
      skip "$f unreadable"
      continue
    fi
    # 600/400 is the bar on Debian and Arch. Fedora and RHEL ship these keys
    # 0640 root:ssh_keys on purpose — sshd drops privileges and reads them
    # through that group — so requiring ^[0-7]00$ graded a stock RHEL host as
    # FAIL and exited 1 on a machine that was configured correctly. CI never
    # caught it because no tester image installs openssh-server. Group *read*
    # is accepted only when the group owning the key is that distro group;
    # world access, and group write, stay a failure everywhere.
    key_group="$(stat -c '%G' "$f" 2>/dev/null || printf '')"
    # The exemption is for the *empty* ssh_keys group. On Fedora and RHEL that
    # group exists with no members: nothing gains read access by belonging to
    # it, which is what makes 0640 safe there. Trusting the name alone would
    # invert this check — add a user to ssh_keys, or create the group by hand
    # on Debian and chmod the keys 0640, and every member could read the host
    # identity while the check that exists to catch exactly that printed pass.
    # Fails closed: the exemption needs positive evidence that the group is
    # empty, so a host without getent — or one where the lookup fails — is
    # graded by the strict rule rather than given the benefit of the doubt.
    key_group_members=""
    key_group_known=0
    if [[ "$key_group" == "ssh_keys" ]] && command -v getent >/dev/null 2>&1; then
      if key_group_members="$(getent group ssh_keys 2>/dev/null | awk -F: '{print $4}')"; then
        key_group_known=1
      fi
    fi
    if [[ "$mode" =~ ^[0-7]00$ ]]; then
      pass "$f mode $mode"
    elif [[ "$mode" =~ ^[0-7]40$ && "$key_group" == "ssh_keys" \
            && "$key_group_known" == "1" && -z "$key_group_members" ]]; then
      pass "$f mode $mode (group $key_group, empty — the Fedora/RHEL convention)"
    elif [[ "$mode" =~ ^[0-7]40$ && "$key_group" == "ssh_keys" ]]; then
      fail "$f mode $mode" \
        "group ssh_keys has members ($key_group_members) who can read this host key: chmod 600 $f"
    elif [[ "$mode" =~ ^[0-7][0-7]0$ ]]; then
      # Group access with no world access: the objection is that the group can
      # read the host identity, not that anything is writable. Say that, rather
      # than naming bits this file does not set.
      fail "$f mode $mode" \
        "group $key_group can read this host private key: chmod 600 $f"
    else
      fail "$f mode $mode" \
        "this host private key is world-accessible: chmod 600 $f"
    fi
  done
  if (( host_keys == 0 )); then
    skip "no SSH host private keys in $ETC_SSH"
  fi
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
      # Configured and never running is the interesting case: the package is
      # installed, the apt conf says yes, and nothing has actually applied a
      # security update. The stamp is what apt periodic leaves behind.
      stamp=""
      for p in /var/lib/apt/periodic/unattended-upgrades-stamp \
               /var/lib/unattended-upgrades/unattended-upgrades-stamp; do
        [[ -e "$p" ]] && { stamp="$p"; break; }
      done
      if [[ -z "$stamp" ]]; then
        warn "unattended-upgrades is configured but has never left a stamp" \
             "check: systemctl status unattended-upgrades.service"
      elif age="$(days_since "$stamp")"; then
        if (( age > 14 )); then
          warn "unattended-upgrades last ran ${age}d ago" "journalctl -u unattended-upgrades"
        else
          pass "unattended-upgrades stamp is ${age}d old"
        fi
      else
        skip "unattended-upgrades stamp unreadable"
      fi
    else
      warn "unattended security upgrades not configured" "apt-get install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1; then
      pass "dnf-automatic enabled"
      stamp="/var/lib/systemd/timers/stamp-dnf-automatic.timer"
      if [[ -e "$stamp" ]]; then
        if age="$(days_since "$stamp")"; then
          if (( age > 14 )); then
            warn "dnf-automatic last triggered ${age}d ago" "systemctl status dnf-automatic.timer"
          else
            pass "dnf-automatic stamp is ${age}d old"
          fi
        else
          skip "dnf-automatic stamp unreadable"
        fi
      else
        warn "dnf-automatic is enabled but has never left a timer stamp" \
             "systemctl start dnf-automatic.timer"
      fi
    else
      warn "automatic updates not enabled" "dnf install dnf-automatic && systemctl enable --now dnf-automatic.timer"
    fi
  else
    skip "no apt or dnf; automatic updates not checked"
  fi
fi

# --- kernel ----------------------------------------------------------------
if want kernel; then
  group "kernel"

  v="$(kernel_value kernel.randomize_va_space 2>/dev/null || true)"
  case "$v" in
    2) pass "full address-space randomisation enabled" ;;
    1) warn "kernel.randomize_va_space=1 (partial ASLR)" "prefer full randomisation: sysctl -w kernel.randomize_va_space=2" ;;
    0) fail "kernel.randomize_va_space=0 (ASLR disabled)" "enable it: sysctl -w kernel.randomize_va_space=2" ;;
    *) skip "kernel.randomize_va_space unavailable" ;;
  esac

  v="$(kernel_value kernel.kptr_restrict 2>/dev/null || true)"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    if (( v >= 1 )); then pass "kernel pointers restricted (kptr_restrict=$v)"
    else warn "kernel pointers are exposed (kptr_restrict=0)" "restrict them: sysctl -w kernel.kptr_restrict=1"; fi
  else
    skip "kernel.kptr_restrict unavailable"
  fi

  v="$(kernel_value kernel.dmesg_restrict 2>/dev/null || true)"
  case "$v" in
    1) pass "unprivileged kernel log access restricted" ;;
    0) warn "unprivileged users can read the kernel log" "restrict it: sysctl -w kernel.dmesg_restrict=1" ;;
    *) skip "kernel.dmesg_restrict unavailable" ;;
  esac

  for setting in fs.protected_hardlinks fs.protected_symlinks; do
    v="$(kernel_value "$setting" 2>/dev/null || true)"
    case "$v" in
      1) pass "$setting=1" ;;
      0) fail "$setting=0" "protect shared directories: sysctl -w $setting=1" ;;
      *) skip "$setting unavailable" ;;
    esac
  done

  v="$(kernel_value kernel.unprivileged_bpf_disabled 2>/dev/null || true)"
  case "$v" in
    1|2) pass "unprivileged BPF disabled (value $v)" ;;
    0) warn "unprivileged BPF is enabled" "unless developers need it: sysctl -w kernel.unprivileged_bpf_disabled=1" ;;
    *) skip "kernel.unprivileged_bpf_disabled unavailable" ;;
  esac

  if [[ -r /sys/kernel/security/lsm ]]; then
    lsm="$(tr -d '[:space:]' < /sys/kernel/security/lsm)"
    lsm_aa=0
    lsm_se=0
    case ",$lsm," in *,apparmor,*) lsm_aa=1 ;; esac
    case ",$lsm," in *,selinux,*)  lsm_se=1 ;; esac
    if (( lsm_aa == 0 && lsm_se == 0 )); then
      warn "no AppArmor or SELinux in active LSM list ($lsm)" "confirm host or workload isolation supplies the intended policy"
    fi
    # Present is not enforcing. A host with AppArmor loaded and every profile
    # in complain mode, or SELinux in permissive, looks locked down in the LSM
    # list and is not.
    if (( lsm_aa == 1 )); then
      profiles="/sys/kernel/security/apparmor/profiles"
      if [[ -r "$profiles" ]]; then
        aa_n="$(grep -c '(enforce)' "$profiles" 2>/dev/null || true)"
        [[ "$aa_n" =~ ^[0-9]+$ ]] || aa_n=0
        if (( aa_n > 0 )); then
          pass "AppArmor has $aa_n profile(s) in enforce mode"
        else
          warn "AppArmor is loaded but no profiles are in enforce mode" \
               "aa-enforce <profile>, or check: cat /sys/kernel/security/apparmor/profiles"
        fi
      else
        skip "AppArmor profiles unreadable"
      fi
    fi
    if (( lsm_se == 1 )); then
      if [[ -r /sys/fs/selinux/enforce ]]; then
        se="$(tr -d '[:space:]' < /sys/fs/selinux/enforce)"
        case "$se" in
          1) pass "SELinux is enforcing" ;;
          0) warn "SELinux is permissive" "setenforce 1, and persist SELINUX=enforcing in /etc/selinux/config" ;;
          *) skip "SELinux enforce node unreadable ($se)" ;;
        esac
      else
        skip "SELinux enforce node unreadable"
      fi
    fi
  else
    skip "active Linux security modules not readable"
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

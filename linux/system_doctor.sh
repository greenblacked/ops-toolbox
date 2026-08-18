#!/usr/bin/env bash
# system_doctor.sh
# Read-only health report for a Linux machine after bootstrap.
#
# The counterpart of macos-initial-setup/workstation_doctor.sh, and the other
# half of a pair with hardening_audit.sh in this directory. The two look at
# some of the same things and answer different questions, so keep them apart:
# the audit grades security posture and prints the command that fixes each
# finding; this one describes the state of the machine — free space, a pending
# reboot, whether sshd is here at all, which firewall is in charge, who owns
# the packages, containers, failed units, load. "No firewall" is a finding
# there and a fact here.
#
# It changes nothing, and there is deliberately no exit code for a bad report:
# a full disk and a failed unit are things to read, not gates. Use
# `hardening_audit.sh --fail-on warn` when you want something that fails a
# pipeline.
#
# Exit codes:
#   0   the report ran (warnings do not change the exit code)
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
set -u
set -o pipefail

QUIET=0
SKIP_CONTAINERS=0
SKIP_UNITS=0
MIN_FREE_PCT=10
MIN_MEMORY_PCT=10

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

OK_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

# One line per observation: verdict, what was looked at, and — when it is not
# healthy — the command that shows you more. --quiet keeps only the lines worth
# waking up for.
ok()   { OK_COUNT=$((OK_COUNT + 1)); (( QUIET )) || printf "  %s[ ok ]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
info() { (( QUIET )) || printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"
  return 0
}
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
system_doctor.sh - read-only health report for a Linux machine

Describes the state of the machine and changes nothing. For security findings
and the command that fixes each one, use hardening_audit.sh instead.

Usage:
  $(basename "$0") [--min-free PCT] [--min-memory PCT]
                  [--skip-containers] [--skip-units] [--quiet]

Options:
  --min-free PCT     Warn below this much free space on / (default: $MIN_FREE_PCT)
  --min-memory PCT   Warn below this much available memory (default: $MIN_MEMORY_PCT)
  --skip-containers  Don't probe docker/podman (slow when a daemon is wedged)
  --skip-units       Don't run 'systemctl --failed'
  --quiet            Print only warnings
  --help, -h         Show this help

Sections: system, sessions, time, packages, disk, memory, updates, services, journal, network, containers, load

Exit codes: 0 report printed, 2 not Linux, 3 usage
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
    --min-free)        require_value "$1" "${2:-}"; shift; MIN_FREE_PCT="$1" ;;
    --min-free=*)      MIN_FREE_PCT="${1#*=}"; require_value "--min-free" "$MIN_FREE_PCT" ;;
    --min-memory)      require_value "$1" "${2:-}"; shift; MIN_MEMORY_PCT="$1" ;;
    --min-memory=*)    MIN_MEMORY_PCT="${1#*=}"; require_value "--min-memory" "$MIN_MEMORY_PCT" ;;
    --skip-containers) SKIP_CONTAINERS=1 ;;
    --skip-units)      SKIP_UNITS=1 ;;
    --quiet)           QUIET=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$MIN_FREE_PCT" =~ ^[0-9]+$ ]] || (( MIN_FREE_PCT > 100 )); then
  err "--min-free must be a percentage between 0 and 100, got: $MIN_FREE_PCT"
  exit 3
fi
if ! [[ "$MIN_MEMORY_PCT" =~ ^[0-9]+$ ]] || (( MIN_MEMORY_PCT > 100 )); then
  err "--min-memory must be a percentage between 0 and 100, got: $MIN_MEMORY_PCT"
  exit 3
fi

# --help is handled above so it works anywhere; everything past this point
# reads Linux-specific paths.
if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Duplicated in each linux/ script on purpose (see CONTRIBUTING.md). OS_RELEASE
# is honoured so the unknown-distro path can actually be tested.
detect_pkg_mgr() {
  local os_release="${OS_RELEASE:-/etc/os-release}"
  local id="" id_like=""
  if [[ -r "$os_release" ]]; then
    id="$(sed -n 's/^ID=//p' "$os_release" | tr -d '"' | head -n 1)"
    id_like="$(sed -n 's/^ID_LIKE=//p' "$os_release" | tr -d '"' | head -n 1)"
  fi
  case " $id $id_like " in
    *" debian "*|*" ubuntu "*)             printf 'apt\n' ;;
    *" fedora "*|*" rhel "*|*" centos "*)  printf 'dnf\n' ;;
    *" arch "*|*" archlinux "*)            printf 'pacman\n' ;;
    *) printf 'unsupported:%s\n' "${id:-unknown}" ;;
  esac
}

human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1099511627776) printf "%.1fT", b / 1099511627776;
    else if (b >= 1073741824) printf "%.1fG", b / 1073741824;
    else if (b >= 1048576) printf "%.0fM", b / 1048576;
    else printf "%dK", b / 1024
  }'
}

days_since() {
  local mtime now
  mtime="$(stat -c '%Y' "$1" 2>/dev/null || printf '')"
  [[ -z "$mtime" ]] && return 1
  now="$(date +%s)"
  printf '%d\n' $(( (now - mtime) / 86400 ))
}

# --- system ----------------------------------------------------------------
group "system"
OS_RELEASE_FILE="${OS_RELEASE:-/etc/os-release}"
pretty=""
[[ -r "$OS_RELEASE_FILE" ]] && pretty="$(sed -n 's/^PRETTY_NAME=//p' "$OS_RELEASE_FILE" | tr -d '"' | head -n 1)"
info "${pretty:-unknown distribution} · kernel $(uname -r) · $(uname -m)"
info "host $(uname -n)"

if [[ -r /proc/uptime ]]; then
  up_s="$(awk '{ printf "%d", $1 }' /proc/uptime)"
  info "up $(( up_s / 86400 ))d $(( (up_s % 86400) / 3600 ))h $(( (up_s % 3600) / 60 ))m"
fi

if have systemd-detect-virt; then
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  [[ -n "$virt" && "$virt" != "none" ]] && info "running under $virt"
fi

# Non-zero is a bitmask of "this kernel is not stock": proprietary modules,
# forced loads, unsigned modules, live patches. The number is enough to
# notice; decoding bits is `cat /proc/sys/kernel/tainted`.
if [[ -r /proc/sys/kernel/tainted ]]; then
  taint="$(tr -d '[:space:]' < /proc/sys/kernel/tainted)"
  if [[ "$taint" =~ ^[0-9]+$ ]]; then
    if (( taint == 0 )); then
      ok "kernel is not tainted"
    else
      warn "kernel is tainted ($taint)" "decode: cat /proc/sys/kernel/tainted"
    fi
  else
    skip "kernel taint value unreadable"
  fi
fi

# --- sessions --------------------------------------------------------------
# The first question on a box someone just handed you: who is here.
group "sessions"
session_lines=""
if have loginctl; then
  session_lines="$(loginctl list-sessions --no-legend --no-pager 2>/dev/null || true)"
fi
if [[ -z "$session_lines" ]] && have who; then
  session_lines="$(who 2>/dev/null || true)"
fi
if [[ -n "$session_lines" ]]; then
  n_sess="$(printf '%s\n' "$session_lines" | grep -c . || true)"
  info "$n_sess login session(s)"
  printf '%s\n' "$session_lines" | head -n 10 | sed 's/^/           /'
else
  info "no login sessions"
fi

# --- time ------------------------------------------------------------------
# Clock skew is the outage that looks like everything else: TLS handshakes
# fail, logs jump, Kerberos stops. timedatectl is the one command; without
# it we still print the timezone from /etc so the report is not empty.
group "time"
tz=""
if have timedatectl; then
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  ntp="$(timedatectl show -p NTP --value 2>/dev/null || true)"
  synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ -n "$tz" ]]; then
    info "timezone $tz"
  fi
  case "$synced" in
    yes)
      ok "clock is NTP-synchronised"
      ;;
    no)
      if [[ "$ntp" == "yes" ]]; then
        warn "NTP is on but the clock is not synchronised yet" "timedatectl status"
      else
        warn "clock is not NTP-synchronised" "timedatectl set-ntp true  # or enable chrony / ntpd"
      fi
      ;;
    *)
      if [[ -z "$tz" && -z "$ntp" ]]; then
        skip "timedatectl did not answer (no systemd bus?)"
      else
        info "NTP=${ntp:-unknown} NTPSynchronized=${synced:-unknown}"
      fi
      ;;
  esac
else
  [[ -r /etc/timezone ]] && tz="$(tr -d '[:space:]' < /etc/timezone)"
  [[ -n "$tz" ]] && info "timezone $tz (/etc/timezone)"
  found_ntp=0
  for ntpd in chronyd ntpd ntpsec systemd-timesyncd; do
    if have "$ntpd"; then
      info "NTP client present: $ntpd (timedatectl not installed, not checking sync)"
      found_ntp=1
      break
    fi
  done
  (( found_ntp )) || skip "no timedatectl and no NTP client in PATH"
fi

# --- packages --------------------------------------------------------------
group "packages"
PKG_MGR="$(detect_pkg_mgr)"
case "$PKG_MGR" in
  unsupported:*)
    # A distribution this repository does not manage is exit 2 in the scripts
    # that install things, because they would have nothing to run. A report has
    # plenty left to say, so it says this and carries on.
    skip "no known package manager for '${PKG_MGR#unsupported:}' (apt, dnf and pacman are recognised)"
    PKG_MGR=""
    ;;
  *)
    ok "package manager: $PKG_MGR"
    ;;
esac

# Age of the local package index, which needs no network to answer. A machine
# whose index is months old reports itself up to date and is not.
index_path=""
case "$PKG_MGR" in
  apt)
    for p in /var/lib/apt/periodic/update-success-stamp /var/cache/apt/pkgcache.bin /var/lib/apt/lists; do
      [[ -e "$p" ]] && { index_path="$p"; break; }
    done
    ;;
  dnf)    [[ -d /var/cache/dnf ]] && index_path=/var/cache/dnf ;;
  pacman) [[ -d /var/lib/pacman/sync ]] && index_path=/var/lib/pacman/sync ;;
esac
if [[ -n "$index_path" ]]; then
  if age="$(days_since "$index_path")"; then
    if (( age > 14 )); then
      warn "package index last refreshed ${age}d ago" "refresh it before trusting an upgrade check: stay_fresh.sh --dry-run"
    else
      ok "package index refreshed ${age}d ago"
    fi
  fi
elif [[ -n "$PKG_MGR" ]]; then
  skip "no package index to date-check for $PKG_MGR"
fi

# Pending upgrades from the local index, no network. The count is a fact,
# not a finding: a machine with fifty updates and a fresh index is well,
# it just has not been upgraded yet. stay_fresh.sh is the thing that does.
pending=""
pending_rc=0
case "$PKG_MGR" in
  apt)
    pending="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)"
    ;;
  dnf)
    pending_out="$(dnf check-update --quiet --cacheonly 2>/dev/null)"
    pending_rc=$?
    # dnf: 0 none, 100 updates available, anything else is an error.
    if (( pending_rc == 0 )); then
      pending=0
    elif (( pending_rc == 100 )); then
      pending="$(printf '%s\n' "$pending_out" | grep -cE '^[^[:space:]]' || true)"
    else
      pending=""
    fi
    ;;
  pacman)
    pending="$(pacman -Qu 2>/dev/null | grep -c . || true)"
    ;;
esac
if [[ "$pending" =~ ^[0-9]+$ ]]; then
  if (( pending == 0 )); then
    ok "no pending upgrades"
  else
    info "$pending pending upgrade(s)" "preview: stay_fresh.sh --dry-run"
  fi
elif [[ -n "$PKG_MGR" ]]; then
  skip "could not count pending upgrades for $PKG_MGR"
fi

# --- disk ------------------------------------------------------------------
group "disk"
root_line="$(df -Pk / 2>/dev/null | awk 'NR == 2')"
if [[ -n "$root_line" ]]; then
  used_pct="$(printf '%s\n' "$root_line" | awk '{ gsub(/%/, "", $5); print $5 }')"
  free_b="$(printf '%s\n' "$root_line" | awk '{ printf "%.0f", $4 * 1024 }')"
  free_pct=$(( 100 - used_pct ))
  if (( free_pct < MIN_FREE_PCT )); then
    warn "/ is ${used_pct}% full ($(human_bytes "$free_b") free)" "find the weight: du -xh / --max-depth=2 2>/dev/null | sort -h | tail -20"
  else
    ok "/ is ${used_pct}% full ($(human_bytes "$free_b") free)"
  fi
else
  skip "df could not read /"
fi

# A filesystem out of inodes looks exactly like a healthy one in df -h, which
# is why that outage takes so long to diagnose the first time.
inode_pct="$(df -Pi / 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
if [[ -n "$inode_pct" && "$inode_pct" =~ ^[0-9]+$ ]]; then
  if (( inode_pct >= 90 )); then
    warn "/ has used ${inode_pct}% of its inodes" "space can be free while creating a file still fails: df -i"
  else
    ok "/ has used ${inode_pct}% of its inodes"
  fi
fi

# Other real filesystems, so a full /var or /home is not invisible behind a
# healthy /. Only block devices: tmpfs and overlay churn by design.
others="$(df -Pk 2>/dev/null | awk -v min="$MIN_FREE_PCT" '
  NR > 1 && $1 ~ /^\/dev\// && $6 != "/" {
    gsub(/%/, "", $5)
    if (100 - $5 < min) printf "%s %s%% full\n", $6, $5
  }' | sort -u)"
# Fed by a here-string rather than a pipe: a piped loop runs in a subshell and
# the warning counter it increments would be discarded with it.
if [[ -n "$others" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    warn "$line" "df -h names the rest"
  done <<< "$others"
fi

# Crash dumps eat disk and mean something died. Count only; deletion is
# disk_cleanup.sh --include-coredumps, behind the same opt-in as trash.
coredump_n=0
coredump_seen=0
for d in /var/lib/systemd/coredump /var/crash; do
  [[ -d "$d" ]] || continue
  coredump_seen=1
  while IFS= read -r -d '' _; do
    coredump_n=$((coredump_n + 1))
  done < <(find "$d" -xdev -type f -print0 2>/dev/null)
done
if (( coredump_seen == 0 )); then
  skip "no coredump directories"
elif (( coredump_n == 0 )); then
  ok "no coredump files"
else
  warn "$coredump_n coredump file(s)" "preview: disk_cleanup.sh --dry-run --include-coredumps"
fi

# --- memory ----------------------------------------------------------------
group "memory"
if [[ -r /proc/meminfo ]]; then
  mem_total_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
  mem_available_kb="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)"
  # MemAvailable was added in Linux 3.14. The fallback is intentionally an
  # approximation, but still more useful on an old kernel than reporting no
  # memory state at all.
  if [[ -z "$mem_available_kb" ]]; then
    mem_available_kb="$(awk '
      /^MemFree:/ { free=$2 }
      /^Buffers:/ { buffers=$2 }
      /^Cached:/ { cached=$2 }
      END { print free + buffers + cached }
    ' /proc/meminfo)"
  fi
  if [[ "$mem_total_kb" =~ ^[0-9]+$ && "$mem_available_kb" =~ ^[0-9]+$ ]] &&
     (( mem_total_kb > 0 )); then
    mem_available_pct=$(( mem_available_kb * 100 / mem_total_kb ))
    mem_summary="$(human_bytes "$((mem_available_kb * 1024))") available of $(human_bytes "$((mem_total_kb * 1024))") (${mem_available_pct}%)"
    if (( mem_available_pct < MIN_MEMORY_PCT )); then
      warn "memory: $mem_summary" "inspect pressure and consumers: free -h; ps aux --sort=-%mem | head"
    else
      ok "memory: $mem_summary"
    fi
  else
    skip "/proc/meminfo did not contain usable totals"
  fi

  swap_total_kb="$(awk '/^SwapTotal:/ { print $2; exit }' /proc/meminfo)"
  swap_free_kb="$(awk '/^SwapFree:/ { print $2; exit }' /proc/meminfo)"
  if [[ "$swap_total_kb" =~ ^[0-9]+$ && "$swap_free_kb" =~ ^[0-9]+$ ]]; then
    if (( swap_total_kb == 0 )); then
      info "swap is not configured"
    else
      swap_used_kb=$(( swap_total_kb - swap_free_kb ))
      swap_used_pct=$(( swap_used_kb * 100 / swap_total_kb ))
      if (( swap_used_pct >= 75 )); then
        warn "swap is ${swap_used_pct}% used ($(human_bytes "$((swap_used_kb * 1024))"))" "sustained swap use can explain latency: vmstat 1"
      else
        ok "swap is ${swap_used_pct}% used ($(human_bytes "$((swap_used_kb * 1024))"))"
      fi
    fi
  fi

  # oom_kill in vmstat is since this boot. journal -p err often misses it
  # because the killer logs at warning.
  if [[ -r /proc/vmstat ]]; then
    oom_n="$(awk '/^oom_kill / { print $2; exit }' /proc/vmstat)"
    if [[ "$oom_n" =~ ^[0-9]+$ ]]; then
      if (( oom_n == 0 )); then
        ok "no OOM kills this boot"
      else
        warn "$oom_n OOM kill(s) this boot" "journalctl -k -b -g oom"
      fi
    else
      skip "oom_kill not in /proc/vmstat"
    fi
  fi
else
  skip "/proc/meminfo unreadable"
fi

# --- updates ---------------------------------------------------------------
group "updates"
if [[ -f /var/run/reboot-required || -f /run/reboot-required ]]; then
  pkgs=""
  for f in /var/run/reboot-required.pkgs /run/reboot-required.pkgs; do
    [[ -r "$f" ]] && pkgs="$(tr '\n' ' ' < "$f" | sed 's/ $//')" && break
  done
  warn "a reboot is pending${pkgs:+ (${pkgs})}" "the running kernel and libraries are older than the installed ones"
elif have needs-restarting; then
  if needs-restarting -r >/dev/null 2>&1; then
    ok "no reboot pending"
  else
    warn "a reboot is pending" "needs-restarting -r says the kernel or a service wants a restart"
  fi
else
  ok "no reboot marker present"
fi

# --- services --------------------------------------------------------------
group "services"
if have sshd || [[ -x /usr/sbin/sshd ]] || [[ -r /etc/ssh/sshd_config ]]; then
  ssh_state=""
  if have systemctl; then
    for unit in sshd ssh; do
      state="$(systemctl is-active "$unit" 2>/dev/null || true)"
      case "$state" in
        active)   ssh_state="running ($unit)"; break ;;
        inactive|failed) ssh_state="$state ($unit)" ;;
      esac
    done
  fi
  if [[ -z "$ssh_state" ]] && have pgrep && pgrep -x sshd >/dev/null 2>&1; then
    ssh_state="running"
  fi
  case "$ssh_state" in
    running*) ok "sshd installed and $ssh_state" ;;
    "")       info "sshd installed; could not determine whether it is running" ;;
    *)        info "sshd installed but $ssh_state" ;;
  esac
  info "its configuration is graded by hardening_audit.sh --only ssh"
else
  skip "no sshd on this machine"
fi

if [[ -d /run/systemd/system ]]; then
  if (( SKIP_UNITS )); then
    skip "systemctl --failed (--skip-units)"
  else
    # systemctl is run on its own so its exit status stays visible: folded into
    # a pipeline, a systemctl that refused to answer produces empty output, and
    # empty output here reads as "nothing is failing".
    units="$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null)"; sc_rc=$?
    if (( sc_rc != 0 )); then
      skip "systemctl --failed exited $sc_rc; units not checked"
    else
      names="$(printf '%s\n' "$units" | awk 'NF { print $1 }')"
      count="$(printf '%s\n' "$names" | grep -c . || true)"
      if (( count == 0 )); then
        ok "no failed systemd units"
      else
        warn "$count failed systemd unit(s)" "systemctl status <unit> · journalctl -u <unit> -b"
        printf '%s\n' "$names" | sed 's/^/           /'
      fi
    fi
  fi
else
  skip "no systemd on this machine"
fi

# Processes still running libraries that an upgrade replaced. Reboot-pending
# is the kernel; this is sshd holding a replaced libc. Root sees more.
if have needs-restarting; then
  stale="$(needs-restarting 2>/dev/null || true)"
  stale_n="$(printf '%s\n' "$stale" | grep -c . || true)"
  if (( stale_n == 0 )); then
    ok "no processes listed as needing a restart"
  else
    warn "$stale_n process(es) still running old libraries" "needs-restarting  # or reboot"
    printf '%s\n' "$stale" | head -n 10 | sed 's/^/           /'
  fi
elif have needrestart; then
  stale="$(needrestart -b -r l 2>/dev/null || true)"
  stale_n="$(printf '%s\n' "$stale" | grep -c '^NEEDRESTART-SVC:' || true)"
  if (( stale_n == 0 )); then
    ok "needrestart reports no stale services"
  else
    warn "$stale_n service(s) still running old libraries" "needrestart"
    printf '%s\n' "$stale" | grep '^NEEDRESTART-SVC:' | head -n 10 | sed 's/^/           /'
  fi
else
  skip "needrestart/needs-restarting not installed"
fi

# --- journal ---------------------------------------------------------------
# Error-level lines since boot are the "what broke" question after failed
# units. Capped so a chatty kernel cannot drown the rest of the report.
group "journal"
if have journalctl && [[ -d /run/log/journal || -d /var/log/journal || -d /run/systemd/journal ]]; then
  journal_out="$(journalctl -p err -b --no-pager -n 21 -o short-unix 2>/dev/null || true)"
  journal_n="$(printf '%s\n' "$journal_out" | grep -c . || true)"
  if (( journal_n == 0 )); then
    ok "no error-level journal entries this boot"
  else
    extra=""
    if (( journal_n > 20 )); then
      extra="; first 20 shown"
    fi
    warn "$journal_n error-level journal line(s) this boot${extra}" "journalctl -p err -b"
    printf '%s\n' "$journal_out" | head -n 20 | sed 's/^/           /'
  fi
else
  skip "no journald to read"
fi

# --- network ---------------------------------------------------------------
group "network"
# Each probe captures its output and then matches, rather than piping into
# `grep -q`: grep -q stops at the first match, the producer dies of SIGPIPE and
# under `set -o pipefail` the pipeline reports 141, so a large ruleset would be
# read as "no firewall". Same reasoning as hardening_audit.sh.
fw="none"
if have ufw; then
  case "$(ufw status 2>/dev/null || true)" in *"Status: active"*) fw="ufw" ;; esac
fi
if [[ "$fw" == "none" ]] && have firewall-cmd; then
  case "$(firewall-cmd --state 2>/dev/null || true)" in *running*) fw="firewalld" ;; esac
fi
if [[ "$fw" == "none" ]] && have nft; then
  rules="$(nft list ruleset 2>/dev/null || true)"
  [[ -n "${rules//[[:space:]]/}" ]] && fw="nftables"
fi
if [[ "$fw" == "none" ]] && have iptables; then
  rules="$(iptables -S 2>/dev/null || true)"
  non_default="$(printf '%s\n' "$rules" | grep -cvE '^(-P (INPUT|FORWARD|OUTPUT) ACCEPT)?$' || true)"
  [[ -n "$rules" ]] && [[ "${non_default:-0}" != "0" ]] && fw="iptables"
fi
if [[ "$fw" == "none" ]]; then
  if [[ "$(id -u)" != "0" ]]; then
    skip "no firewall detected, but reading rules needs root — rerun with sudo"
  else
    info "no host firewall in charge (hardening_audit.sh --only network grades this)"
  fi
else
  ok "host firewall: $fw"
fi

if have ip; then
  addrs="$(ip -o -4 addr show scope global 2>/dev/null | awk '{ printf "%s %s\n", $2, $4 }')"
  if [[ -n "$addrs" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      info "$line"
    done <<< "$addrs"
  else
    info "no global IPv4 address"
  fi
  addrs6="$(ip -o -6 addr show scope global 2>/dev/null | awk '{ printf "%s %s\n", $2, $4 }')"
  if [[ -n "$addrs6" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      info "$line"
    done <<< "$addrs6"
  else
    info "no global IPv6 address"
  fi
fi

# --- containers ------------------------------------------------------------
group "containers"
if (( SKIP_CONTAINERS )); then
  skip "docker/podman (--skip-containers)"
else
  found=0
  for engine in docker podman; do
    have "$engine" || continue
    found=1
    if "$engine" info >/dev/null 2>&1; then
      running="$("$engine" ps -q 2>/dev/null | grep -c . || true)"
      total="$("$engine" ps -aq 2>/dev/null | grep -c . || true)"
      images="$("$engine" images -q 2>/dev/null | grep -c . || true)"
      ok "$engine: ${running:-0} running of ${total:-0} container(s), ${images:-0} image(s)"
      # Disk usage only, never prune. Volumes are listed so you can see them;
      # stay_fresh.sh and disk_cleanup.sh refuse to delete them.
      df_out="$("$engine" system df 2>/dev/null || true)"
      if [[ -n "$df_out" ]]; then
        while IFS= read -r df_line; do
          [[ -n "$df_line" ]] || continue
          case "$df_line" in
            TYPE*) continue ;;
          esac
          info "$engine df: $df_line"
        done <<< "$df_out"
      fi
    else
      # Installed and unreachable is the interesting case: either the daemon is
      # down or this user is not in the group, and both look like "no docker".
      warn "$engine is installed but not reachable" "systemctl status $engine · or your user may not be in the '$engine' group"
    fi
  done
  (( found )) || skip "neither docker nor podman is installed"
fi

# --- load ------------------------------------------------------------------
group "load"
if [[ -r /proc/loadavg ]]; then
  read -r load1 load5 load15 _ < /proc/loadavg
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  [[ "$cores" =~ ^[0-9]+$ ]] || cores=1
  (( cores > 0 )) || cores=1
  verdict="$(awk -v l="$load1" -v c="$cores" 'BEGIN { print (l / c >= 1) ? "warn" : "ok" }')"
  summary="load $load1 $load5 $load15 over $cores core(s)"
  if [[ "$verdict" == "warn" ]]; then
    warn "$summary" "the one-minute average is at or above one job per core: top -o %CPU"
  else
    ok "$summary"
  fi
else
  skip "/proc/loadavg unreadable"
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s ok%s  %s%s warn%s  %s%s skip%s\n" \
  "$C_GREEN" "$OK_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

if (( SKIP_COUNT > 0 )) && [[ "$(id -u)" != "0" ]]; then
  info "some probes need root; rerun with sudo for the full picture"
fi
info "security posture is a separate report: ./hardening_audit.sh"
exit 0

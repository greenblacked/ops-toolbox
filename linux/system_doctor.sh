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
SKIP_REMOTE_MOUNTS=0
SKIP_SMART=0
MIN_FREE_PCT=10
MIN_MEMORY_PCT=10
MAX_PSI=10

# The storage and pressure sections read procfs (mounts, md status, PSI,
# file handles, conntrack, thread limits) and the expected mounts from fstab.
# Both are environment variables rather than flags, like OS_RELEASE below: they
# exist so the suite can hand the parsers a read-only remount, a degraded
# array or a stalled memory controller, which no container can produce.
PROC_DIR="${PROC_DIR:-/proc}"
FSTAB="${FSTAB:-/etc/fstab}"

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
#
# info takes the same optional second line as warn below, dimmed and indented
# under the first. It used to render only $1, so the one observation that hands
# you a next command without being a finding — the pending-upgrade count, which
# is a fact about the machine rather than something wrong with it — passed
# "preview: stay_fresh.sh --dry-run" as a second argument that went nowhere.
ok()   { OK_COUNT=$((OK_COUNT + 1)); (( QUIET )) || printf "  %s[ ok ]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
info() {
  (( QUIET )) && return 0
  printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"
  return 0
}
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
  $(basename "$0") [--min-free PCT] [--min-memory PCT] [--max-psi PCT]
                  [--skip-containers] [--skip-units]
                  [--skip-remote-mounts] [--skip-smart] [--quiet]

Options:
  --min-free PCT     Warn below this much free space on / (default: $MIN_FREE_PCT)
  --min-memory PCT   Warn below this much available memory (default: $MIN_MEMORY_PCT)
  --max-psi PCT      Warn when 60-second stall time exceeds this percent (default: $MAX_PSI)
  --skip-containers  Don't probe docker/podman (slow when a daemon is wedged)
  --skip-units       Don't run 'systemctl --failed'
  --skip-remote-mounts  Don't probe NFS/CIFS/sshfs mounts (each probe waits up to 5s)
  --skip-smart       Don't query disk health with smartctl
  --quiet            Print only warnings
  --help, -h         Show this help

Sections: system, sessions, time, packages, disk, storage, memory, updates, services, journal, network, containers, load, pressure

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
    --max-psi)         require_value "$1" "${2:-}"; shift; MAX_PSI="$1" ;;
    --max-psi=*)       MAX_PSI="${1#*=}"; require_value "--max-psi" "$MAX_PSI" ;;
    --skip-containers) SKIP_CONTAINERS=1 ;;
    --skip-units)      SKIP_UNITS=1 ;;
    --skip-remote-mounts) SKIP_REMOTE_MOUNTS=1 ;;
    --skip-smart)      SKIP_SMART=1 ;;
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
# One decimal allowed, because PSI percentages are fractional; the integer part
# is what is range-checked, and 100.5 is refused with it.
if ! [[ "$MAX_PSI" =~ ^[0-9]+(\.[0-9])?$ ]] || (( ${#MAX_PSI} > 5 )) || (( 10#${MAX_PSI%%.*} > 100 )) ||
   [[ "${MAX_PSI%%.*}" == "100" && "$MAX_PSI" == *.[1-9] ]]; then
  err "--max-psi must be a percentage between 0 and 100 (one decimal allowed), got: $MAX_PSI"
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

# A mount point is whatever someone named a directory or a USB stick's label,
# so control characters go before it is printed. Tab and newline are kept.
clean() { tr -d '\000-\010\013-\037'; }

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
  head -n 10 <<<"$session_lines" | sed 's/^/           /'
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

# --- storage ---------------------------------------------------------------
# The failures that take a server down quietly, none of which df shows: a
# filesystem the kernel remounted read-only after an error (everything works
# until the next write), an fstab mount that did not come back after a reboot,
# a degraded md array, a disk that reports its own failure, and a network
# mount that has stopped answering and now blocks df and every login that
# touches it. Read-only throughout: mount, fsck and mdadm appear only in hints.
group "storage"
mounts_txt=""
if [[ -r "$PROC_DIR/mounts" ]]; then
  mounts_txt="$(clean < "$PROC_DIR/mounts")"
fi
if [[ -z "$mounts_txt" ]]; then
  skip "$PROC_DIR/mounts unreadable; mounts not checked"
else
  # Real filesystems only, and the token "ro" exactly: "errors=remount-ro" is
  # an option, not a state. squashfs, iso9660, erofs and overlay are read-only
  # by design, and snaps and desktop media mounts are expected to be. So is
  # the ostree /sysroot, and any mount fstab declares ro. A mount with no
  # fstab entry (a bind or volume mounted :ro) is only reported when it
  # carries errors=remount-ro, which is what a kernel remount leaves behind.
  fstab_in=/dev/null
  [[ -r "$FSTAB" ]] && fstab_in="$FSTAB"
  ro_rows="$(awk '
    NR == FNR {
      if ($0 !~ /^[[:space:]]*#/ && NF >= 4) {
        fs[$2] = 1
        if (("," $4 ",") ~ /,ro,/) fsro[$2] = 1
      }
      next
    }
    $3 ~ /^(ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat|ntfs|ntfs3|zfs)$/ &&
    ("," $4 ",") ~ /,ro,/ &&
    $2 != "/sysroot" && !($2 in fsro) &&
    (($2 in fs) || ("," $4 ",") ~ /,errors=remount-ro,/) &&
    $2 !~ /^\/(snap|var\/lib\/snapd|run\/media)(\/|$)/ { print $2, $3 }
  ' "$fstab_in" - <<<"$mounts_txt")"
  ro_n=0
  while read -r mp fstype; do
    [[ -n "$mp" ]] || continue
    ro_n=$((ro_n + 1))
    (( ro_n <= 5 )) || continue
    warn "$mp is mounted read-only ($fstype)" \
      "if unplanned: dmesg | grep -iE 'remount|I/O error|EXT4-fs error'; fsck needs it unmounted"
  done <<< "$ro_rows"
  if (( ro_n == 0 )); then
    ok "no real filesystem is mounted read-only"
  elif (( ro_n > 5 )); then
    info "and $(( ro_n - 5 )) more read-only mount(s): grep -w ro $PROC_DIR/mounts"
  fi

  # Expected but absent. noauto entries are meant to be mounted by hand, and a
  # nofail entry was declared optional by whoever wrote it, so that one is a
  # note rather than a warning.
  if [[ -r "$FSTAB" ]]; then
    mounted_points="$(awk '{ print $2 }' <<<"$mounts_txt")"
    fstab_rows="$(clean < "$FSTAB" | awk '
      /^[ \t]*#/ || NF < 3 { next }
      $2 == "none" || $2 == "swap" || $3 == "swap" || $3 == "none" { next }
      {
        opts = (NF >= 4) ? $4 : "defaults"
        if (("," opts ",") ~ /,noauto,/) next
        mp = $2
        if (mp != "/") sub(/\/+$/, "", mp)
        print mp, $3, opts
      }')"
    fstab_n=0
    fstab_missing=0
    while read -r mp fstype opts; do
      [[ -n "$mp" ]] || continue
      fstab_n=$((fstab_n + 1))
      grep -qxF -- "$mp" <<<"$mounted_points" && continue
      fstab_missing=$((fstab_missing + 1))
      (( fstab_missing <= 5 )) || continue
      case ",$opts," in
        *,nofail,*) info "fstab entry $mp is not mounted (nofail, $fstype)" "mount $mp  # then journalctl -b -u '*.mount'" ;;
        *)          warn "fstab entry $mp is not mounted ($fstype)" "mount $mp  # then journalctl -b -u '*.mount'" ;;
      esac
    done <<< "$fstab_rows"
    if (( fstab_n == 0 )); then
      info "no auto-mounted entries in $FSTAB"
    elif (( fstab_missing == 0 )); then
      ok "every fstab entry is mounted ($fstab_n checked)"
    elif (( fstab_missing > 5 )); then
      info "and $(( fstab_missing - 5 )) more fstab entr(ies) not mounted"
    fi
  else
    skip "$FSTAB unreadable; fstab mounts not checked"
  fi
fi

# md arrays. The member map is the bracket pair on the status line: [2/1] [U_]
# says two members, one up, the second missing. A recovery or resync line is
# progress, not a fault.
if [[ -r "$PROC_DIR/mdstat" ]]; then
  md_rows="$(clean < "$PROC_DIR/mdstat" | awk '
    /^md[0-9]+[ \t]*:/ { md = $1; next }
    md != "" && match($0, /\[[0-9]+\/[0-9]+\] \[[U_]+\]/) {
      state = substr($0, RSTART, RLENGTH)
      print ((state ~ /_/) ? "DEG" : "OK"), md, state
      next
    }
    md != "" && match($0, /(recovery|resync|reshape|check)[ \t]*=[ \t]*[0-9.]+%/) {
      what = substr($0, RSTART, RLENGTH)
      gsub(/[ \t]*=[ \t]*/, " ", what)
      print "PROG", md, what
    }')"
  md_n=0
  while read -r kind md state; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      DEG)  md_n=$((md_n + 1)); warn "md array $md is degraded ($state)" "mdadm --detail /dev/$md" ;;
      OK)   md_n=$((md_n + 1)); ok "md array $md is healthy ($state)" ;;
      PROG) info "md array $md: $state" ;;
    esac
  done <<< "$md_rows"
  (( md_n > 0 )) || skip "no md arrays in $PROC_DIR/mdstat"
else
  skip "no md arrays ($PROC_DIR/mdstat absent)"
fi

# A disk's own verdict on itself. -H is the health query only: no self-test is
# started and no attribute is changed. Needs root to open the devices.
if (( SKIP_SMART )); then
  skip "SMART health (--skip-smart)"
elif ! have smartctl; then
  skip "smartctl not installed; disk health not checked"
elif [[ "$(id -u)" != "0" ]]; then
  skip "SMART needs root; rerun with sudo"
else
  smart_n=0
  while read -r dev dflag dtype _rest; do
    [[ "$dev" =~ ^/dev/[A-Za-z0-9/_.-]+$ ]] || continue
    smart_n=$((smart_n + 1))
    (( smart_n <= 32 )) || break
    dargs=()
    [[ "$dflag" == "-d" && "$dtype" =~ ^[A-Za-z0-9_,+-]+$ ]] && dargs=(-d "$dtype")
    if have timeout; then
      health="$(timeout 20 smartctl -H "${dargs[@]+"${dargs[@]}"}" "$dev" 2>/dev/null | clean)"
    else
      health="$(smartctl -H "${dargs[@]+"${dargs[@]}"}" "$dev" 2>/dev/null | clean)"
    fi
    if grep -q 'FAILED' <<<"$health"; then
      warn "SMART overall health FAILED on $dev" "smartctl -a $dev  # replace the disk"
    elif grep -qE 'PASSED|Health Status: OK' <<<"$health"; then
      ok "SMART health PASSED on $dev"
    else
      reason="$(grep -m 1 -iE 'unavailable|not supported|unable|error' <<<"$health" || true)"
      skip "SMART health unknown on $dev${reason:+: ${reason:0:80}}"
    fi
  done <<< "$(smartctl --scan 2>/dev/null | clean)"
  (( smart_n > 0 )) || skip "smartctl --scan found no devices"
fi

# A network mount whose server is gone does not fail, it hangs, and takes df
# and any shell that touches it along. Each one is probed with a bounded stat;
# -k sends KILL after the TERM, which an NFS wait still honours.
remote_rows="$(awk '$3 ~ /^(nfs|nfs4|cifs|smb3|smbfs|fuse\.sshfs)$/ { print $2, $3 }' <<<"$mounts_txt")"
while read -r mp fstype; do
  [[ -n "$mp" ]] || continue
  if (( SKIP_REMOTE_MOUNTS )); then
    skip "$mp ($fstype) not probed (--skip-remote-mounts)"
  elif ! have timeout; then
    skip "$mp ($fstype) not probed: timeout(1) not installed"
  else
    # /proc/mounts writes a space in a path as \040; stat needs the real name.
    real_mp="$(printf '%b' "$mp")"
    timeout -k 2 5 stat -f -- "$real_mp" >/dev/null 2>&1
    st_rc=$?
    case "$st_rc" in
      0)       ok "$mp answers ($fstype)" ;;
      124|137) warn "$mp did not answer within 5s (stale or unreachable $fstype mount)" \
                 "umount -f -l '$mp' after confirming the server is gone" ;;
      *)       warn "$mp could not be read (stat exited $st_rc, $fstype)" "grep '$mp' $PROC_DIR/mounts; dmesg | tail" ;;
    esac
  fi
done <<< "$remote_rows"

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
    head -n 10 <<<"$stale" | sed 's/^/           /'
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
    head -n 20 <<<"$journal_out" | sed 's/^/           /'
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

# --- pressure --------------------------------------------------------------
# Load average counts tasks waiting on I/O as busy and never sees memory
# stalls, so it is the wrong number for "everything is slow". The kernel's own
# answer is pressure stall information: the share of the last minute in which
# tasks were stalled on CPU, memory or I/O. Next to it are the limits that
# produce random errors when they run out: file handles, the connection
# tracking table (full means silent packet drops), threads and PIDs, and
# processes stuck in uninterruptible sleep. Every probe reads procfs and skips
# when its file is missing, so old kernels and containers stay quiet. Nothing
# is tuned; sysctl names appear only in hints (sysctl_defaults.sh applies).
group "pressure"

# Integer percentage of used/limit, or nothing when either is not a number.
pct_of() {
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 1
  (( ${#1} <= 15 && ${#2} <= 15 && 10#$2 > 0 )) || return 1
  printf '%s\n' $(( 10#$1 * 100 / 10#$2 ))
}

psi_warned=0
psi_seen=0
for res in cpu memory io; do
  psi_file="$PROC_DIR/pressure/$res"
  [[ -e "$psi_file" ]] || continue
  psi_seen=1
  # "some" is the share of time at least one task stalled; "full" (memory and
  # io, and cpu on newer kernels) is the share in which every runnable task did.
  psi="$(awk '
    $1 == "some" || $1 == "full" {
      for (i = 2; i <= NF; i++) { n = split($i, kv, "="); if (n == 2) v[$1 "_" kv[1]] = kv[2] }
    }
    END {
      printf "%s %s %s\n", ("some_avg10" in v) ? v["some_avg10"] : "-", ("some_avg60" in v) ? v["some_avg60"] : "-", ("full_avg60" in v) ? v["full_avg60"] : "-"
    }' "$psi_file" 2>/dev/null)"
  read -r s10 s60 f60 <<< "$psi"
  if ! [[ "${s60:-}" =~ ^[0-9]+(\.[0-9]+)?$ && "${s10:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    skip "$res pressure unreadable ($psi_file)"
    continue
  fi
  [[ "${f60:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || f60="-"
  verdict="$(awk -v s="$s60" -v f="$f60" -v m="$MAX_PSI" -v r="$res" 'BEGIN {
    if (s + 0 >= m + 0) print "some"
    else if (r != "cpu" && f != "-" && f + 0 >= (m + 0) / 2) print "full"
    else print "ok" }')"
  s60_1="$(awk -v x="$s60" 'BEGIN { printf "%.1f", x }')"
  s10_1="$(awk -v x="$s10" 'BEGIN { printf "%.1f", x }')"
  case "$res" in
    cpu)    psi_hint="top -o %CPU" ;;
    memory) psi_hint="ps aux --sort=-%mem | head" ;;
    io)     psi_hint="iostat -x 1 · iotop" ;;
  esac
  case "$verdict" in
    some)
      psi_warned=1
      warn "$res pressure: tasks stalled ${s60_1}% of the last 60s (avg10 ${s10_1})" "$psi_hint"
      ;;
    full)
      psi_warned=1
      warn "$res pressure: every task stalled $(awk -v x="$f60" 'BEGIN { printf "%.1f", x }')% of the last 60s (some ${s60_1}%)" "$psi_hint"
      ;;
    *)
      ok "$res pressure: ${s60_1}% stalled over the last 60s"
      ;;
  esac
done
(( psi_seen )) || skip "kernel has no PSI (needs Linux 4.20+, CONFIG_PSI)"

# allocated, unused, max. On kernels that report unused as 0 the first field
# is already the used count.
if [[ -r "$PROC_DIR/sys/fs/file-nr" ]]; then
  read -r fh_alloc fh_unused fh_max _ < "$PROC_DIR/sys/fs/file-nr"
  if [[ "${fh_alloc:-}" =~ ^[0-9]+$ && "${fh_unused:-}" =~ ^[0-9]+$ ]] && fh_pct="$(pct_of "$(( 10#$fh_alloc - 10#$fh_unused ))" "${fh_max:-}")"; then
    fh_used=$(( 10#$fh_alloc - 10#$fh_unused ))
    if (( fh_pct >= 80 )); then
      warn "file handles ${fh_pct}% used ($fh_used of $fh_max)" "lsof | awk '{print \$1}' | sort | uniq -c | sort -rn | head"
    else
      ok "file handles ${fh_pct}% used ($fh_used of $fh_max)"
    fi
  else
    skip "file-nr unreadable ($PROC_DIR/sys/fs/file-nr)"
  fi
else
  skip "no $PROC_DIR/sys/fs/file-nr"
fi

# Only present when the conntrack module is loaded; absent is normal and says
# nothing, so it prints nothing.
ct_dir="$PROC_DIR/sys/net/netfilter"
if [[ -r "$ct_dir/nf_conntrack_count" && -r "$ct_dir/nf_conntrack_max" ]]; then
  ct_count="$(tr -d '[:space:]' < "$ct_dir/nf_conntrack_count")"
  ct_max="$(tr -d '[:space:]' < "$ct_dir/nf_conntrack_max")"
  if ct_pct="$(pct_of "$ct_count" "$ct_max")"; then
    if (( ct_pct >= 80 )); then
      warn "connection tracking table ${ct_pct}% full ($ct_count of $ct_max)" "sysctl net.netfilter.nf_conntrack_max; dmesg | grep 'table full'"
    else
      ok "connection tracking table ${ct_pct}% full ($ct_count of $ct_max)"
    fi
  else
    skip "conntrack counters unreadable"
  fi
fi

# Every thread takes a PID, so threads are measured against both limits. The
# fourth loadavg field is running/total scheduling entities.
if [[ -r "$PROC_DIR/loadavg" ]]; then
  read -r _ _ _ la_tasks _ < "$PROC_DIR/loadavg"
  threads="${la_tasks#*/}"
  if [[ "$threads" =~ ^[0-9]+$ ]]; then
    procs=0
    for d in "$PROC_DIR"/[0-9]*; do
      [[ -d "$d" ]] && procs=$((procs + 1))
    done
    pid_used=$(( 10#$threads > procs ? 10#$threads : procs ))
    limits_checked=0
    if [[ -r "$PROC_DIR/sys/kernel/threads-max" ]]; then
      tmax="$(tr -d '[:space:]' < "$PROC_DIR/sys/kernel/threads-max")"
      if t_pct="$(pct_of "$threads" "$tmax")"; then
        limits_checked=1
        if (( t_pct >= 80 )); then
          warn "$threads threads: ${t_pct}% of kernel.threads-max ($tmax)" "ps -eLf | awk '{print \$2}' | uniq -c | sort -rn | head"
        fi
      fi
    fi
    if [[ -r "$PROC_DIR/sys/kernel/pid_max" ]]; then
      pmax="$(tr -d '[:space:]' < "$PROC_DIR/sys/kernel/pid_max")"
      if p_pct="$(pct_of "$pid_used" "$pmax")"; then
        limits_checked=1
        if (( p_pct >= 80 )); then
          warn "$pid_used PIDs in use: ${p_pct}% of kernel.pid_max ($pmax)" "sysctl kernel.pid_max; ps -eo nlwp,pid,comm --sort=-nlwp | head"
        fi
      fi
    fi
    if (( limits_checked )) && (( ${t_pct:-0} < 80 && ${p_pct:-0} < 80 )); then
      ok "$threads threads and $procs processes, well inside the PID and thread limits"
    elif (( limits_checked == 0 )); then
      skip "threads-max and pid_max unreadable"
    fi
  else
    skip "loadavg task count unreadable"
  fi
else
  skip "no $PROC_DIR/loadavg"
fi

# One ps call, read twice. A zombie holds only a PID until its parent reaps it;
# a process in D state is waiting on I/O it cannot be interrupted from, and a
# handful of them is the usual sign of a dying disk or a dead network mount.
# It is a snapshot: a busy disk shows a few in passing.
ps_out="$(ps -eo stat=,pid=,comm= 2>/dev/null | clean)"; ps_rc=$?
if (( ps_rc != 0 )) || [[ -z "$ps_out" ]]; then
  skip "ps -eo stat,pid,comm did not answer; process states not checked"
else
  z_n="$(awk '$1 ~ /^Z/ { c++ } END { print c + 0 }' <<<"$ps_out")"
  d_rows="$(awk '$1 ~ /^D/ { print $2, $3 }' <<<"$ps_out")"
  d_n="$(grep -c . <<<"$d_rows" || true)"
  [[ "$d_n" =~ ^[0-9]+$ ]] || d_n=0
  if (( z_n >= 10 )); then
    warn "$z_n zombie process(es)" "their parent has not reaped them: ps -o ppid= -p <pid>, then restart that parent"
  elif (( z_n > 0 )); then
    info "$z_n zombie process(es)"
  fi
  if (( d_n >= 5 )); then
    warn "$d_n process(es) in uninterruptible sleep (stuck on I/O?)" \
      "a snapshot, rerun to confirm; as root: cat /proc/<pid>/stack, and see the storage section"
    (( QUIET )) || head -n 5 <<<"$d_rows" | sed 's/^/           /'
  elif (( d_n > 0 )); then
    info "$d_n process(es) in uninterruptible sleep right now"
  fi
  (( z_n < 10 && d_n < 5 )) && ok "no pile-up of zombie or uninterruptible processes"
fi

# Who is holding the stalled resource, when a stall was reported. --sort is a
# procps option; a ps without it is a note, not a failure.
if (( psi_warned )); then
  top_mem="$(ps -eo pid=,comm=,%mem=,%cpu= --sort=-%mem 2>/dev/null | clean | head -n 3)"
  top_cpu="$(ps -eo pid=,comm=,%mem=,%cpu= --sort=-%cpu 2>/dev/null | clean | head -n 3)"
  if [[ -n "$top_mem" && -n "$top_cpu" ]]; then
    info "top by memory (pid comm %mem %cpu):"
    (( QUIET )) || head -n 3 <<<"$top_mem" | sed 's/^/           /'
    info "top by CPU (pid comm %mem %cpu):"
    (( QUIET )) || head -n 3 <<<"$top_cpu" | sed 's/^/           /'
  else
    skip "ps --sort is not supported here; no top consumers listed"
  fi
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

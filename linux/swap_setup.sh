#!/usr/bin/env bash
# swap_setup.sh
# Report, create or remove a swapfile, with the matching /etc/fstab line.
#
# Cloud droplets and fresh VMs often ship with no swap, and the first OOM kill
# sends someone to a half-remembered fallocate / mkswap / swapon / fstab recipe.
# system_doctor.sh reports that swap is missing and sysctl_defaults.sh tunes
# vm.swappiness; this is the step between them.
#
# Read-only by default: with no mode flag it reports active swap, the swap
# lines in fstab, vm.swappiness, RAM and a suggested size. --create and
# --remove change the machine, preview with --dry-run, and need --yes. It never
# touches an existing file or a partition, never enables swap on a device,
# never sets swappiness, and edits fstab only by an atomic same-directory
# replace after a timestamped backup, removing only the line it added. If any
# step fails before swapon succeeds, the file it just created is removed.
#
# --path and --fstab are how the tests point it at fixtures; no environment
# variable is read for that.
#
# Exit codes:
#   0   report printed, or the change was made
#   1   a step failed, or there is not enough free space
#   2   preflight failed (not Linux, not root, mkswap/swapon missing, or a
#       filesystem that cannot hold a swapfile)
#   3   bad CLI arguments, or a change requested without --yes
#   4   nothing to do (the file exists, swap is already active without
#       --force, or nothing to remove)
set -u
set -o pipefail

MODE="report"
CREATE_REQUESTED=0
REMOVE_REQUESTED=0
DRY_RUN=0
ASSUME_YES=0
FORCE=0
SIZE="2G"
SIZE_SET=0
SWAP_PATH="/swapfile"
FSTAB="/etc/fstab"
MARKER="# ops-toolbox swapfile"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
swap_setup.sh - report, create or remove a swapfile and its fstab line

Read-only by default: prints active swap, the swap lines in fstab,
vm.swappiness, RAM and a suggested size. --create and --remove change the
machine, need root and --yes, and preview with --dry-run. Never touches an
existing file or a partition; fstab is backed up before it is edited.

Usage:
  $(basename "$0")
  $(basename "$0") --create --dry-run
  sudo $(basename "$0") --create --size 4G --yes
  sudo $(basename "$0") --remove --yes

Options:
  --create         Create, enable and persist a swapfile
  --remove         Disable the swapfile, drop the fstab line it added, delete it
  --size SIZE      Swapfile size, 128M to 64G, like 512M or 4G (default: $SIZE)
  --path FILE      Swapfile path, absolute, no whitespace or backslash (default: $SWAP_PATH)
  --fstab FILE     fstab to read and edit (default: $FSTAB)
  --force          With --create, add a swapfile even though swap is already active
  --dry-run        Print every step without running it
  --yes, -y        Required for --create or --remove to change anything
  --help, -h       Show this help

Exit codes: 0 done or report printed, 1 a step failed or not enough space,
2 not Linux / not root / tools missing / unsupported filesystem, 3 usage,
4 nothing to do (file exists, swap already active, nothing to remove)
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
    --create)    MODE="create"; CREATE_REQUESTED=1 ;;
    --remove)    MODE="remove"; REMOVE_REQUESTED=1 ;;
    --size)      require_value "$1" "${2:-}"; SIZE="$2"; SIZE_SET=1; shift ;;
    --size=*)    SIZE="${1#*=}"; require_value "--size" "$SIZE"; SIZE_SET=1 ;;
    --path)      require_value "$1" "${2:-}"; SWAP_PATH="$2"; shift ;;
    --path=*)    SWAP_PATH="${1#*=}"; require_value "--path" "$SWAP_PATH" ;;
    --fstab)     require_value "$1" "${2:-}"; FSTAB="$2"; shift ;;
    --fstab=*)   FSTAB="${1#*=}"; require_value "--fstab" "$FSTAB" ;;
    --force)     FORCE=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( CREATE_REQUESTED == 1 && REMOVE_REQUESTED == 1 )); then
  err "--create and --remove are separate modes; choose one"
  exit 3
fi
if (( SIZE_SET == 1 && CREATE_REQUESTED == 0 )); then
  err "--size applies to --create"
  exit 3
fi
if (( FORCE == 1 && CREATE_REQUESTED == 0 )); then
  err "--force applies to --create"
  exit 3
fi

# SIZE in MiB, from the validated NNNM / NNNG form.
SIZE_MIB=0
if [[ "$SIZE" =~ ^[1-9][0-9]*[MG]$ ]]; then
  SIZE_MIB="${SIZE%?}"
  [[ "$SIZE" == *G ]] && SIZE_MIB=$((SIZE_MIB * 1024))
fi
if (( SIZE_MIB < 128 || SIZE_MIB > 65536 )); then
  err "--size must be between 128M and 64G, like 512M or 4G, got: $SIZE"
  exit 3
fi

case "$SWAP_PATH" in
  /*) ;;
  *) err "--path must be absolute, got: $SWAP_PATH"; exit 3 ;;
esac
case "$FSTAB" in
  /*) ;;
  *) err "--fstab must be absolute, got: $FSTAB"; exit 3 ;;
esac
# The path becomes the first field of an fstab line, where whitespace splits
# fields and a backslash starts an octal escape; refuse them (and control
# characters) rather than write a line fstab would read differently.
if [[ "$SWAP_PATH" =~ [[:space:][:cntrl:]\\] ]]; then
  err "--path must not contain whitespace, control characters or backslashes"
  exit 3
fi
# Compare the resolved path, not the string: '/proc/../proc/x' and '//' name
# the same places as their plain spellings.
swap_resolved="$(realpath -m -- "$SWAP_PATH" 2>/dev/null || printf '%s' "$SWAP_PATH")"
case "$swap_resolved" in
  /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*)
    err "--path refuses $swap_resolved (resolved from '$SWAP_PATH')"
    exit 3
    ;;
esac
SWAP_PATH="$swap_resolved"

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }
step() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# Active swap areas, one name per line. swapon --show is util-linux 2.23+;
# /proc/swaps is the fallback that every kernel has.
active_names() {
  local out
  if have swapon && out="$(swapon --show=NAME --noheadings 2>/dev/null)"; then
    awk 'NF { print $1 }' <<<"$out"
    return 0
  fi
  [[ -r /proc/swaps ]] && awk 'NR > 1 && NF { print $1 }' /proc/swaps
  return 0
}

# Non-comment fstab lines whose type field is swap.
fstab_swap_lines() {
  [[ -r "$FSTAB" ]] || return 0
  awk '!/^[ \t]*#/ && $3 == "swap"' "$FSTAB"
}

fstab_has() {
  [[ -r "$FSTAB" ]] || return 1
  awk -v f="$1" '!/^[ \t]*#/ && $1 == f { found = 1 } END { exit !found }' "$FSTAB"
}

# The one line this script writes, matched whole so --remove can never take
# out a line somebody else wrote for the same file.
fstab_line() {
  printf '%s none swap sw 0 0 %s\n' "$1" "$MARKER"
}

# --- report ----------------------------------------------------------------
report() {
  local active fstab_lines mem_kb ram_mib suggest_mib swappiness
  step "swap"
  if have swapon && active="$(swapon --show=NAME,TYPE,SIZE,USED --noheadings 2>/dev/null)"; then
    :
  else
    active="$( [[ -r /proc/swaps ]] && awk 'NR > 1 && NF' /proc/swaps )"
  fi
  if [[ -n "${active//[[:space:]]/}" ]]; then
    ok "active swap:"
    awk 'NF { print "         " $0 }' <<<"$active"
  else
    info "no active swap"
  fi

  step "fstab ($FSTAB)"
  if [[ ! -r "$FSTAB" ]]; then
    warn "cannot read $FSTAB"
  fi
  fstab_lines="$(fstab_swap_lines)"
  if [[ -n "$fstab_lines" ]]; then
    ok "swap entries:"
    awk '{ print "         " $0 }' <<<"$fstab_lines"
  else
    info "no swap entries"
  fi

  step "memory"
  swappiness="$(tr -d ' \t\n' < /proc/sys/vm/swappiness 2>/dev/null || true)"
  info "vm.swappiness = ${swappiness:-unknown} (sysctl_defaults.sh manages it)"
  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    ram_mib=$((mem_kb / 1024))
    if (( ram_mib <= 2048 )); then
      suggest_mib=$((ram_mib * 2))
    elif (( ram_mib <= 8192 )); then
      suggest_mib=$ram_mib
    else
      suggest_mib=4096
    fi
    info "RAM ${ram_mib}M"
    info "suggested size: $(( (suggest_mib + 1023) / 1024 ))G"
  else
    info "RAM unknown (no /proc/meminfo)"
  fi

  if [[ -z "${active//[[:space:]]/}" && -z "$fstab_lines" ]]; then
    printf "\n"
    info "no swap configured; preview one with: $(basename "$0") --create --dry-run"
  fi
}

# Every change goes through here: previewed under --dry-run, run otherwise.
# Returns the command's status so the caller can unwind.
run_step() {
  local label="$1"; shift
  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    return 0
  fi
  if "$@"; then
    ok "$label"
    return 0
  fi
  err "$label failed"
  return 1
}

# Copy fstab aside, refusing to overwrite an earlier copy. cp -p keeps the
# mode and ownership, so the backup is no more readable than the original.
backup_fstab() {
  local backup
  backup="$FSTAB.ops-toolbox.$(date +%Y%m%d-%H%M%S-%N).bak"
  if [[ -e "$backup" ]]; then
    err "refusing to overwrite $backup"
    return 1
  fi
  if ! cp -p -- "$FSTAB" "$backup"; then
    err "could not back up $FSTAB"
    return 1
  fi
  info "backup: $backup"
}

# Write the new fstab beside the old one and rename it over: a crash leaves
# either the old file or the new one, never half of each. The temporary file
# starts as a cp -p of the original, so it inherits its mode and owner.
replace_fstab() {
  local filter="$1" tmp
  tmp="$(mktemp "$(dirname "$FSTAB")/.fstab.ops-toolbox.XXXXXXXX")" || {
    err "could not create a temporary file beside $FSTAB"
    return 1
  }
  if ! cp -p -- "$FSTAB" "$tmp"; then
    rm -f -- "$tmp"
    err "could not copy $FSTAB"
    return 1
  fi
  case "$filter" in
    append)
      fstab_line "$SWAP_PATH" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
      ;;
    drop)
      awk -v l="$(fstab_line "$SWAP_PATH")" '$0 != l' "$FSTAB" > "$tmp" || { rm -f -- "$tmp"; return 1; }
      ;;
  esac
  if ! mv -f -- "$tmp" "$FSTAB"; then
    rm -f -- "$tmp"
    err "could not replace $FSTAB"
    return 1
  fi
}

change_preflight() {
  if (( DRY_RUN == 0 && ASSUME_YES == 0 )); then
    err "refusing to change swap without --yes; preview with --dry-run"
    exit 3
  fi
  if [[ "$(id -u)" != "0" ]] && (( DRY_RUN == 0 )); then
    err "--$MODE needs root (or --dry-run to preview)"
    exit 2
  fi
  if [[ ! -f "$FSTAB" ]]; then
    err "no fstab at $FSTAB"
    exit 2
  fi
}

# --- create ----------------------------------------------------------------
create() {
  local dir fstype avail_kib need_kib created=0 active line
  change_preflight
  for tool in mkswap swapon; do
    if ! have "$tool"; then
      err "required tool is missing: $tool"
      exit 2
    fi
  done
  if [[ -e "$SWAP_PATH" || -L "$SWAP_PATH" ]]; then
    err "$SWAP_PATH already exists; this script never reuses or overwrites a file"
    exit 4
  fi
  active="$(active_names)"
  if [[ -n "$active" ]] && (( FORCE == 0 )); then
    info "swap is already active: $(tr '\n' ' ' <<<"$active" | sed 's/ $//')"
    info "pass --force to add $SWAP_PATH as well"
    exit 4
  fi

  dir="$(dirname "$SWAP_PATH")"
  if [[ ! -d "$dir" ]]; then
    err "no directory $dir"
    exit 2
  fi
  # Swapfiles need a filesystem that maps file blocks directly. These either
  # cannot (tmpfs, ramfs, network filesystems, zfs) or need their own tool:
  # btrfs makes one with `btrfs filesystem mkswapfile`.
  fstype="$(stat -f -c %T "$dir" 2>/dev/null || true)"
  case "$fstype" in
    tmpfs|ramfs|nfs|nfs4|cifs|smb2|zfs)
      err "$dir is on $fstype, which cannot hold a swapfile"
      exit 2
      ;;
    btrfs)
      err "$dir is on btrfs; create the file with 'btrfs filesystem mkswapfile' by hand"
      exit 2
      ;;
  esac

  avail_kib="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  need_kib=$(( SIZE_MIB * 1024 * 11 / 10 ))
  if ! [[ "$avail_kib" =~ ^[0-9]+$ ]] || (( avail_kib < need_kib )); then
    err "not enough free space in $dir for $SIZE plus 10% (${avail_kib:-unknown} KiB available, $need_kib needed)"
    exit 1
  fi

  step "create $SWAP_PATH ($SIZE)"
  line="$(fstab_line "$SWAP_PATH")"
  # The file is private from the moment it exists: swap holds memory pages.
  umask 077
  if (( DRY_RUN == 1 )); then
    run_step "allocate $SIZE" fallocate -l "$SIZE" "$SWAP_PATH"
  elif have fallocate && fallocate -l "$SIZE" "$SWAP_PATH" 2>/dev/null; then
    created=1
    ok "allocate $SIZE"
  else
    # fallocate is missing, or the filesystem does not support it (ext3,
    # some XFS setups). dd writes every block, which is slower but works.
    rm -f -- "$SWAP_PATH"
    created=1
    run_step "allocate $SIZE with dd" dd if=/dev/zero of="$SWAP_PATH" bs=1M count="$SIZE_MIB" status=none || {
      rm -f -- "$SWAP_PATH"
      exit 1
    }
  fi
  if ! run_step "restrict to mode 600" chmod 600 "$SWAP_PATH" \
    || ! run_step "format as swap" mkswap "$SWAP_PATH" \
    || ! run_step "enable" swapon "$SWAP_PATH"; then
    if (( created == 1 )); then
      rm -f -- "$SWAP_PATH" && info "removed $SWAP_PATH, which this run created"
    fi
    exit 1
  fi

  if fstab_has "$SWAP_PATH"; then
    info "$FSTAB already lists $SWAP_PATH; left as it is"
  elif (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s would append to %s, after a backup: %s\n" "$C_DIM" "$C_RESET" "$FSTAB" "$line"
  else
    if ! backup_fstab || ! replace_fstab append; then
      err "$SWAP_PATH is active, but $FSTAB was not updated; it will not survive a reboot"
      exit 1
    fi
    ok "appended to $FSTAB: $line"
  fi
}

# --- remove ----------------------------------------------------------------
remove() {
  local is_active=0 in_fstab=0 marked=0 line
  change_preflight
  if [[ -e "$SWAP_PATH" && ! -f "$SWAP_PATH" ]] || [[ -L "$SWAP_PATH" ]]; then
    err "$SWAP_PATH is not a regular file; this script never removes a device or partition"
    exit 3
  fi
  line="$(fstab_line "$SWAP_PATH")"
  grep -qxF -- "$SWAP_PATH" <<<"$(active_names)" && is_active=1
  fstab_has "$SWAP_PATH" && in_fstab=1
  grep -qxF -- "$line" "$FSTAB" 2>/dev/null && marked=1
  if (( is_active == 0 && in_fstab == 0 )); then
    info "nothing to remove: $SWAP_PATH is neither active nor in $FSTAB"
    exit 4
  fi
  if (( in_fstab == 1 && marked == 0 )); then
    err "$FSTAB lists $SWAP_PATH with a line this script did not write"
    err "remove that line by hand first; it is never edited from here"
    exit 4
  fi

  step "remove $SWAP_PATH"
  if (( is_active == 1 )); then
    run_step "disable" swapoff "$SWAP_PATH" || exit 1
  fi
  if (( marked == 1 )); then
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s would drop from %s, after a backup: %s\n" "$C_DIM" "$C_RESET" "$FSTAB" "$line"
    else
      if ! backup_fstab || ! replace_fstab drop; then
        exit 1
      fi
      ok "dropped from $FSTAB: $line"
    fi
  fi
  if [[ -f "$SWAP_PATH" ]]; then
    run_step "delete" rm -f -- "$SWAP_PATH" || exit 1
  fi
}

case "$MODE" in
  report) report ;;
  create) create ;;
  remove) remove ;;
esac

if (( DRY_RUN == 1 )) && [[ "$MODE" != "report" ]]; then
  printf "dry-run complete; no changes written\n"
fi
exit 0

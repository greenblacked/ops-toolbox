#!/usr/bin/env bash
# sysctl_defaults.sh
# Report, apply and revert a small set of Linux sysctl values.
#
# The counterpart of macos-initial-setup/macos_defaults.sh. Read-only by
# default: running it with no flags changes nothing and prints the current
# value of each setting beside the desired one. --apply writes a drop-in under
# /etc/sysctl.d/ and applies it live; --revert restores the values captured by
# the last apply and removes the drop-in.
#
# The list is deliberately short. These are the knobs a workstation hits when
# an IDE's file watcher runs out of inotify watches, or when a laptop spends
# its afternoon swapping. Kernel networking tweaks, production hardening and
# container-host map-count changes stay out: they are context-specific in the
# same way auto-hardening would be, and hardening_audit.sh already reports
# the security-relevant ones.
#
# Exit codes:
#   0   success (nothing to change, or changes applied)
#   1   one or more settings failed to apply
#   2   preflight failed (not Linux, or --apply without root)
#   3   bad CLI arguments
set -u
set -o pipefail

MODE="report"
DRY_RUN=0
ONLY=""
APPLY_REQUESTED=0
REVERT_REQUESTED=0
BACKUP_DIR="${TMPDIR:-/tmp}"
BACKUP_FILE=""
REVERT_FROM=""
SYSCTL_D="${SYSCTL_D:-/etc/sysctl.d}"
PROC_SYS="${PROC_SYS:-/proc/sys}"
DROP_IN_NAME="99-ops-toolbox.conf"
DROP_IN="$SYSCTL_D/$DROP_IN_NAME"

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

FAIL_COUNT=0

usage() {
  cat <<EOF
sysctl_defaults.sh - report, apply and revert Linux sysctl values

Read-only by default. Running it with no flags changes nothing: it prints the
current value of each setting beside the desired one, so you can see what
--apply would do before doing it.

Usage:
  $(basename "$0")                         # report current vs desired
  $(basename "$0") --apply                 # write the drop-in and apply live
  $(basename "$0") --apply --dry-run       # show the file without writing it
  $(basename "$0") --revert                # restore values from the last --apply
  $(basename "$0") --list-groups

Options:
  --apply            Write /etc/sysctl.d/$DROP_IN_NAME and apply live
  --revert           Restore from the most recent backup written by --apply
  --backup-file P    Write an --apply backup to this new file
  --revert-from P    Revert from this backup instead of guessing the newest
  --dry-run          With --apply or --revert, print instead of writing
  --only GROUPS      Scope report/apply to a subset (see --list-groups)
  --list-groups      Print the group names and exit
  --help, -h         Show this help

SYSCTL_D and PROC_SYS are honoured so the apply path is testable without
writing into /etc. Every --apply writes the previous values to:
  ${BACKUP_DIR}/sysctl_defaults-backup-<timestamp>.txt

Exit codes: 0 success, 1 one or more settings failed, 2 not Linux / not root, 3 usage
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

# group|key|value|what it does
#
# Keys are sysctl dotted names. Values are integers. Keep this list short: a
# sysctl collection is the same kind of regretted automation macos_defaults.sh
# warns about, and a long one will be wrong on somebody's machine.
SETTINGS='
inotify|fs.inotify.max_user_watches|524288|file-watcher ceiling for IDEs and recursive watches
inotify|fs.inotify.max_user_instances|1024|concurrent inotify instances per user
inotify|fs.inotify.max_queued_events|16384|inotify event queue before events are dropped
vm|vm.swappiness|10|prefer RAM over swap on a workstation
'

groups_list() {
  local group
  while IFS='|' read -r group _rest; do
    [[ -n "$group" ]] && printf '%s\n' "$group"
  done <<EOF
${SETTINGS}
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --apply)        MODE="apply"; APPLY_REQUESTED=1 ;;
    --revert)       MODE="revert"; REVERT_REQUESTED=1 ;;
    --backup-file)  require_value "$1" "${2:-}"; BACKUP_FILE="$2"; shift ;;
    --backup-file=*) BACKUP_FILE="${1#*=}"; require_value "--backup-file" "$BACKUP_FILE" ;;
    --revert-from)  require_value "$1" "${2:-}"; REVERT_FROM="$2"; shift ;;
    --revert-from=*) REVERT_FROM="${1#*=}"; require_value "--revert-from" "$REVERT_FROM" ;;
    --dry-run)      DRY_RUN=1 ;;
    --only)         require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)       ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --list-groups)  groups_list | sort -u; exit 0 ;;
    -h|--help)      usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( APPLY_REQUESTED == 1 && REVERT_REQUESTED == 1 )); then
  err "--apply and --revert are separate modes; choose one"
  exit 3
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

group_wanted() {
  local group="$1"
  [[ -z "$ONLY" ]] && return 0
  local part
  IFS=',' read -r -a parts <<< "$ONLY"
  for part in "${parts[@]}"; do
    [[ "$part" == "$group" ]] && return 0
  done
  return 1
}

if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a only_parts <<< "$ONLY"
  for part in "${only_parts[@]}"; do
    case "$part" in
      inotify|vm) ;;
      *) err "unknown --only group: $part (see --list-groups)"; exit 3 ;;
    esac
  done
fi

key_to_proc() {
  local key="$1"
  local path="$PROC_SYS"
  local rest="$key"
  while [[ "$rest" == *.* ]]; do
    path="$path/${rest%%.*}"
    rest="${rest#*.}"
  done
  printf '%s/%s\n' "$path" "$rest"
}

read_current() {
  local proc_file
  proc_file="$(key_to_proc "$1")"
  if [[ -r "$proc_file" ]]; then
    tr -d ' \t\n' < "$proc_file"
    return 0
  fi
  return 1
}

write_live() {
  local key="$1" value="$2"
  local proc_file
  proc_file="$(key_to_proc "$key")"
  if [[ -w "$proc_file" ]]; then
    printf '%s\n' "$value" > "$proc_file"
    return $?
  fi
  # sysctl(8) always addresses the running kernel, so taking this fallback
  # while PROC_SYS points somewhere else would step straight out of the
  # sandbox the override exists to create — a test run would silently retune
  # the host it runs on, and the backup written beside it would record the
  # fixture's values rather than the real ones, making --revert a no-op.
  # Fail loudly instead.
  if [[ "$PROC_SYS" != "/proc/sys" ]]; then
    err "refusing 'sysctl -w $key': PROC_SYS is $PROC_SYS, not /proc/sys"
    return 1
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -w "$key=$value" >/dev/null
    return $?
  fi
  return 1
}

# A backup is only as trustworthy as the file it sits in. BACKUP_DIR defaults
# to /tmp, which is world-writable: any local user can drop a file matching the
# glob below and wait for root to run --revert. The sticky bit does not help —
# it prevents deleting somebody else's file, not creating your own. So require
# the file to be owned by root or by whoever is running this, and to be
# writable by nobody else.
backup_is_trustworthy() {
  local src="$1" owner mode grp oth
  owner="$(stat -c '%u' -- "$src" 2>/dev/null || printf '')"
  mode="$(stat -c '%a' -- "$src" 2>/dev/null || printf '')"
  [[ -n "$owner" && -n "$mode" ]] || return 1
  [[ "$owner" == "0" || "$owner" == "$(id -u)" ]] || return 1
  grp="${mode: -2:1}"
  oth="${mode: -1}"
  case "$grp$oth" in
    *[2367]*) return 1 ;;
  esac
  return 0
}

newest_backup() {
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    backup_is_trustworthy "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(ls -1t "$BACKUP_DIR"/sysctl_defaults-backup-*.txt 2>/dev/null)
  return 1
}

# --revert feeds every key it reads to write_live. Restoring a key this script
# never manages would let a planted backup set anything at all — kernel.core_pattern
# to a command, say — so the file is treated as data to match against the table,
# not as a list of instructions.
known_key() {
  local candidate="$1" group key value blurb
  while IFS='|' read -r group key value blurb; do
    [[ -n "$group" ]] || continue
    [[ "$key" == "$candidate" ]] && return 0
  done <<EOF
${SETTINGS}
EOF
  return 1
}

# --- report ----------------------------------------------------------------
report() {
  local group key value blurb current
  local last_group=""
  while IFS='|' read -r group key value blurb; do
    [[ -n "$group" ]] || continue
    group_wanted "$group" || continue
    if [[ "$group" != "$last_group" ]]; then
      printf "\n%s== %s ==%s\n" "$C_BOLD" "$group" "$C_RESET"
      last_group="$group"
    fi
    if current="$(read_current "$key")"; then
      if [[ "$current" == "$value" ]]; then
        ok "$key = $current"
      else
        info "$key = $current  (desired $value)  $blurb"
      fi
    else
      printf "  %s[skip]%s %s unreadable\n" "$C_DIM" "$C_RESET" "$key"
    fi
  done <<EOF
${SETTINGS}
EOF
}

drop_in_body() {
  local group key value blurb
  printf '# written by linux/sysctl_defaults.sh — --revert removes this file\n'
  while IFS='|' read -r group key value blurb; do
    [[ -n "$group" ]] || continue
    group_wanted "$group" || continue
    printf '%s = %s\n' "$key" "$value"
  done <<EOF
${SETTINGS}
EOF
}

backup_current() {
  local dest="$1"
  local group key value blurb current
  # The default backup name carries a timestamp, so only an explicit
  # --backup-file can land on something that already exists — and this used to
  # truncate it without a word. A backup destination is not worth destroying a
  # file for.
  if [[ -s "$dest" ]]; then
    err "refusing to overwrite $dest"
    err "it already exists and is not empty; choose another --backup-file"
    exit 3
  fi
  : > "$dest"
  printf '# sysctl_defaults.sh backup %s\n' "$(date)" >> "$dest"
  while IFS='|' read -r group key value blurb; do
    [[ -n "$group" ]] || continue
    group_wanted "$group" || continue
    if current="$(read_current "$key")"; then
      printf '%s=%s\n' "$key" "$current" >> "$dest"
    fi
  done <<EOF
${SETTINGS}
EOF
}

needs_real_root() {
  # The SYSCTL_D / PROC_SYS overrides exist so apply can be tested without
  # writing into /etc. Root is required only when those still point at the
  # real kernel and distro drop-in directory.
  [[ "$SYSCTL_D" == /etc/* || "$PROC_SYS" == /proc/* ]]
}

# --- apply -----------------------------------------------------------------
apply() {
  if [[ "$(id -u)" != "0" ]] && (( DRY_RUN == 0 )) && needs_real_root; then
    err "--apply needs root (or --dry-run to preview)"
    exit 2
  fi

  # The drop-in is rewritten from scratch, and drop_in_body only emits the
  # groups --only names. So applying one group replaces a file that held
  # several, and the dropped ones revert at the next boot rather than now —
  # which is the worst time to find out. The backup beside it is filtered the
  # same way, so it cannot put them back either.
  if [[ -n "$ONLY" ]] && [[ -f "$DROP_IN" ]]; then
    warn "--only rewrites $DROP_IN with just: $ONLY"
    warn "  any other group already in that file is dropped, and the change"
    warn "  shows up at the next boot rather than now"
  fi

  local body
  body="$(drop_in_body)"

  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s would write %s\n" "$C_DIM" "$C_RESET" "$DROP_IN"
    printf '%s\n' "$body" | sed 's/^/           /'
    local group key value blurb current
    while IFS='|' read -r group key value blurb; do
      [[ -n "$group" ]] || continue
      group_wanted "$group" || continue
      current="$(read_current "$key" || printf '?')"
      printf "  %s(dry-run)%s sysctl -w %s=%s  %s(now %s)%s\n" \
        "$C_DIM" "$C_RESET" "$key" "$value" "$C_DIM" "$current" "$C_RESET"
    done <<EOF
${SETTINGS}
EOF
    printf "dry-run complete; no changes written\n"
    return 0
  fi

  mkdir -p "$SYSCTL_D" || { err "cannot create $SYSCTL_D"; exit 1; }

  if [[ -z "$BACKUP_FILE" ]]; then
    BACKUP_FILE="$BACKUP_DIR/sysctl_defaults-backup-$(date +%Y%m%d-%H%M%S).txt"
  fi
  backup_current "$BACKUP_FILE"
  info "backup: $BACKUP_FILE"

  printf '%s\n' "$body" > "$DROP_IN" || { err "cannot write $DROP_IN"; exit 1; }
  ok "wrote $DROP_IN"

  local group key value blurb
  while IFS='|' read -r group key value blurb; do
    [[ -n "$group" ]] || continue
    group_wanted "$group" || continue
    if write_live "$key" "$value"; then
      ok "$key = $value"
    else
      err "failed to apply $key=$value"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done <<EOF
${SETTINGS}
EOF
}

# --- revert ----------------------------------------------------------------
revert() {
  local src="${REVERT_FROM:-}"
  if [[ -z "$src" ]]; then
    src="$(newest_backup || true)"
  fi
  if [[ -z "$src" || ! -f "$src" ]]; then
    err "no backup to revert from; pass --revert-from FILE"
    exit 3
  fi

  if ! backup_is_trustworthy "$src"; then
    err "refusing to revert from $src"
    err "a backup must be owned by root or by $(id -un), and writable by nobody else"
    err "fix with: sudo chown root:root '$src' && sudo chmod 600 '$src'"
    exit 3
  fi

  if [[ "$(id -u)" != "0" ]] && (( DRY_RUN == 0 )) && needs_real_root; then
    err "--revert needs root (or --dry-run to preview)"
    exit 2
  fi

  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s would restore from %s\n" "$C_DIM" "$C_RESET" "$src"
    printf "  %s(dry-run)%s would remove %s\n" "$C_DIM" "$C_RESET" "$DROP_IN"
    grep -vE '^\s*(#|$)' "$src" | sed 's/^/           /'
    printf "dry-run complete; no changes written\n"
    return 0
  fi

  info "restoring from $src"
  local line key value
  while IFS= read -r line; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    [[ -n "$key" && -n "$value" ]] || continue
    if ! known_key "$key"; then
      warn "skipping $key: not a key this script manages"
      continue
    fi
    if write_live "$key" "$value"; then
      ok "$key = $value"
    else
      err "failed to restore $key=$value"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done < "$src"

  if [[ -f "$DROP_IN" ]]; then
    rm -f "$DROP_IN"
    ok "removed $DROP_IN"
  fi
}

case "$MODE" in
  report) report ;;
  apply)  apply ;;
  revert) revert ;;
esac

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0

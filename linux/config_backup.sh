#!/usr/bin/env bash
# config_backup.sh
# Dated tar of selected paths (default: /etc) so an upgrade or an edit has
# something to roll back to.
#
# This is the Linux counterpart of mikrotik/backup.lua and
# mikrotik/export_config.py: a copy you can keep, not a restore tool. It never
# writes back into the paths it archives. A dry run writes nothing, including
# logs. A real run requires --yes.
#
# Default source is /etc because that is what people actually mean by "the
# box config". Home directories, databases and container volumes stay out —
# those are backups with a different blast radius, and this script is the
# one you run before editing sshd_config.
#
# Exit codes:
#   0   archive written (or dry-run completed)
#   1   tar or rotation failed
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
set -u
set -o pipefail

DRY_RUN=0
ASSUME_YES=0
LIST=0
LIST_FILE=""
DEST=""
KEEP=7
PREFIX="config"
PATHS=()

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
config_backup.sh - dated tar of selected paths (default: /etc)

Writes a gzip archive and rotates older copies in --dest. A dry run writes
nothing. A real run requires --yes. This is a copy, not a restore.

Usage:
  $(basename "$0") --dry-run
  $(basename "$0") --yes
  $(basename "$0") --list
  $(basename "$0") --yes --paths /etc/ssh,/etc/nginx --dest DIR --keep 5

Options:
  --dry-run          Print the archive path without writing it
  --yes, -y          Required for a run that actually writes
  --list [FILE]      Show contents of FILE, or of the newest archive in --dest
  --paths LIST       Comma-separated absolute paths (repeatable; default: /etc)
  --dest DIR         Directory for archives (default: ~/ops-toolbox-backups)
  --keep N           Archives to retain after a successful write (default: $KEEP; 0 = keep all)
  --prefix NAME      Filename prefix (default: $PREFIX)
  --help, -h         Show this help

Exit codes: 0 success, 1 tar or rotation failed, 2 not Linux, 3 usage
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

add_paths() {
  local raw="$1"
  local item
  local parts
  IFS=',' read -r -a parts <<< "$raw"
  for item in "${parts[@]}"; do
    [[ -n "$item" ]] || continue
    PATHS+=("$item")
  done
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)     DRY_RUN=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --list)
      LIST=1
      if [[ -n "${2:-}" && "$2" != --* ]]; then
        LIST_FILE="$2"
        shift
      fi
      ;;
    --list=*)      LIST=1; LIST_FILE="${1#*=}"; require_value "--list" "$LIST_FILE" ;;
    --paths)       require_value "$1" "${2:-}"; add_paths "$2"; shift ;;
    --paths=*)     add_paths "${1#*=}"; require_value "--paths" "${1#*=}" ;;
    --dest)        require_value "$1" "${2:-}"; DEST="$2"; shift ;;
    --dest=*)      DEST="${1#*=}"; require_value "--dest" "$DEST" ;;
    --keep)        require_value "$1" "${2:-}"; KEEP="$2"; shift ;;
    --keep=*)      KEEP="${1#*=}"; require_value "--keep" "$KEEP" ;;
    --prefix)      require_value "$1" "${2:-}"; PREFIX="$2"; shift ;;
    --prefix=*)    PREFIX="${1#*=}"; require_value "--prefix" "$PREFIX" ;;
    -h|--help)     usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || (( KEEP > 3650 )); then
  err "--keep must be an integer between 0 and 3650, got: $KEEP"
  exit 3
fi

case "$PREFIX" in
  *[!A-Za-z0-9._-]*)
    err "--prefix may contain letters, digits, dot, underscore and hyphen only"
    exit 3
    ;;
esac
[[ -n "$PREFIX" ]] || { err "--prefix must not be empty"; exit 3; }

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

resolve_dest() {
  if [[ -z "$DEST" ]]; then
    if [[ -z "${HOME:-}" ]]; then
      err "\$HOME is not set; pass --dest DIR"
      exit 2
    fi
    DEST="$HOME/ops-toolbox-backups"
  fi
  case "$DEST" in
    /*) ;;
    *) DEST="$(pwd)/$DEST" ;;
  esac
}

if (( LIST )); then
  if [[ -z "$LIST_FILE" ]]; then
    resolve_dest
    LIST_FILE="$(ls -1t "$DEST"/"$PREFIX"-*.tar.gz 2>/dev/null | head -n 1 || true)"
    if [[ -z "$LIST_FILE" ]]; then
      err "no $PREFIX-*.tar.gz archives in $DEST"
      exit 3
    fi
  fi
  if [[ ! -f "$LIST_FILE" ]]; then
    err "not an archive: $LIST_FILE"
    exit 3
  fi
  info "listing $LIST_FILE"
  tar -tzf "$LIST_FILE"
  exit $?
fi

if (( DRY_RUN == 0 && ASSUME_YES == 0 )); then
  err "refusing to write an archive without --yes; preview with --dry-run"
  exit 3
fi

if (( ${#PATHS[@]} == 0 )); then
  PATHS=("/etc")
fi

resolve_dest

stamp="$(date +%Y%m%d-%H%M%S)"
archive="$DEST/${PREFIX}-${stamp}.tar.gz"

rels=()
missing=0
for p in "${PATHS[@]}"; do
  case "$p" in
    /*) ;;
    *)
      err "paths must be absolute, got: $p"
      exit 3
      ;;
  esac
  # Compare the resolved path, not the string. '//', '/.', '/../' and
  # '/etc/..' all name root; an exact match on '/' lets every one of them
  # through and tars the whole filesystem into --dest.
  resolved="$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
  if [[ "$resolved" == "/" ]]; then
    err "refusing to archive / (resolved from '$p')"
    exit 3
  fi
  p="$resolved"
  if [[ ! -e "$p" ]]; then
    warn "skipping missing path: $p"
    missing=$((missing + 1))
    continue
  fi
  rel="${p#/}"
  [[ -n "$rel" ]] || rel="."
  rels+=("$rel")
done

if (( ${#rels[@]} == 0 )); then
  err "no existing paths to archive"
  exit 3
fi

info "archive: $archive"
for rel in "${rels[@]}"; do
  info "include: /$rel"
done
(( missing )) && info "skipped $missing missing path(s)"

rotate_old() {
  local keep="$1"
  local do_it="$2"
  local match removed
  [[ "$keep" == "0" ]] && return 0
  [[ -d "$DEST" ]] || return 0
  match="$(ls -1t "$DEST"/"$PREFIX"-*.tar.gz 2>/dev/null || true)"
  [[ -n "$match" ]] || return 0
  # Dry-run has not written the new archive yet, so count it as the newest
  # entry; otherwise --keep 1 would leave one old copy plus the new one.
  removed=0
  (( do_it )) || removed=1
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    removed=$((removed + 1))
    if (( removed > keep )); then
      if (( do_it )); then
        if rm -f "$old"; then
          ok "rotated $old"
        else
          err "could not remove $old"
          FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
      else
        info "would rotate $old"
      fi
    fi
  done <<< "$match"
}

if (( DRY_RUN )); then
  info "would create $DEST"
  info "would write $archive"
  rotate_old "$KEEP" 0
  info "dry-run complete; no changes written"
  exit 0
fi

if ! mkdir -p "$DEST"; then
  err "could not create $DEST"
  exit 1
fi

# -C / so the archive contains etc/ssh/... rather than an absolute path that
# restores on top of the live tree by accident. GNU and BusyBox tar both
# accept this form. Unreadable files are a warning from tar, not a reason to
# skip the rest of the tree. No `set -e`: a warning must not abort rotation.
tar -czf "$archive" -C / "${rels[@]}"
tar_rc=$?
if (( tar_rc != 0 )); then
  # tar exits 1 for warnings (unreadable files under /etc) and 2 for fatal.
  # A warning still produced an archive, which is the useful outcome on a
  # machine where /etc/shadow is root-only and the caller is not root.
  if [[ -s "$archive" ]] && (( tar_rc == 1 )); then
    warn "tar reported unreadable files; archive still written"
  else
    err "tar failed (exit $tar_rc)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    rm -f "$archive"
  fi
fi

if [[ -f "$archive" ]]; then
  ok "wrote $archive ($(stat -c '%s' "$archive") bytes)"
  rotate_old "$KEEP" 1
else
  err "archive was not written"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0

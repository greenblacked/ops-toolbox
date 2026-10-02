#!/usr/bin/env bash
# config_backup.sh
# Dated tar of selected paths (default: /etc) so an upgrade or an edit has
# something to roll back to.
#
# This is the Linux counterpart of mikrotik/features/backup.lua and
# mikrotik/features/export_config.py: a copy you can keep, not a restore tool. It never
# writes back into the paths it archives. A dry run writes nothing, including
# logs. A real run requires --yes. The archive is created mode 0600, because
# what it holds is /etc.
#
# Default source is /etc because that is what people actually mean by "the
# box config". Home directories, databases and container volumes stay out —
# those are backups with a different blast radius, and this script is the
# one you run before editing sshd_config.
#
# Exit codes:
#   0   complete archive written (or dry-run completed)
#   1   partial backup, or staging, validation, publication or rotation failed
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

Validates and publishes a unique gzip archive, then rotates older copies in
--dest. Partial backups are named *.partial.tar.gz and return exit 1. Requires
flock (util-linux) and a destination filesystem supporting hard links. Files are
created mode 0600: the default source is /etc, which holds shadow, sudoers and
the sshd host keys. A dry run writes nothing. A real run requires --yes. This
is a copy, not a restore.

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
  --keep N           Complete and partial archives to retain separately (default: $KEEP; 0 = keep all)
  --prefix NAME      Filename prefix (default: $PREFIX)
  --help, -h         Show this help

Exit codes: 0 complete backup, 1 partial backup or failure, 2 preflight, 3 usage
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
archive="$DEST/${PREFIX}-${stamp}-UNIQUE.tar.gz"

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
  local partial_only="${3:-0}"
  local match old name complete_count partial_count count
  local candidates=()
  [[ "$keep" == "0" ]] && return 0
  [[ -d "$DEST" ]] || return 0
  # Read basenames so even a destination containing a newline is safe. All
  # generated basenames use only the validated prefix and a fixed alphabet.
  for old in "$DEST"/"$PREFIX"-*.tar.gz; do
    [[ -f "$old" && ! -L "$old" ]] || continue
    name="${old##*/}"
    # Unrecognised names are not ours to rotate. In particular, ls output for
    # a newline-containing name could otherwise become two deletion targets.
    case "$name" in *[!A-Za-z0-9._-]*) continue ;; esac
    candidates+=("$name")
  done
  (( ${#candidates[@]} > 0 )) || return 0
  match="$(cd "$DEST" && ls -1t -- "${candidates[@]}" 2>/dev/null || true)"
  [[ -n "$match" ]] || return 0
  complete_count=0
  partial_count=0
  # A preview assumes a new complete archive. It writes no staging or lock.
  (( do_it )) || complete_count=1
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    old="$DEST/$old"
    # Symlinks and directories are not generations owned by this script.
    [[ -f "$old" && ! -L "$old" ]] || continue
    case "$old" in
      *.partial.tar.gz) partial_count=$((partial_count + 1)); count="$partial_count" ;;
      *)
        (( partial_only )) && continue
        complete_count=$((complete_count + 1)); count="$complete_count"
        ;;
    esac
    if (( count > keep )); then
      if (( do_it )); then
        if rm -f -- "$old"; then
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
  info "would write $DEST/${PREFIX}-${stamp}-UNIQUE.tar.gz (validated before publication)"
  rotate_old "$KEEP" 0
  info "dry-run complete; no changes written"
  exit 0
fi

for tool in tar gzip mktemp flock ln; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    err "required tool is missing: $tool"
    exit 2
  fi
done

if ! mkdir -p -- "$DEST"; then
  err "could not create $DEST"
  exit 1
fi

# The private directory keeps the staged pathname out of other users' reach.
# mktemp creates it atomically; the file is 0600 before tar writes any secrets.
# Staging under --dest also guarantees publication stays on one filesystem.
stage_dir="$(umask 077; mktemp -d "$DEST/.${PREFIX}-stage.XXXXXXXX")" || {
  err "could not create private staging directory in $DEST"
  exit 1
}
trap 'if ! rm -rf -- "$stage_dir"; then err "could not remove staging directory: $stage_dir"; exit 1; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
staged_archive="$stage_dir/archive.tar.gz"
if ! (umask 077; set -C; : > "$staged_archive"); then
  err "could not create private staged archive"
  exit 1
fi

# -C / keeps member names relative to the filesystem root. A tar warning can
# produce a useful partial copy, but neither an exit code nor a nonempty file
# proves the gzip stream and tar members are readable.
tar -czf "$staged_archive" -C / "${rels[@]}"
tar_rc=$?
if (( tar_rc > 1 )); then
  err "tar failed (exit $tar_rc); previous archives preserved"
  exit 1
fi
# GNU tar accepts an empty stream (and some short non-tar streams) as an
# empty archive. At least one listed member is required: every included file
# or directory should contribute one. Drain the listing to avoid SIGPIPE.
if ! gzip -t -- "$staged_archive" || ! tar -tzf "$staged_archive" | (
  found=0
  while IFS= read -r; do found=1; done
  (( found ))
); then
  err "staged archive failed validation; previous archives preserved"
  exit 1
fi

archive="$DEST/${PREFIX}-${stamp}-${stage_dir##*.}"
partial=0
if (( tar_rc == 1 || missing > 0 )); then
  archive="$archive.partial.tar.gz"
  partial=1
  warn "partial backup: tar exit $tar_rc, $missing requested path(s) missing"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  archive="$archive.tar.gz"
fi

# Lock the destination directory's inode rather than a predictable writable
# lock file. Publication and rotation share this lock across concurrent runs;
# staging and validation may proceed independently. The descriptor closes on
# exit, including signals, so an interrupted run cannot leave a stale lock.
if ! exec 9<"$DEST"; then
  err "could not open destination for locking"
  exit 1
fi
if ! flock -x 9; then
  err "could not lock destination; previous archives preserved"
  exit 1
fi

# link(2) publishes the already validated inode atomically and refuses an
# occupied name. -T prevents ln from following a destination directory symlink.
# Never use mv here: its normal replacement behavior would destroy a backup.
if ! ln -T -- "$staged_archive" "$archive"; then
  err "could not publish $archive; previous archives preserved"
  exit 1
fi
ok "wrote $archive ($(stat -c '%s' "$archive") bytes)"
rotate_old "$KEEP" 1 "$partial"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0

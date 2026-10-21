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
# --diff answers the question after the edit: what is different now from the
# newest archive (or a named one)? GNU tar compares the members with the live
# tree and extracts nothing, so it stays read-only like --list, and the one-file
# restore it suggests is printed, never run. The exclusions an archive was made
# with are stored in it as the member .config_backup/excludes (one pattern per
# line after two header lines), so --diff can leave the same files out of its
# new-file scan; --exclude and --exclude-secrets on --diff add to that set. An
# archive without the member is compared as before.
#
# --exclude and --exclude-secrets make an archive you can hand to somebody:
# tar exclusion patterns, matched against member names relative to /, passed
# to tar as separate arguments. The preset is short and fixed on purpose
# (shadow, gshadow, opasswd, the SSH host private keys, /etc/ssl/private and
# the distro's NAME- backup copies). It narrows what is in the archive; it
# does not make an archive safe to publish.
#
# Exit codes:
#   0   complete archive written (or dry-run completed); --diff: no differences
#   1   partial backup, or staging, validation, publication or rotation failed;
#       --diff: differences found, a file could not be compared, or the
#       compare itself failed
#   2   preflight failed (not Linux, or tar missing for --diff)
#   3   bad CLI arguments (including --diff with --list, --yes or --dry-run, or
#       no archive to compare)
set -u
set -o pipefail

DRY_RUN=0
ASSUME_YES=0
LIST=0
LIST_FILE=""
DIFF=0
DIFF_FILE=""
EXCLUDES=()
EXCLUDE_SECRETS=0
# --exclude-secrets: the secrets a default /etc run would otherwise carry.
# Fixed and documented rather than clever, so nobody mistakes it for a
# guarantee. etc/*- is the distro's passwd-, shadow- and group- backups.
SECRET_PATTERNS='etc/shadow*
etc/gshadow*
etc/security/opasswd
etc/ssh/ssh_host_*_key
etc/ssl/private
etc/*-'
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
  $(basename "$0") --diff
  $(basename "$0") --yes --paths /etc/ssh,/etc/nginx --dest DIR --keep 5

Options:
  --dry-run          Print the archive path without writing it
  --yes, -y          Required for a run that actually writes
  --list [FILE]      Show contents of FILE, or of the newest archive in --dest
  --diff [FILE]      Compare FILE (or the newest archive) with the live --paths;
                     read-only, no --yes; exit 1 when anything differs
  --paths LIST       Comma-separated absolute paths (repeatable; default: /etc)
  --dest DIR         Directory for archives (default: ~/ops-toolbox-backups)
  --keep N           Complete and partial archives to retain separately (default: $KEEP; 0 = keep all)
  --prefix NAME      Filename prefix (default: $PREFIX)
  --exclude PATTERN  Leave out members matching a tar glob, relative to /
                     (repeatable), e.g. 'etc/ssl/private' or '*.key'
  --exclude-secrets  Leave out shadow, gshadow, opasswd, SSH host private keys,
                     /etc/ssl/private and NAME- backups; not a publish-safe filter
                     Both are recorded in the archive; --diff applies them (and
                     accepts more) so excluded files are not reported as NEW
  --help, -h         Show this help

Exit codes: 0 complete backup (--diff: identical), 1 partial backup or failure
(--diff: differences found), 2 preflight, 3 usage
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

# Patterns are relative to /, because tar runs with -C / and sees member
# names without the leading slash; one with a slash would silently match
# nothing, which reads exactly like a working exclusion.
add_exclude() {
  local pattern="$1"
  if [[ -z "$pattern" ]]; then
    err "--exclude pattern must not be empty"
    exit 3
  fi
  if [[ "$pattern" == *$'\n'* ]]; then
    err "--exclude pattern must not contain a newline"
    exit 3
  fi
  if [[ "$pattern" == "# "* ]]; then
    err "--exclude pattern must not start with '# ' (the archive manifest uses that for comments)"
    exit 3
  fi
  if [[ "$pattern" == /* ]]; then
    err "--exclude patterns are relative to /; drop the leading slash: $pattern"
    exit 3
  fi
  EXCLUDES+=("$pattern")
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
    --diff)
      DIFF=1
      if [[ -n "${2:-}" && "$2" != --* ]]; then
        DIFF_FILE="$2"
        shift
      fi
      ;;
    --diff=*)      DIFF=1; DIFF_FILE="${1#*=}"; require_value "--diff" "$DIFF_FILE" ;;
    --paths)       require_value "$1" "${2:-}"; add_paths "$2"; shift ;;
    --paths=*)     add_paths "${1#*=}"; require_value "--paths" "${1#*=}" ;;
    --dest)        require_value "$1" "${2:-}"; DEST="$2"; shift ;;
    --dest=*)      DEST="${1#*=}"; require_value "--dest" "$DEST" ;;
    --keep)        require_value "$1" "${2:-}"; KEEP="$2"; shift ;;
    --keep=*)      KEEP="${1#*=}"; require_value "--keep" "$KEEP" ;;
    --prefix)      require_value "$1" "${2:-}"; PREFIX="$2"; shift ;;
    --prefix=*)    PREFIX="${1#*=}"; require_value "--prefix" "$PREFIX" ;;
    --exclude)     require_value "$1" "${2:-}"; add_exclude "$2"; shift ;;
    --exclude=*)   require_value "--exclude" "${1#*=}"; add_exclude "${1#*=}" ;;
    --exclude-secrets) EXCLUDE_SECRETS=1 ;;
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

# Exclusions shape an archive being written, and --diff applies them to the
# live scan; --list only reads, so they mean nothing there.
if (( LIST && (${#EXCLUDES[@]} > 0 || EXCLUDE_SECRETS) )); then
  err "--exclude and --exclude-secrets apply to writing or comparing an archive, not to --list"
  exit 3
fi

# --diff reads; every one of these asks for something else, and quietly
# ignoring one would leave the caller believing it happened.
if (( DIFF )); then
  if (( LIST )); then
    err "--diff and --list are separate modes; choose one"
    exit 3
  fi
  if (( ASSUME_YES || DRY_RUN )); then
    err "--diff is read-only and writes nothing; drop --yes and --dry-run"
    exit 3
  fi
fi

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

# --- diff ------------------------------------------------------------------
# One finding per line: WORD /path (detail). Directory mtimes are left out on
# purpose: adding or deleting a file changes its parent's, so they only repeat
# a NEW or GONE line already printed. A directory whose mode or owner changed
# is still reported.
diff_line() {
  local word="$1" path="$2" detail="${3:-}" colour="$C_YELLOW"
  case "$word" in
    GONE) colour="$C_RED" ;;
    NEW)  colour="$C_BLUE" ;;
    SKIP) colour="$C_DIM" ;;
  esac
  if [[ -n "$detail" ]]; then
    printf "  %s%-7s%s %s (%s)\n" "$colour" "$word" "$C_RESET" "$path" "$detail"
  else
    printf "  %s%-7s%s %s\n" "$colour" "$word" "$C_RESET" "$path"
  fi
}

# Does PATH (relative to /, no leading slash) match PATTERN the way tar's
# default --exclude does: a glob whose * also matches /, tried against the
# whole name and against every suffix that starts after a /, and a match on
# a leading directory excludes what is below it.
path_matches() {
  local s="$1" pat="$2" d
  while :; do
    d="$s"
    while :; do
      # shellcheck disable=SC2053
      [[ "$d" == $pat ]] && return 0
      case "$d" in */*) d="${d%/*}" ;; *) break ;; esac
    done
    case "$s" in */*) s="${s#*/}" ;; *) break ;; esac
  done
  return 1
}

# Drop the live paths (absolute, one per line) that an exclusion would have
# kept out of the archive; with no patterns, the list passes through.
filter_excluded() {
  local path
  if (( ${#diff_excludes[@]} == 0 )); then
    cat
    return 0
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    excluded_path "${path#/}" || printf '%s\n' "$path"
  done
}

excluded_path() {
  local pat
  for pat in ${diff_excludes[@]+"${diff_excludes[@]}"}; do
    path_matches "$1" "$pat" && return 0
  done
  return 1
}

# --paths narrows the comparison: only findings under one of these count.
under_roots() {
  local path="$1" root
  for root in "${diff_roots[@]}"; do
    [[ "$path" == "$root" || "$path" == "$root"/* ]] && return 0
  done
  return 1
}

diff_changed=0
diff_gone=0
diff_new=0
diff_skipped=0
diff_unparsed=0
first_member=""
pending_path=""
pending_reasons=""

flush_changed() {
  [[ -n "$pending_path" ]] || return 0
  local live="/$pending_path"
  if [[ "$pending_reasons" == "Mod time differs" && -d "$live" && ! -L "$live" ]]; then
    :
  elif under_roots "$live"; then
    diff_line CHANGED "$live" "$pending_reasons"
    diff_changed=$((diff_changed + 1))
    [[ -n "$first_member" ]] || first_member="$pending_path"
  fi
  pending_path=""
  pending_reasons=""
}

# Directory members end in a slash and are dropped, so a new directory shows
# up as the files inside it.
archive_files() {
  tar -tzf "$1" 2>/dev/null | grep -v '/$' | sed 's|^|/|' | LC_ALL=C sort -u
}

# find's stderr goes to $live_err, not away: a subtree it cannot enter is
# files this listing never sees, and a silent miss would read as "0 new".
# A file, not a variable, because the caller reads this through a process
# substitution.
live_err=""
live_files() {
  local root
  for root in "${diff_roots[@]}"; do
    [[ -e "$root" ]] || continue
    LC_ALL=C find "$root" -xdev \( -type f -o -type l \) -print 2>>"$live_err"
  done | LC_ALL=C sort -u
}

# One SKIP per find error, so the exit code is nonzero and the user knows the
# NEW list is incomplete.
report_live_errors() {
  local line msg path reason
  [[ -s "$live_err" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    msg="${line#find: }"
    path="${msg%%: *}"
    reason="${msg#*: }"
    path="${path#[\`\']}"
    path="${path%\'}"
    if [[ "$reason" == "Permission denied" ]]; then
      reason="unreadable; new files here may be missing; rerun with sudo"
    else
      reason="$reason; new files here may be missing"
    fi
    diff_line SKIP "$path" "$reason"
    diff_skipped=$((diff_skipped + 1))
  done < "$live_err"
}

diff_archive() {
  local archive="$DIFF_FILE" out tar_rc line path reason p resolved
  local missing_suffix=": Cannot stat: No such file or directory"
  if [[ -z "$archive" ]]; then
    resolve_dest
    archive="$(ls -1t "$DEST"/"$PREFIX"-*.tar.gz 2>/dev/null | head -n 1 || true)"
    if [[ -z "$archive" ]]; then
      err "no $PREFIX-*.tar.gz archives in $DEST"
      exit 3
    fi
  fi
  if [[ ! -f "$archive" ]]; then
    err "not an archive: $archive"
    exit 3
  fi
  if ! command -v tar >/dev/null 2>&1; then
    err "required tool is missing: tar"
    exit 2
  fi

  (( ${#PATHS[@]} > 0 )) || PATHS=("/etc")
  diff_roots=()
  for p in "${PATHS[@]}"; do
    case "$p" in
      /*) ;;
      *) err "paths must be absolute, got: $p"; exit 3 ;;
    esac
    resolved="$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
    if [[ "$resolved" == "/" ]]; then
      err "refusing to compare / (resolved from '$p')"
      exit 3
    fi
    diff_roots+=("$resolved")
  done

  # The exclusions the archive was made with, then any given on this command
  # line. An archive from before the manifest has none, and is compared as it
  # always was.
  diff_excludes=()
  local manifest line recorded=0
  if manifest="$(tar -xzOf "$archive" .config_backup/excludes 2>/dev/null)"; then
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != "# "* ]] || continue
      diff_excludes+=("$line")
      recorded=$((recorded + 1))
    done <<< "$manifest"
  fi
  if (( EXCLUDE_SECRETS )); then
    while IFS= read -r line; do
      [[ -n "$line" ]] && diff_excludes+=("$line")
    done <<< "$SECRET_PATTERNS"
  fi
  if (( ${#EXCLUDES[@]} > 0 )); then
    diff_excludes+=("${EXCLUDES[@]}")
  fi
  if (( recorded > 0 )); then
    info "archive was made with $recorded exclusion(s); the same files are left out of the new-file scan"
  fi

  info "comparing $archive with the live tree"

  # tar -d compares every member with the file of the same name under -C and
  # extracts nothing. It exits 1 on a difference and 2 when it could not open
  # something, so the exit code alone cannot tell a difference from a failure;
  # whether every line it printed was understood can. GNU tar closes an exit 2
  # with a fixed trailer that only restates the lines before it, so it is
  # recognised and not counted: an unreadable file alone stays a SKIP.
  local diff_tar_excludes=() pat
  for pat in ${diff_excludes[@]+"${diff_excludes[@]}"}; do
    diff_tar_excludes+=("--exclude=$pat")
  done
  out="$(LC_ALL=C tar -dzf "$archive" ${diff_tar_excludes[@]+"${diff_tar_excludes[@]}"} -C / 2>&1)"
  tar_rc=$?
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    line="${line#tar: }"
    case "$line" in
      *"$missing_suffix")
        flush_changed
        path="${line%"$missing_suffix"}"
        path="${path%: Warning}"
        if under_roots "/$path"; then
          diff_line GONE "/$path"
          diff_gone=$((diff_gone + 1))
          [[ -n "$first_member" ]] || first_member="$path"
        fi
        ;;
      *": Cannot "*": Permission denied")
        flush_changed
        path="${line%: Cannot *}"
        if under_roots "/$path"; then
          diff_line SKIP "/$path" "unreadable; rerun with sudo"
          diff_skipped=$((diff_skipped + 1))
        fi
        ;;
      "Exiting with failure status due to previous errors")
        flush_changed
        ;;
      *": "*" differs"|*": Contents differ")
        path="${line%: *}"
        reason="${line##*: }"
        if [[ "$path" == "$pending_path" ]]; then
          pending_reasons="$pending_reasons, $reason"
        else
          flush_changed
          pending_path="$path"
          pending_reasons="$reason"
        fi
        ;;
      *)
        flush_changed
        warn "tar: $line"
        diff_unparsed=$((diff_unparsed + 1))
        ;;
    esac
  done <<< "$out"
  flush_changed

  if (( tar_rc > 1 && diff_unparsed > 0 )); then
    err "tar could not compare $archive (exit $tar_rc)"
    return 1
  fi

  # NEW: on disk under --paths, not in the archive. Both sides are sorted in
  # the C locale, which is the order comm expects.
  local new_list
  live_err="$(mktemp)" || { err "cannot create a temporary file"; return 1; }
  new_list="$(LC_ALL=C comm -13 <(archive_files "$archive") <(live_files | filter_excluded))"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    diff_line NEW "$path"
    diff_new=$((diff_new + 1))
  done <<< "$new_list"
  report_live_errors
  rm -f -- "$live_err"

  printf "%s changed, %s gone, %s new, %s skipped\n" \
    "$diff_changed" "$diff_gone" "$diff_new" "$diff_skipped"
  if (( diff_changed + diff_gone + diff_new + diff_skipped + diff_unparsed == 0 )); then
    ok "no differences from $archive"
    return 0
  fi
  if [[ -n "$first_member" ]]; then
    # Printed, never run: this script is a copy, not a restore.
    info "restore one file with: tar -xzf $(printf '%q' "$archive") -C / $(printf '%q' "$first_member")"
  fi
  return 1
}

if (( DIFF )); then
  diff_archive
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

if (( EXCLUDE_SECRETS )); then
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] && EXCLUDES+=("$pattern")
  done <<< "$SECRET_PATTERNS"
fi
# One argv entry per pattern, never a string handed to eval, so a pattern's
# shell metacharacters stay inert. The ${x[@]+...} form keeps an empty list
# legal under set -u on Bash 3.2.
tar_excludes=()
for pattern in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
  tar_excludes+=("--exclude=$pattern")
  if (( DRY_RUN )); then
    info "would exclude: $pattern"
  else
    info "exclude: $pattern"
  fi
done

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

# Record what was left out, inside the archive, so --diff can leave the same
# files out of its new-file scan instead of reporting each as NEW. Written
# only when there is something to record, so an archive without exclusions is
# what it always was. The staging directory is removed on exit.
manifest_args=()
if (( ${#EXCLUDES[@]} > 0 )); then
  manifest_dir="$stage_dir/manifest"
  if ! (umask 077; mkdir -p -- "$manifest_dir/.config_backup" \
        && {
          printf '# config_backup.sh exclusions, one tar pattern per line\n'
          printf '# exclude-secrets: %s\n' "$EXCLUDE_SECRETS"
          printf '%s\n' "${EXCLUDES[@]}"
        } > "$manifest_dir/.config_backup/excludes"); then
    err "could not write the exclusion manifest"
    exit 1
  fi
  manifest_args=(-C "$manifest_dir" .config_backup)
fi

# -C / keeps member names relative to the filesystem root. A tar warning can
# produce a useful partial copy, but neither an exit code nor a nonempty file
# proves the gzip stream and tar members are readable.
tar -czf "$staged_archive" ${tar_excludes[@]+"${tar_excludes[@]}"} -C / "${rels[@]}" ${manifest_args[@]+"${manifest_args[@]}"}
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

# A pattern that also matches the manifest member would drop it silently, and
# the archive would then be diffed as if nothing had been excluded.
if (( ${#manifest_args[@]} > 0 )) \
   && ! tar -tzf "$staged_archive" | grep -qx '\.config_backup/excludes'; then
  err "an --exclude pattern also matches .config_backup/excludes; narrow it"
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

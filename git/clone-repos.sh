#!/usr/bin/env bash
# Clone every git repository listed in a text file, one URL per line, into a
# parent directory. A repository that is already cloned is skipped, an
# occupied destination is reported and left alone, and a failure on one line
# never stops the rest. Useful for standing up a workstation from a list of
# the repositories you actually work in, and for the mirror of that: writing
# the list once and never cloning by hand again.
#
# File format:
#   - one repository URL (or local path) per line
#   - an optional second field is the destination, relative to --dir unless
#     it is absolute; the default is the repository name from the URL
#   - blank lines and lines starting with # are ignored
#
# Exit codes:
#   0   every listed repository was cloned or was already there
#   1   one or more repositories failed (bad line, occupied path, clone error)
#   2   preflight failed (list file unreadable, git missing, --dir unusable)
#   3   bad CLI arguments
#   4   the list has no entries
set -euo pipefail

# --- output ----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

info()  { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
debug() { (( VERBOSE )) && printf "%s[dbg ]%s %s\n" "$C_DIM" "$C_RESET" "$*"; return 0; }

# --- defaults --------------------------------------------------------------
DRY_RUN=0
VERBOSE=0
DEST_DIR="."
LIST_FILE="repos.txt"

usage() {
  cat <<EOF
clone-repos.sh - clone every git repository listed in a text file

Usage:
  $(basename "$0") [--dry-run] [--verbose] [--dir DIR] [FILE]

Arguments:
  FILE               List of repositories, one per line (default: repos.txt)

Options:
  -n, --dry-run      Print the clones that would run; write nothing
  -v, --verbose      Also print each line as it is read and each decision made
  -d, --dir DIR      Parent directory for the clones (default: current directory)
  -h, --help         Show this help

File format:
  - one repository URL or local path per line
  - an optional second field is the destination, relative to --dir unless it
    is absolute; the default is the repository name taken from the URL
  - blank lines and lines starting with # are ignored

Examples:
  $(basename "$0") --dry-run repos.txt
  $(basename "$0") --dir ~/src repos.txt

Exit codes: 0 success, 1 a repository failed, 2 preflight, 3 usage, 4 nothing to do
EOF
}

# Byte-identical to git/git_sync_default.sh — see CONTRIBUTING.md for why
# this is copied rather than sourced from a shared library.
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

# --- arguments -------------------------------------------------------------
# --help is handled here, before any preflight check, so it keeps working on a
# machine without git or without a list file.
file_given=0
while (( $# > 0 )); do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -d|--dir)     require_value "$1" "${2:-}"; DEST_DIR="$2"; shift ;;
    --dir=*)      DEST_DIR="${1#*=}"; require_value "--dir" "$DEST_DIR" ;;
    --)           shift; break ;;
    -*)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
    *)
      if (( file_given )); then
        err "unexpected argument: $1"
        usage >&2
        exit 3
      fi
      LIST_FILE="$1"
      file_given=1
      ;;
  esac
  shift
done
# Anything after a lone -- is the list file, and only one.
if (( $# > 0 )); then
  if (( file_given )) || (( $# > 1 )); then
    err "unexpected argument: ${2:-$1}"
    usage >&2
    exit 3
  fi
  LIST_FILE="$1"
fi

# --- preflight -------------------------------------------------------------
if [[ ! -e "$LIST_FILE" ]]; then
  err "repository list not found: $LIST_FILE"
  exit 2
fi
if [[ ! -f "$LIST_FILE" || ! -r "$LIST_FILE" ]]; then
  err "repository list is not a readable file: $LIST_FILE"
  exit 2
fi
if ! command -v git >/dev/null 2>&1; then
  err "git is not installed or not in PATH"
  exit 2
fi
if [[ -e "$DEST_DIR" && ! -d "$DEST_DIR" ]]; then
  err "destination exists and is not a directory: $DEST_DIR"
  exit 2
fi
if (( DRY_RUN == 0 )); then
  if ! mkdir -p "$DEST_DIR"; then
    err "failed to create destination directory: $DEST_DIR"
    exit 2
  fi
  if [[ ! -w "$DEST_DIR" ]]; then
    err "destination directory is not writable: $DEST_DIR"
    exit 2
  fi
fi

# --- helpers ---------------------------------------------------------------
run() {
  if (( DRY_RUN == 1 )); then
    printf "dry-run: would run: %s\n" "$*"
  else
    "$@"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# True when the directory holds nothing, dotfiles included. git clone accepts
# an empty directory as its target and refuses anything else.
is_empty_dir() {
  local d="$1" f
  for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    if [[ -e "$f" || -L "$f" ]]; then
      return 1
    fi
  done
  return 0
}

# The last path component of the URL with any .git suffix dropped, which is
# what git clone itself would name the checkout.
repo_name_from_url() {
  local name="${1%/}"
  name="${name%.git}"
  name="${name##*/}"
  # scp-style host:path with no slash in the path part
  name="${name##*:}"
  printf '%s' "$name"
}

# A scheme, an scp-style user@host:path, or a filesystem path. Anything else
# is a typo in the list rather than something to hand to git.
looks_like_git_url() {
  case "$1" in
    *://*|*@*:*|/*|./*|../*|*/*) return 0 ;;
  esac
  return 1
}

# --- main ------------------------------------------------------------------
info "list: $LIST_FILE  destination: $DEST_DIR"
debug "git: $(command -v git)"

cloned=0
skipped=0
failed=0
line_no=0
entries=0

# `|| [[ -n "$raw_line" ]]` keeps a last line with no trailing newline.
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line_no=$((line_no + 1))
  line="$(trim "${raw_line%$'\r'}")"

  case "$line" in
    ''|\#*)
      debug "$LIST_FILE:$line_no: blank or comment"
      continue
      ;;
  esac
  entries=$((entries + 1))

  # Split on whitespace with globbing off, so a * in a line stays literal.
  set -f
  # shellcheck disable=SC2086  # word splitting is the point
  set -- $line
  set +f
  url="${1:-}"
  dest_rel="${2:-}"
  if (( $# > 2 )); then
    err "$LIST_FILE:$line_no: too many fields; expected a URL and an optional destination"
    failed=$((failed + 1))
    continue
  fi

  if ! looks_like_git_url "$url"; then
    err "$LIST_FILE:$line_no: not a git URL or path: $url"
    failed=$((failed + 1))
    continue
  fi

  [[ -n "$dest_rel" ]] || dest_rel="$(repo_name_from_url "$url")"
  if [[ -z "$dest_rel" || "$dest_rel" == "-" ]]; then
    err "$LIST_FILE:$line_no: could not determine a destination for $url"
    failed=$((failed + 1))
    continue
  fi
  case "$dest_rel" in
    /*) dest_path="$dest_rel" ;;
    *)  dest_path="${DEST_DIR%/}/$dest_rel" ;;
  esac
  debug "$LIST_FILE:$line_no: $url -> $dest_path"

  if [[ -e "$dest_path" ]]; then
    if [[ -d "$dest_path/.git" || -f "$dest_path/.git" ]]; then
      ok "already cloned: $dest_path"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ -d "$dest_path" ]] && is_empty_dir "$dest_path"; then
      debug "reusing empty directory: $dest_path"
    else
      err "$LIST_FILE:$line_no: destination exists and is not a git checkout: $dest_path"
      failed=$((failed + 1))
      continue
    fi
  fi

  if (( DRY_RUN == 0 )); then
    parent="$(dirname "$dest_path")"
    if ! mkdir -p "$parent" || [[ ! -w "$parent" ]]; then
      err "$LIST_FILE:$line_no: cannot write to parent directory: $parent"
      failed=$((failed + 1))
      continue
    fi
    info "cloning $url -> $dest_path"
  fi

  if run git clone -- "$url" "$dest_path"; then
    cloned=$((cloned + 1))
    (( DRY_RUN )) || ok "cloned: $dest_path"
  else
    err "$LIST_FILE:$line_no: clone failed: $url -> $dest_path"
    if [[ -e "$dest_path" ]]; then
      warn "an incomplete clone may be left at $dest_path; remove it before retrying"
    fi
    failed=$((failed + 1))
  fi
done < "$LIST_FILE"

if (( entries == 0 )); then
  warn "no repository entries in $LIST_FILE"
  (( DRY_RUN )) && printf "dry-run complete; no changes written\n"
  exit 4
fi

if (( DRY_RUN == 1 )); then
  info "would clone $cloned, already present $skipped, failed $failed"
  printf "dry-run complete; no changes written\n"
else
  info "cloned $cloned, already present $skipped, failed $failed"
fi

(( failed == 0 )) || exit 1
exit 0

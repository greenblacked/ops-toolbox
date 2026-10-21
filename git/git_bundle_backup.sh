#!/usr/bin/env bash
# Write a verified, timestamped bundle of every ref in this repository.

set -euo pipefail

# --- output ----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''
fi

ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# --- defaults --------------------------------------------------------------
DRY_RUN=0
OUT_DIR="$HOME/git-bundles"
NAME=""
REFS=()
KEEP=""
YES=0

usage() {
  cat <<EOF
git_bundle_backup.sh - verified, timestamped offline backup of a repository

Writes one file holding every ref of the current repository -- branches, tags,
remote-tracking refs, the newest stash entry, recovery refs -- with
'git bundle create --all', proves it with 'git bundle verify', and only then
moves it into place, so a crash never leaves something that looks like a
backup and is not. Run it before a history rewrite, a host migration or
deleting a clone that holds the only copy of something, or on a schedule for a
repository with no remote.

The file is OUT/NAME-YYYYMMDDTHHMMSSZ.bundle (UTC). Restore with:

  git clone OUT/NAME-<stamp>.bundle NAME-restored

Usage:
  $(basename "$0") [--out DIR] [--name NAME] [--ref REF]... [--keep N] [--yes] [--dry-run]

Options:
  --out DIR     Where bundles go (default: ~/git-bundles)
  --name NAME   File name prefix (default: the repository directory's name);
                letters, digits, '.', '_' and '-' only
  --ref REF     Bundle only this ref (repeatable; default: every ref)
  --keep N      Keep the newest N bundles of NAME in DIR, this one included,
                and list the older ones; only NAME-<stamp>.bundle files are
                ever considered
  --yes         With --keep, delete the older bundles instead of listing them
  --dry-run     Show what would run; create, verify, move and delete nothing
  -h, --help    Show this help

A bundle carries the full history it contains, secrets that were ever committed
included, so keep it as carefully as the repository. Nothing is uploaded.

Exit codes: 0 success, 1 the bundle could not be created or verified, or would
overwrite a file, 2 not a git repo or DIR unusable, 3 usage, 4 nothing to back
up or a --ref not found
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

require_number() {
  local option="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      printf "%s requires a whole number, got: %s\n" "$option" "$value" >&2
      exit 3
      ;;
  esac
}

# --- arguments -------------------------------------------------------------
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out)
      require_value "$1" "${2:-}"; shift; OUT_DIR="$1" ;;
    --out=*)
      OUT_DIR="${1#*=}"; require_value "--out" "$OUT_DIR" ;;
    --name)
      require_value "$1" "${2:-}"; shift; NAME="$1" ;;
    --name=*)
      NAME="${1#*=}"; require_value "--name" "$NAME" ;;
    --ref)
      require_value "$1" "${2:-}"; shift; REFS+=("$1") ;;
    --ref=*)
      value="${1#*=}"; require_value "--ref" "$value"; REFS+=("$value") ;;
    --keep)
      require_value "$1" "${2:-}"; shift; require_number "--keep" "$1"; KEEP="$1" ;;
    --keep=*)
      KEEP="${1#*=}"; require_value "--keep" "$KEEP"; require_number "--keep" "$KEEP" ;;
    --yes)     YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if [[ -n "$KEEP" ]] && (( 10#$KEEP < 1 )); then
  # --keep 0 would delete the bundle this run has just written.
  printf -- "--keep must be 1 or more\n" >&2
  exit 3
fi
if (( YES == 1 )) && [[ -z "$KEEP" ]]; then
  printf -- "--yes only applies with --keep\n" >&2
  exit 3
fi
name_re='^[A-Za-z0-9._-]+$'
if [[ -n "$NAME" && ! "$NAME" =~ $name_re ]]; then
  printf -- "--name takes letters, digits, '.', '_' and '-', got: %s\n" "$NAME" >&2
  exit 3
fi

# --- preflight -------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if [[ -z "$NAME" ]]; then
  if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]]; then
    NAME="$(basename "$top")"
  else
    # A bare repository has no worktree; name it after its directory.
    git_dir="$(git rev-parse --absolute-git-dir)"
    NAME="$(basename "${git_dir%.git}")"
  fi
  if [[ ! "$NAME" =~ $name_re ]]; then
    printf "the repository directory name '%s' cannot be a file prefix; pass --name\n" "$NAME" >&2
    exit 3
  fi
fi

if [[ -z "$(git for-each-ref --count=1)" ]]; then
  printf "nothing to back up: this repository has no refs yet\n" >&2
  exit 4
fi

for ref in "${REFS[@]+"${REFS[@]}"}"; do
  if [[ "$ref" == -* ]] || ! git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    printf "ref not found: %s\n" "$ref" >&2
    exit 4
  fi
done

if [[ -e "$OUT_DIR" && ! -d "$OUT_DIR" ]]; then
  err "output exists and is not a directory: $OUT_DIR"
  exit 2
fi

# --- helpers ---------------------------------------------------------------
# %q so a path with a space is previewed as one argument, as in gacp.sh.
run() {
  if (( DRY_RUN == 1 )); then
    printf "dry-run: would run:"
    printf " %q" "$@"
    printf "\n"
  else
    "$@"
  fi
}

human_size() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) { printf "%.2f GB", b / 1073741824; exit }
    if (b >= 1048576)    { printf "%.1f MB", b / 1048576; exit }
    if (b >= 1024)       { printf "%.0f KB", b / 1024; exit }
    printf "%d B", b
  }'
}

# --- bundle ----------------------------------------------------------------
# The stamp sorts as text in time order, which is what retention relies on:
# no mtime, no stat(1), whose flags differ between BSD and GNU.
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
final="${OUT_DIR%/}/$NAME-$stamp.bundle"
partial="${OUT_DIR%/}/.$NAME-$stamp.bundle.partial"
if (( ${#REFS[@]} > 0 )); then
  what=("${REFS[@]}")
else
  what=(--all)
fi

if [[ -e "$final" ]]; then
  err "refusing to overwrite $final"
  exit 1
fi

if [[ ! -d "$OUT_DIR" ]]; then
  if ! run mkdir -p "$OUT_DIR"; then
    err "cannot create $OUT_DIR"
    exit 2
  fi
fi

# Written under a hidden name, verified, then renamed: within one directory the
# rename is atomic, so the final name only ever holds a verified bundle.
if ! run git bundle create "$partial" "${what[@]}"; then
  rm -f "$partial"
  err "git bundle create failed; nothing was written to $OUT_DIR"
  exit 1
fi
if (( DRY_RUN == 1 )); then
  run git bundle verify "$partial"
elif ! verify_out="$(git bundle verify "$partial" 2>&1)"; then
  rm -f "$partial"
  err "the new bundle did not verify, so it was removed:"
  printf '%s\n' "$verify_out" >&2
  exit 1
fi
if ! run mv "$partial" "$final"; then
  rm -f "$partial"
  err "could not move the verified bundle into place: $final"
  exit 1
fi

if (( DRY_RUN == 0 )); then
  bytes="$(wc -c <"$final" | tr -d ' ')"
  heads="$(git bundle list-heads "$final" | wc -l | tr -d ' ')"
  ok "bundle written and verified: $final"
  printf "  size: %s, %s ref(s)\n" "$(human_size "$bytes")" "$heads"
  printf "\nrestore with:\n"
  printf "  git bundle verify %s\n" "$final"
  printf "  git clone %s %s-restored\n" "$final" "$NAME"
fi

# --- retention -------------------------------------------------------------
# Only this script's own names for this NAME are candidates: the glob, then the
# exact shape again, so another repository's bundles and anything else in DIR
# are never listed, let alone deleted.
if [[ -n "$KEEP" ]]; then
  stamp_re='^[0-9]{8}T[0-9]{6}Z\.bundle$'
  listing=""
  for f in "${OUT_DIR%/}/$NAME"-????????T??????Z.bundle; do
    [[ -f "$f" ]] || continue
    base="${f##*/}"
    rest="${base#"$NAME"-}"
    [[ "$rest" =~ $stamp_re ]] || continue
    listing="$listing$base"$'\n'
  done
  # A dry run wrote nothing, but the bundle it describes still counts as the
  # newest one to keep.
  if (( DRY_RUN == 1 )); then
    listing="$listing${final##*/}"$'\n'
  fi

  total=0
  sorted=()
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    sorted+=("$base")
    total=$((total + 1))
  done < <(printf '%s' "$listing" | sort -u)

  prune=$((total - 10#$KEEP))
  i=0
  while (( i < prune )); do
    victim="${OUT_DIR%/}/${sorted[$i]}"
    i=$((i + 1))
    if (( DRY_RUN == 1 )); then
      run rm -- "$victim"
    elif (( YES == 1 )); then
      if rm -- "$victim"; then
        printf "pruned: %s\n" "$victim"
      else
        warn "could not delete $victim"
      fi
    else
      printf "would prune (pass --yes to delete): %s\n" "$victim"
    fi
  done
fi

if (( DRY_RUN == 1 )); then
  printf "dry-run complete; no changes written\n"
fi
exit 0

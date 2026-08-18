#!/usr/bin/env bash
# Move HEAD back one commit while keeping or discarding changes (safe undo).

set -euo pipefail

DRY_RUN=0
MODE="soft"
FORCE=0
REVERT=0
RESET_MODE_SET=0

usage() {
  cat <<EOF
git_undo_last_commit.sh - undo the last commit, keep changes in the tree

Default: git reset --soft HEAD~1 (commit undone; changes stay staged).

Usage:
  $(basename "$0") [--dry-run]
  $(basename "$0") --mixed
  $(basename "$0") --hard --force
  $(basename "$0") --revert

Options:
  --soft          Reset with index and working tree kept (default)
  --mixed         Reset with index unstaged, working tree kept
  --hard          Reset and discard working tree changes (requires --force)
  --revert        Create a new commit that reverses HEAD (safe for pushed work)
  --force         Required with --hard
  --dry-run       Print the git reset command without running it
  --help, -h      Show this help

Exit code 4 if there is no parent commit (e.g. single-commit repo after init).
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --soft)
      MODE="soft"
      RESET_MODE_SET=1
      ;;
    --mixed)
      MODE="mixed"
      RESET_MODE_SET=1
      ;;
    --hard)
      MODE="hard"
      RESET_MODE_SET=1
      ;;
    --force)
      FORCE=1
      ;;
    --revert)
      REVERT=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf "unknown argument: %s\n" "$1" >&2
      usage
      exit 3
      ;;
    *)
      printf "unknown argument: %s\n" "$1" >&2
      usage
      exit 3
      ;;
  esac
  shift
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if (( REVERT == 1 )); then
  if (( RESET_MODE_SET == 1 || FORCE == 1 )); then
    printf -- "--revert cannot be combined with reset modes or --force\n" >&2
    exit 3
  fi
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    printf "no commit to revert\n" >&2
    exit 4
  fi
  if [[ -n "$(git status --porcelain=v1)" ]]; then
    printf "working tree is not clean; commit or stash changes before --revert\n" >&2
    exit 4
  fi
  if (( DRY_RUN == 1 )); then
    printf "dry-run: would run: git revert --no-edit HEAD\n"
    exit 0
  fi
  git revert --no-edit HEAD
  printf "reverted last commit with a new history-preserving commit\n"
  exit 0
fi

if [[ "$MODE" == "hard" && "$FORCE" -ne 1 ]]; then
  printf -- "--hard requires --force (destructive: discards uncommitted work)\n" >&2
  exit 3
fi

if ! git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
  printf "no parent commit to reset to (repository may have only one commit)\n" >&2
  exit 4
fi

reset_arg="--soft"
if [[ "$MODE" == "mixed" ]]; then
  reset_arg="--mixed"
elif [[ "$MODE" == "hard" ]]; then
  reset_arg="--hard"
fi

if (( DRY_RUN == 1 )); then
  printf "dry-run: would run: git reset %s HEAD~1\n" "$reset_arg"
  exit 0
fi

git reset "$reset_arg" HEAD~1
printf "undid last commit (%s reset); changes: see git status\n" "$MODE"

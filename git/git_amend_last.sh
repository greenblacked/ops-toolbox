#!/usr/bin/env bash
# Amend the latest commit with staged changes and optionally replace its message.

set -euo pipefail

ADD_ALL=0
DRY_RUN=0
MESSAGE=""

usage() {
  cat <<EOF
git_amend_last.sh - amend the last commit's content and optionally its message

Optionally runs git add --all before amending (like folding unstaged work into
the previous commit).

Usage:
  $(basename "$0") [--add-all] [--message TEXT] [--dry-run]

Options:
  --add-all, -a   Run git add --all before amending
  --message TEXT  Replace the commit message instead of keeping it unchanged
  --dry-run       Show what would run without changing the repository
  --help, -h      Show this help

Requires something staged after optional --add-all, or amend would be a no-op.

Exit code 4 if nothing is staged to include in the amend.
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
    --add-all|-a)
      ADD_ALL=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --message|-m)
      require_value "$1" "${2:-}"
      shift
      MESSAGE="$1"
      ;;
    --message=*)
      MESSAGE="${1#*=}"
      require_value "--message" "$MESSAGE"
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

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  printf "no commits to amend\n" >&2
  exit 4
fi

if (( DRY_RUN == 1 )); then
  if (( ADD_ALL == 1 )); then
    printf "dry-run: would run: git add --all\n"
    if [[ -n "$MESSAGE" ]]; then
      printf "dry-run: would run: git commit --amend -m %q\n" "$MESSAGE"
    else
      printf "dry-run: would run: git commit --amend --no-edit\n"
    fi
    exit 0
  fi
  if git diff --cached --quiet && [[ -z "$MESSAGE" ]]; then
    printf "nothing staged to amend; use --add-all or stage files first\n" >&2
    exit 4
  fi
  if [[ -n "$MESSAGE" ]]; then
    printf "dry-run: would run: git commit --amend -m %q\n" "$MESSAGE"
  else
    printf "dry-run: would run: git commit --amend --no-edit\n"
  fi
  exit 0
fi

if (( ADD_ALL == 1 )); then
  git add --all
fi

if git diff --cached --quiet && [[ -z "$MESSAGE" ]]; then
  printf "nothing staged to amend; use --add-all or stage files first\n" >&2
  exit 4
fi

if [[ -n "$MESSAGE" ]]; then
  git commit --amend -m "$MESSAGE"
  printf "amended last commit (message updated)\n"
else
  git commit --amend --no-edit
  printf "amended last commit (message unchanged)\n"
fi

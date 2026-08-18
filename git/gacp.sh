#!/usr/bin/env bash
# Stage all changes, commit with a message, and push.

set -euo pipefail

DRY_RUN=0
PUSH=1
STAGED_ONLY=0
REMOTE="origin"
BRANCH=""
MESSAGE=""

usage() {
  cat <<EOF
gacp.sh - git add --all, commit, and push

Usage:
  $(basename "$0") "commit message"
  $(basename "$0") -m "commit message"
  $(basename "$0") --dry-run -m "commit message"

Options:
  -m, --message TEXT  Commit message
  --dry-run           Show commands without changing the repository
  --no-push           Commit but do not push
  --staged-only       Commit only files already staged; do not run git add --all
  --remote NAME       Remote to push to when no upstream exists (default: origin)
  --branch NAME       Branch to push when no upstream exists (default: current branch)
  --help, -h          Show this help

Exit codes: 0 success, 2 not a git repo, 3 usage, 4 nothing to commit, 5 push from detached HEAD
EOF
}

quote_arg() {
  printf "%q" "$1"
}

print_cmd() {
  local first=1
  printf "dry-run: would run:"
  for arg in "$@"; do
    if (( first == 1 )); then
      printf " %s" "$(quote_arg "$arg")"
      first=0
    else
      printf " %s" "$(quote_arg "$arg")"
    fi
  done
  printf "\n"
}

run() {
  if (( DRY_RUN == 1 )); then
    print_cmd "$@"
  else
    "$@"
  fi
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
    -m|--message)
      require_value "$1" "${2:-}"
      shift
      MESSAGE="$1"
      ;;
    --message=*)
      MESSAGE="${1#*=}"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --no-push)
      PUSH=0
      ;;
    --staged-only)
      STAGED_ONLY=1
      ;;
    --remote)
      require_value "$1" "${2:-}"
      shift
      REMOTE="$1"
      ;;
    --remote=*)
      REMOTE="${1#*=}"
      ;;
    --branch)
      require_value "$1" "${2:-}"
      shift
      BRANCH="$1"
      ;;
    --branch=*)
      BRANCH="${1#*=}"
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
      if [[ -n "$MESSAGE" ]]; then
        MESSAGE="$MESSAGE $1"
      else
        MESSAGE="$1"
      fi
      ;;
  esac
  shift
done

if [[ -z "$MESSAGE" ]]; then
  printf "commit message is required\n" >&2
  usage
  exit 3
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if (( STAGED_ONLY == 1 )); then
  if git diff --cached --quiet; then
    printf "nothing staged to commit\n"
    exit 4
  fi
elif [[ -z "$(git status --porcelain=v1)" ]]; then
  printf "nothing to commit\n"
  exit 4
fi

current_branch="$(git branch --show-current)"
if [[ -z "$current_branch" && "$PUSH" -eq 1 ]]; then
  printf "cannot push from detached HEAD; pass --no-push or switch to a branch\n" >&2
  exit 5
fi
if [[ -z "$BRANCH" ]]; then
  BRANCH="$current_branch"
fi

if (( STAGED_ONLY == 0 )); then
  run git add --all
fi
run git commit -m "$MESSAGE"

if (( PUSH == 1 )); then
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    run git push
  else
    run git push -u "$REMOTE" "$BRANCH"
  fi
fi

if (( DRY_RUN == 1 )); then
  printf "dry-run complete; no changes written\n"
elif (( PUSH == 1 )); then
  printf "committed and pushed: %s\n" "$MESSAGE"
else
  printf "committed without push: %s\n" "$MESSAGE"
fi

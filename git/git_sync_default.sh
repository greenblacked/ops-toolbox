#!/usr/bin/env bash
# Fetch and fast-forward the repository's default branch.

set -euo pipefail

DRY_RUN=0
REMOTE="origin"
BRANCH=""
RESTORE=0

usage() {
  cat <<EOF
git_sync_default.sh - fetch and fast-forward the default branch

Usage:
  $(basename "$0") [--dry-run] [--restore] [--remote origin] [--branch main]

Options:
  --dry-run        Show commands without changing the repository
  --remote NAME    Remote to fetch from (default: origin)
  --branch NAME    Branch to sync (default: remote HEAD, main, or master)
  --restore        Return to the originally checked-out branch after syncing
  --help, -h       Show this help
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
    --dry-run)
      DRY_RUN=1
      ;;
    --restore)
      RESTORE=1
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

if [[ -z "$BRANCH" ]]; then
  remote_head="$(git symbolic-ref --quiet --short "refs/remotes/${REMOTE}/HEAD" 2>/dev/null || true)"
  if [[ -n "$remote_head" ]]; then
    BRANCH="${remote_head#${REMOTE}/}"
  elif git show-ref --verify --quiet "refs/remotes/${REMOTE}/main" || git show-ref --verify --quiet "refs/heads/main"; then
    BRANCH="main"
  elif git show-ref --verify --quiet "refs/remotes/${REMOTE}/master" || git show-ref --verify --quiet "refs/heads/master"; then
    BRANCH="master"
  else
    printf "could not determine default branch; pass --branch\n" >&2
    exit 4
  fi
fi

if [[ -n "$(git status --porcelain=v1)" ]]; then
  printf "working tree is not clean; commit or stash changes first\n" >&2
  exit 4
fi

current_branch="$(git branch --show-current)"
original_head="$(git rev-parse HEAD)"
RESTORE_PENDING=0

restore_original_checkout() {
  local rc=$?
  trap - EXIT
  if (( RESTORE_PENDING == 1 )); then
    if [[ -n "$current_branch" ]]; then
      if git switch "$current_branch"; then
        printf "restored %s\n" "$current_branch"
      else
        printf "could not restore original branch: %s\n" "$current_branch" >&2
        rc=1
      fi
    else
      if git switch --detach "$original_head"; then
        printf "restored detached HEAD at %s\n" "${original_head:0:12}"
      else
        printf "could not restore detached HEAD at %s\n" "${original_head:0:12}" >&2
        rc=1
      fi
    fi
  fi
  exit "$rc"
}

run() {
  if (( DRY_RUN == 1 )); then
    printf "dry-run: would run: %s\n" "$*"
  else
    "$@"
  fi
}

run git fetch "$REMOTE" "$BRANCH"

if [[ "$current_branch" != "$BRANCH" ]]; then
  run git switch "$BRANCH"
  if (( RESTORE == 1 && DRY_RUN == 0 )); then
    RESTORE_PENDING=1
    trap restore_original_checkout EXIT
  fi
fi

if git show-ref --verify --quiet "refs/remotes/${REMOTE}/${BRANCH}"; then
  run git merge --ff-only "${REMOTE}/${BRANCH}"
else
  printf "remote branch not found after fetch: %s/%s\n" "$REMOTE" "$BRANCH" >&2
  exit 4
fi

if (( RESTORE == 1 && DRY_RUN == 1 )) && [[ "$current_branch" != "$BRANCH" ]]; then
  if [[ -n "$current_branch" ]]; then
    run git switch "$current_branch"
  else
    run git switch --detach "$original_head"
  fi
fi

if (( DRY_RUN == 1 )); then
  printf "dry-run complete; no changes written\n"
else
  printf "synced %s with %s/%s\n" "$BRANCH" "$REMOTE" "$BRANCH"
fi

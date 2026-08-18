#!/usr/bin/env bash
# Delete local branches that are already merged into the base branch.

set -euo pipefail

DRY_RUN=0
BASE=""
FORCE=0
INCLUDES=()
EXCLUDES=()

usage() {
  cat <<EOF
git_cleanup_merged.sh - delete local branches merged into a base branch

Usage:
  $(basename "$0") [--dry-run] [--base main] [--include GLOB] [--exclude GLOB] [--force]

Options:
  --dry-run       Show branches that would be deleted
  --base BRANCH   Base branch to compare against (default: current branch)
  --include GLOB  Only consider matching branches (repeatable)
  --exclude GLOB  Skip matching branches (repeatable)
  --force         Also delete protected-looking names such as develop
  --help, -h      Show this help
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
    --base)
      require_value "$1" "${2:-}"
      shift
      BASE="$1"
      ;;
    --base=*)
      BASE="${1#*=}"
      ;;
    --force)
      FORCE=1
      ;;
    --include)
      require_value "$1" "${2:-}"
      shift
      INCLUDES+=("$1")
      ;;
    --include=*)
      value="${1#*=}"
      require_value "--include" "$value"
      INCLUDES+=("$value")
      ;;
    --exclude)
      require_value "$1" "${2:-}"
      shift
      EXCLUDES+=("$1")
      ;;
    --exclude=*)
      value="${1#*=}"
      require_value "--exclude" "$value"
      EXCLUDES+=("$value")
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

if [[ -z "$BASE" ]]; then
  BASE="$(git branch --show-current)"
fi
if [[ -z "$BASE" ]]; then
  printf "cannot determine base branch; pass --base\n" >&2
  exit 4
fi
if ! git show-ref --verify --quiet "refs/heads/${BASE}"; then
  printf "base branch not found: %s\n" "$BASE" >&2
  exit 4
fi

current_branch="$(git branch --show-current)"
protected_regex='^(main|master|develop|development|dev|staging|stage|production|prod|release)$'
candidates=0
removed=0
failed=0

branch_selected() {
  local branch="$1" pattern matched
  matched=0
  if (( ${#INCLUDES[@]} == 0 )); then
    matched=1
  else
    for pattern in ${INCLUDES[@]+"${INCLUDES[@]}"}; do
      [[ "$branch" == $pattern ]] && { matched=1; break; }
    done
  fi
  (( matched == 1 )) || return 1
  for pattern in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    [[ "$branch" == $pattern ]] && return 1
  done
  return 0
}

while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  [[ "$branch" != "$BASE" ]] || continue
  [[ "$branch" != "$current_branch" ]] || continue
  branch_selected "$branch" || continue

  if (( FORCE == 0 )) && [[ "$branch" =~ $protected_regex ]]; then
    printf "skip protected branch: %s\n" "$branch"
    continue
  fi

  candidates=$((candidates + 1))
  if (( DRY_RUN == 1 )); then
    printf "dry-run: would delete branch: %s\n" "$branch"
  else
    if git branch -d "$branch"; then
      removed=$((removed + 1))
    else
      printf "warn: could not delete branch: %s\n" "$branch" >&2
      failed=$((failed + 1))
    fi
  fi
done < <(git branch --merged "$BASE" --format='%(refname:short)')

if (( candidates == 0 )); then
  printf "no merged local branches to delete\n"
elif (( DRY_RUN == 1 )); then
  printf "dry-run complete; no branches deleted\n"
else
  if (( removed > 0 )); then
    printf "deleted %s merged local branch(es)\n" "$removed"
  fi
  if (( failed > 0 )); then
    printf "warning: failed to delete %s branch(es)\n" "$failed" >&2
    exit 1
  fi
fi

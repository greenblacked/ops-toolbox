#!/usr/bin/env bash
# Show diff between the merge-base of a base branch and HEAD (what your branch adds).

set -euo pipefail

BASE=""
MODE="stat"
WORKING_TREE=0

usage() {
  cat <<EOF
git_diff_branch.sh - diff your work since diverging from a base branch

Compares merge-base(BASE, HEAD)..HEAD so you see commits and changes unique to
the current branch, not unrelated updates on BASE.

Usage:
  $(basename "$0") [--base main] [--stat|--patch] [--working-tree]
  $(basename "$0") --base main --patch

Options:
  --base BRANCH   Branch to compare against (default: main, else master)
  --stat          Show diffstat only (default)
  --patch         Full patch diff (-p)
  --working-tree  Include staged and unstaged tracked changes after HEAD
  --help, -h      Show this help

Exit code 4 if neither main nor master exists locally and --base was not given.
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
    --base)
      require_value "$1" "${2:-}"
      shift
      BASE="$1"
      ;;
    --base=*)
      BASE="${1#*=}"
      ;;
    --stat)
      MODE="stat"
      ;;
    --patch|-p)
      MODE="patch"
      ;;
    --working-tree)
      WORKING_TREE=1
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

if [[ -z "$BASE" ]]; then
  if git show-ref --verify --quiet refs/heads/main; then
    BASE="main"
  elif git show-ref --verify --quiet refs/heads/master; then
    BASE="master"
  else
    printf "could not infer base branch; pass --base\n" >&2
    exit 4
  fi
fi

if ! git show-ref --verify --quiet "refs/heads/${BASE}"; then
  printf "base branch not found locally: %s\n" "$BASE" >&2
  exit 4
fi

merge_base="$(git merge-base "$BASE" HEAD)"

range="$merge_base..HEAD"
if (( WORKING_TREE == 1 )); then
  range="$merge_base"
fi

if [[ "$MODE" == "stat" ]]; then
  git diff --stat "$range"
else
  git diff "$range"
fi

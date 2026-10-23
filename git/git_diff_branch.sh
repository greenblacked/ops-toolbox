#!/usr/bin/env bash
# Show diff between the merge-base of a base branch and HEAD (what your branch adds).

set -euo pipefail

BASE=""
MODE="stat"
WORKING_TREE=0
PATHS=()
REQUIRE_CHANGES=0

usage() {
  cat <<EOF
git_diff_branch.sh - diff your work since diverging from a base branch

Compares merge-base(BASE, HEAD)..HEAD so you see commits and changes unique to
the current branch, not unrelated updates on BASE.

Usage:
  $(basename "$0") [--base main] [--stat|--patch|--name-only|--name-status]
                     [--path PATHSPEC]... [--require-changes] [--working-tree]
  $(basename "$0") --base main --patch
  $(basename "$0") --base origin/main --name-only --path k8s/ --require-changes

Options:
  --base BRANCH      Branch to compare against: a local branch, or a
                     remote-tracking one such as origin/main (default: main,
                     else master)
  --stat             Show diffstat only (default)
  --patch            Full patch diff (-p)
  --name-only        Only the changed paths, one per line
  --name-status      Status letter (A, M, D, R...) and path, tab-separated
  --path PATHSPEC    Limit every mode to this pathspec (repeatable): a
                     directory such as k8s/, or git's own forms such as
                     ':(glob)**/*.yaml'
  --require-changes  Exit 4 when nothing changed (under the --path filter)
  --working-tree     Include staged and unstaged tracked changes after HEAD
  --help, -h         Show this help

Exit code 4 if neither main nor master exists locally and --base was not given,
if the base is neither a local nor a remote-tracking branch, or with
--require-changes when there is nothing to show.
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
    --name-only)
      MODE="names"
      ;;
    --name-status)
      MODE="name-status"
      ;;
    --path)
      require_value "$1" "${2:-}"
      shift
      PATHS+=("$1")
      ;;
    --path=*)
      value="${1#*=}"
      require_value "--path" "$value"
      PATHS+=("$value")
      ;;
    --require-changes)
      REQUIRE_CHANGES=1
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

# A local branch first, as before; a remote-tracking one second, because a
# fresh CI checkout has origin/main and no local main at all. The full ref
# name is what gets used, so a branch and a tag of the same name cannot be
# confused.
if git show-ref --verify --quiet "refs/heads/${BASE}"; then
  base_ref="refs/heads/${BASE}"
elif git show-ref --verify --quiet "refs/remotes/${BASE}"; then
  base_ref="refs/remotes/${BASE}"
else
  printf "base branch not found locally or as a remote-tracking ref: %s\n" "$BASE" >&2
  exit 4
fi

merge_base="$(git merge-base "$base_ref" HEAD)"

range="$merge_base..HEAD"
if (( WORKING_TREE == 1 )); then
  range="$merge_base"
fi

# Pathspecs go after --, so one can never be read as an option, and git
# applies its own pathspec rules to them.
if (( REQUIRE_CHANGES == 1 )); then
  changed="$(git diff --name-only "$range" -- ${PATHS[@]+"${PATHS[@]}"})"
  if [[ -z "$changed" ]]; then
    printf "no changes in %s\n" "$range" >&2
    exit 4
  fi
fi

case "$MODE" in
  stat)        git diff --stat "$range" -- ${PATHS[@]+"${PATHS[@]}"} ;;
  names)       git diff --name-only "$range" -- ${PATHS[@]+"${PATHS[@]}"} ;;
  name-status) git diff --name-status "$range" -- ${PATHS[@]+"${PATHS[@]}"} ;;
  *)           git diff "$range" -- ${PATHS[@]+"${PATHS[@]}"} ;;
esac

#!/usr/bin/env bash
# List recent local branches, optionally switch to one by rank.

set -euo pipefail

LIMIT=12
SWITCH_TO=""
NAMES_ONLY=0

usage() {
  cat <<EOF
git_recent_branches.sh - list or switch to recently updated local branches

Usage:
  $(basename "$0") [--limit 12]
  $(basename "$0") --switch 2

Options:
  --limit N     Number of branches to show (default: 12)
  --switch N    Switch to the Nth branch in the recent list
  --names-only  Print only branch names, one per line (for automation)
  --help, -h    Show this help
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
    --limit)
      require_value "$1" "${2:-}"
      shift
      LIMIT="$1"
      ;;
    --limit=*)
      LIMIT="${1#*=}"
      ;;
    --switch)
      require_value "$1" "${2:-}"
      shift
      SWITCH_TO="$1"
      ;;
    --switch=*)
      SWITCH_TO="${1#*=}"
      ;;
    --names-only)
      NAMES_ONLY=1
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

if [[ ! "$LIMIT" =~ ^[0-9]+$ || "$LIMIT" -lt 1 ]]; then
  printf -- "--limit must be a positive integer\n" >&2
  exit 3
fi
if [[ -n "$SWITCH_TO" ]] && [[ ! "$SWITCH_TO" =~ ^[0-9]+$ || "$SWITCH_TO" -lt 1 ]]; then
  printf -- "--switch must be a positive integer\n" >&2
  exit 3
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

# Build the list without mapfile so this script runs on Bash 3.2 (macOS stock /bin/bash).
branches=()
count=0
while IFS= read -r line && (( count < LIMIT )); do
  [[ -n "$line" ]] || continue
  branches+=("$line")
  count=$((count + 1))
done < <(git for-each-ref \
  --sort=-committerdate \
  --format='%(refname:short)%09%(committerdate:relative)%09%(subject)' \
  refs/heads)

if (( ${#branches[@]} == 0 )); then
  printf "no local branches found\n"
  exit 0
fi

if [[ -n "$SWITCH_TO" ]]; then
  if (( SWITCH_TO > ${#branches[@]} )); then
    printf -- "--switch index out of range: %s\n" "$SWITCH_TO" >&2
    exit 4
  fi
  selected="${branches[$((SWITCH_TO - 1))]}"
  branch="${selected%%$'\t'*}"
  git switch -q "$branch"
  printf "switched to %s\n" "$branch"
  exit 0
fi

if (( NAMES_ONLY == 1 )); then
  for entry in "${branches[@]}"; do
    printf "%s\n" "${entry%%$'\t'*}"
  done
  exit 0
fi

printf "Recent local branches:\n"
i=1
for entry in "${branches[@]}"; do
  branch="${entry%%$'\t'*}"
  rest="${entry#*$'\t'}"
  when="${rest%%$'\t'*}"
  subject="${rest#*$'\t'}"
  printf "  %2d. %-28s %-18s %s\n" "$i" "$branch" "$when" "$subject"
  i=$((i + 1))
done

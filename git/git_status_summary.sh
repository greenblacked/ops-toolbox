#!/usr/bin/env bash
# Print a compact status summary for the current Git repository.

set -euo pipefail

usage() {
  cat <<EOF
git_status_summary.sh - compact repository status

Usage:
  $(basename "$0") [--porcelain] [--help]

Options:
  --porcelain  Stable tab-separated key/value lines for automation
EOF
}

PORCELAIN=0
while (( $# > 0 )); do
  case "$1" in
    --porcelain) PORCELAIN=1 ;;
    --help|-h) usage; exit 0 ;;
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

branch="$(git branch --show-current)"
head_sha="$(git rev-parse --short HEAD)"
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
changed_count="$(git status --porcelain=v1 | wc -l | tr -d ' ')"
staged_count="$(git diff --cached --name-only | wc -l | tr -d ' ')"
unstaged_count="$(git diff --name-only | wc -l | tr -d ' ')"
untracked_count="$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')"

ahead=0
behind=0
if [[ -n "$upstream" ]]; then
  counts="$(git rev-list --left-right --count "${upstream}...HEAD")"
  behind="${counts%%	*}"
  ahead="${counts##*	}"
fi

if (( PORCELAIN == 1 )); then
  printf "branch\t%s\n" "${branch:-detached HEAD}"
  printf "head\t%s\n" "$head_sha"
  printf "upstream\t%s\n" "${upstream:-}"
  printf "ahead\t%s\n" "$ahead"
  printf "behind\t%s\n" "$behind"
  printf "changed\t%s\n" "$changed_count"
  printf "staged\t%s\n" "$staged_count"
  printf "unstaged\t%s\n" "$unstaged_count"
  printf "untracked\t%s\n" "$untracked_count"
else
  printf "Repository status:\n"
  printf "  branch:    %s\n" "${branch:-detached HEAD}"
  printf "  head:      %s\n" "$head_sha"
  printf "  upstream:  %s\n" "${upstream:-<none>}"
  printf "  ahead:     %s\n" "$ahead"
  printf "  behind:    %s\n" "$behind"
  printf "  changed:   %s\n" "$changed_count"
  printf "  staged:    %s\n" "$staged_count"
  printf "  unstaged:  %s\n" "$unstaged_count"
  printf "  untracked: %s\n" "$untracked_count"
fi

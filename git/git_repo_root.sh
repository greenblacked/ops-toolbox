#!/usr/bin/env bash
# Print the absolute path to the current Git repository root.

set -euo pipefail

usage() {
  cat <<EOF
git_repo_root.sh - print the repository root directory

Usage:
  $(basename "$0") [--git-dir] [--help]

Output is a single line: the absolute path from git rev-parse --show-toplevel.
Use in shell: cd "\$($(basename "$0"))"

Options:
  --git-dir   Print the absolute Git metadata directory instead of the worktree root
EOF
}

MODE="root"
while (( $# > 0 )); do
  case "$1" in
    --git-dir) MODE="git-dir" ;;
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

if [[ "$MODE" == "git-dir" ]]; then
  git rev-parse --absolute-git-dir
else
  git rev-parse --show-toplevel
fi

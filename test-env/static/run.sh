#!/usr/bin/env bash
# Run the repository-wide static convention checks.
#
# Needs nothing but bash and git — no Docker, no network, no Python. That is
# deliberate: these checks should still run on a machine where the Docker
# suites cannot.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
export REPO_ROOT

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$REPO_ROOT is not a git working tree; these checks read the index" >&2
  exit 1
fi

exec "$HERE/check_conventions.sh"

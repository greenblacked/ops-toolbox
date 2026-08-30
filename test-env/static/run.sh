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

rc=0

"$HERE/check_conventions.sh" || rc=1

# Behavioural checks that need no Docker live with the code they test, but are
# run from here so they reach the pull-request path. The mikrotik suite needs a
# CHR image under QEMU, so anything wired only into it runs nightly at best —
# and the exit-code contract below guards a silent-backup-failure bug that
# should be caught before merge, not the next morning.
printf '\n--- pull_router_backups.sh exit codes ---\n'
"$REPO_ROOT/mikrotik/tests/test_pull_router_backups.sh" || rc=1

printf '\n--- RouterOS script conventions ---\n'
"$REPO_ROOT/mikrotik/tests/test_lua_conventions.sh" || rc=1

printf '\n--- run-tests.sh automation contract ---\n'
"$HERE/test_run_tests.sh" || rc=1

printf '\n--- documentation citations ---\n'
"$HERE/test_doc_citations.sh" || rc=1

exit "$rc"

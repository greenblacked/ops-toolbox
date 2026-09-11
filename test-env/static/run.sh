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

# This runner invokes scripts that read the environment, so it has to pin what
# they read for the same reason the suites it calls do. CHANGELOG_ROOT is the
# live one: changelog.sh takes it as the directory holding CHANGELOG.md and
# changelog.d/, so a developer with it exported had this runner validate some
# other checkout's fragments and report "1 fragment(s) would paste cleanly"
# about files that are not in this repository -- a fully green static suite
# that checked nothing here. check_conventions.sh unsets it too, but that is a
# child process and the unset never reaches this one.
# PIN_MAX_AGE_DAYS is check_pin_age.sh's threshold, and it is the whole gate:
# exported by a developer or a runner, it silently changes what "too old"
# means and the check still prints [ ok ] for every file. Same reasoning as
# CHANGELOG_ROOT above — a runner must not be aimed by the shell that starts it.
unset CHANGELOG_ROOT PIN_MAX_AGE_DAYS

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

# One file per change under changelog.d/ is what keeps two pull requests from
# editing the same line of CHANGELOG.md; a fragment that would not paste is
# caught here, before it is the release that finds out.
printf '\n--- pin age ---\n'
"$HERE/check_pin_age.sh" || rc=1

printf '\n--- changelog fragments ---\n'
"$REPO_ROOT/changelog.d/changelog.sh" check || rc=1
"$HERE/test_changelog.sh" || rc=1

exit "$rc"

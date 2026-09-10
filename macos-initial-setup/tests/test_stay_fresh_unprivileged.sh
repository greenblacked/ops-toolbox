#!/usr/bin/env bash
# Permission-denied paths in stay_fresh.sh, run as a non-root user inside the
# tester container.
#
# Everything else in this directory runs as root, where almost nothing is
# forbidden: a root process can create any directory and delete any file, so the
# EACCES branches are unreachable and were previously asserted only by
# construction. This suite runs as uid 1000 against directories the image
# deliberately left root-owned, which is the only way to make open(2) and
# unlink(2) actually refuse.
set -uo pipefail

if [[ "$(uname -s)" != "Linux" || ! -f /.dockerenv ]]; then
  echo "refusing to run: container-only" >&2
  exit 1
fi
if [[ "$(id -u)" == "0" ]]; then
  echo "this suite must run as a non-root user; got uid 0" >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-/repo}"
M="$REPO_ROOT/macos-initial-setup"
SF="$M/stay_fresh.sh"

# stay_fresh.sh reads these from the environment to locate somebody else's cache
# or to reach a notifier, and a developer's shell — or this container — often
# has them set. Inherited, they aim the run at a real cache or a real webhook:
# an exported BUN_INSTALL once satisfied a relocation assertion from ~/.bun, so
# the test passed here and failed in CI. Every test that needs one of these
# supplies it itself; start from an environment holding none of them.
unset BUN_INSTALL CLOUDSDK_CONFIG TF_PLUGIN_CACHE_DIR UV_CACHE_DIR
unset STAY_FRESH_LOCK_DIR STAY_FRESH_NOTIFY STAY_FRESH_NOTIFY_TIMEOUT \
  STAY_FRESH_NOTIFY_WHEN STAY_FRESH_SLACK_WEBHOOK STAY_FRESH_STEP_TIMEOUT \
  STAY_FRESH_TG_BOT_TOKEN STAY_FRESH_TG_CHAT_ID

failures=0
ok()  { echo "[ ok ] $*"; }
err() { echo "[fail] $*" >&2; failures=$((failures + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then ok "$label"
  else err "$label (expected '$expected', got '$actual')"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$label"
  else err "$label (missing '$needle')"; printf '%s\n' "$haystack" | tail -20 >&2; fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    err "$label (unexpected '$needle')"; printf '%s\n' "$haystack" | tail -20 >&2
  else ok "$label"; fi
}
assert_called() {
  local label="$1" calls="$2" needle="$3"
  if grep -qF -- "$needle" "$calls" 2>/dev/null; then ok "$label"
  else err "$label (no '$needle' in recorded calls)"; tail -15 "$calls" >&2 2>/dev/null; fi
}
assert_not_called() {
  local label="$1" calls="$2" needle="$3"
  if grep -qF -- "$needle" "$calls" 2>/dev/null; then
    err "$label (unexpected '$needle')"; tail -15 "$calls" >&2 2>/dev/null
  else ok "$label"; fi
}

mkbin() {
  local path="$1"; shift
  { echo '#!/bin/sh'; printf '%s\n' "$@"; } > "$path"
  chmod +x "$path"
}

d="$(mktemp -d)"
mkdir -p "$d/bin" "$d/home" "$d/tmp"
mkbin "$d/bin/uname" 'case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac'
mkbin "$d/bin/id"    'case "${1:-}" in -u) echo 501 ;; -un) echo tester ;; *) /usr/bin/id "$@" ;; esac'
mkbin "$d/bin/sw_vers" 'case "${1:-}" in -productVersion) echo 15.0 ;; -buildVersion) echo TESTBUILD ;; esac'
mkbin "$d/bin/df" 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"' \
                  'echo "/dev/test 1000000 200000 800000 20% /"'
mkbin "$d/bin/pgrep" 'exit 1'
mkbin "$d/bin/xcode-select" 'exit 0'
# sudo is absent from the image. This one reports a warm credential and then
# runs the command as the same unprivileged user, which is the point: the
# retry must be aimed at the right entry whether or not it then succeeds.
mkbin "$d/bin/sudo" 'case "${1:-}" in' \
                    '  -v) exit 0 ;;' \
                    '  -n) shift; case "${1:-}" in true) exit 0 ;; esac ;;' \
                    'esac' \
                    'echo "sudo $*" >> "$CALLS"' \
                    'exec "$@"'

run_sf() {
  local tmp="$1"; shift
  HOME="$d/home" TMPDIR="$tmp" PATH="$d/bin:/usr/bin:/bin" NO_COLOR=1 CALLS="$d/calls" \
    "$SF" "$@" </dev/null 2>&1
}

echo "--- run lock under EACCES ---"
# The lock lives under HOME (STAY_FRESH_LOCK_DIR is the test seam), not
# TMPDIR: the LaunchAgent environment carries only PATH, so a TMPDIR lock
# split into two different directories between agent and terminal runs.
# /rootonly is mode 700 and owned by root, so `mkdir -p` of anything beneath
# it fails outright. The run must say it could not create the directory, not
# blame a lock.
out="$(STAY_FRESH_LOCK_DIR=/rootonly/scratch \
  run_sf "$d/tmp" --yes --no-sudo --only versions)"; rc=$?
assert_eq "an uncreatable lock dir fails preflight -> 2" "2" "$rc"
assert_contains "an uncreatable lock dir is named" "$out" "to hold the run lock"
assert_not_contains "an uncreatable lock dir is not blamed on a stale lock" "$out" \
  "stale stay_fresh lock"

# /rootlocked exists and is traversable but not writable by us, so `mkdir -p`
# succeeds (it is already there) and the lock mkdir is the call that gets EACCES.
# This is the branch that distinguishes "someone else holds the lock" from "we
# cannot create one": before, any mkdir failure was read as contention and the
# recovery path announced a stale lock that never existed.
out="$(STAY_FRESH_LOCK_DIR=/rootlocked \
  run_sf "$d/tmp" --yes --no-sudo --only versions)"; rc=$?
assert_eq "an unwritable lock dir fails preflight -> 2" "2" "$rc"
assert_contains "an unwritable lock dir reports the lock it could not take" "$out" \
  "cannot acquire run lock"
assert_not_contains "an unwritable lock dir is not blamed on a stale lock" "$out" \
  "stale stay_fresh lock"

# An unusable TMPDIR is not a reason to refuse the run: the full disk this
# script is run for is where TMPDIR lives. The log moves to the state
# directory under HOME and the run says so; the scratch lists the sweeps
# need move with it, so a step that lists before it deletes still works.
L="$d/home/Library/Logs"
mkdir -p "$L/Homebrew"
printf 'old\n' > "$L/Homebrew/old.log"; touch -d '40 days ago' "$L/Homebrew/old.log"
out="$(run_sf /rootonly/scratch --yes --no-sudo --only versions,user-logs)"; rc=$?
assert_eq "an uncreatable TMPDIR does not refuse the run" "0" "$rc"
assert_contains "the log falls back to the state directory and says so" "$out" \
  "cannot write the log under /rootonly/scratch; logging to $d/home/Library/Logs/stay_fresh instead"
assert_not_contains "an uncreatable TMPDIR does not implicate the lock" "$out" \
  "run lock"
if [[ ! -e "$L/Homebrew/old.log" ]]; then
  ok "a sweep that needs a scratch list still runs with TMPDIR unusable"
else
  err "the scratch list did not fall back with the log"
fi
assert_contains "the run is clean despite the fallback" "$out" "warn steps:  0"
out="$(run_sf /rootonly/scratch --yes --no-sudo --only versions)"; rc=$?
assert_eq "the lock is released after a run that used the fallback log" "0" "$rc"
assert_not_contains "no stale lock is left behind" "$out" "stale stay_fresh lock"

# Neither TMPDIR nor the state directory writable: the run goes ahead
# without a log, says so, and still does its work.
rm -rf "$d/home/Library/Logs/stay_fresh"
chmod 555 "$L"
out="$(run_sf /rootonly/scratch --yes --no-sudo --only versions)"; rc=$?
assert_eq "no writable log location at all still runs" "0" "$rc"
assert_contains "the missing log is said" "$out" \
  "running without one; command output will not be kept"
assert_contains "the run still reaches its verdict" "$out" "stay_fresh"
assert_contains "the step still ran" "$out" "Active tool versions done"
assert_not_contains "no error about removing the missing log" "$out" "/dev/null"
chmod 755 "$L"

echo "--- cache deletion that the filesystem refuses ---"
# A cache entry inside a directory we may not write: rm(1) can unlink neither the
# child nor, therefore, the parent. The step must keep the data, say so, and be
# accounted a warning rather than a clean success.
mkdir -p "$d/home/Library/Caches/protected"
printf 'irreplaceable\n' > "$d/home/Library/Caches/protected/data"
mkdir -p "$d/home/Library/Caches/disposable"
printf 'junk\n' > "$d/home/Library/Caches/disposable/data"
chmod 555 "$d/home/Library/Caches/protected"

: > "$d/calls"
out="$(run_sf "$d/tmp" --yes --no-sudo --only user-caches)"; rc=$?
assert_eq "an undeletable cache entry does not fail the run" "0" "$rc"
assert_contains "an undeletable cache entry is reported" "$out" "could not fully clear"
assert_contains "an undeletable cache entry is accounted a warning" "$out" "warn steps:  1"
if [[ -f "$d/home/Library/Caches/protected/data" ]]; then
  ok "an undeletable cache entry survives"
else
  err "an undeletable cache entry was removed"
fi
if [[ ! -e "$d/home/Library/Caches/disposable" ]]; then
  ok "a deletable neighbour is still cleared"
else
  err "one undeletable entry stopped the rest of the sweep"
fi
if [[ ! -s "$d/calls" ]]; then
  ok "--no-sudo never reaches for sudo"
else
  err "--no-sudo ran sudo"; cat "$d/calls" >&2
fi

# With sudo available the refusal is retried, and the retry is aimed at the
# one top-level entry the kernel refused - GNU rm names the file inside it -
# not at the whole cache directory. Here sudo grants nothing, so the entry
# still survives and the step still warns; what changes is what was asked.
mkdir -p "$d/home/Library/Caches/disposable"
printf 'junk\n' > "$d/home/Library/Caches/disposable/data"
: > "$d/calls"
out="$(run_sf "$d/tmp" --yes --only user-caches)"; rc=$?
assert_eq "a refused entry with sudo available does not fail the run" "0" "$rc"
assert_contains "the retry is announced" "$out" "retrying 1 entry owned by another user with sudo"
assert_called "the retry names the refused top-level entry" "$d/calls" \
  "sudo rm -rf -- $d/home/Library/Caches/protected"
assert_not_called "the retry does not sweep the whole directory" "$d/calls" "sudo find"
assert_not_called "the retry leaves the entries the first pass handled alone" "$d/calls" "disposable"
assert_contains "a retry sudo could not carry out is still a warning" "$out" "warn steps:  1"
if [[ -f "$d/home/Library/Caches/protected/data" ]]; then
  ok "the refused entry survives a retry that grants nothing"
else
  err "the refused entry was removed"
fi
chmod 755 "$d/home/Library/Caches/protected"

echo "--- an unreadable directory under ~/Library/Logs ---"
# find cannot enter a mode-000 directory and exits non-zero having listed
# everything else. The sweep still removes what was listed and says what it
# could not see; it used to throw the whole list away and prune nothing.
L="$d/home/Library/Logs"
mkdir -p "$L/Homebrew" "$L/locked"
printf 'old\n' > "$L/Homebrew/old.log"; touch -d '40 days ago' "$L/Homebrew/old.log"
printf 'hidden\n' > "$L/locked/old.log"; touch -d '40 days ago' "$L/locked/old.log"
chmod 000 "$L/locked"
out="$(run_sf "$d/tmp" --yes --no-sudo --only user-logs)"; rc=$?
assert_eq "an unreadable log directory does not fail the run" "0" "$rc"
if [[ ! -e "$L/Homebrew/old.log" ]]; then
  ok "the old logs that were listed are still removed"
else
  err "an unreadable directory stopped the whole sweep"
fi
assert_contains "the unreadable directory is reported" "$out" "could not be fully scanned"
assert_contains "an unreadable directory is accounted a warning" "$out" "warn steps:  1"
chmod 755 "$L/locked"
rm -rf "$d"

if (( failures )); then
  echo; echo "=== $failures unprivileged test(s) failed ===" >&2
  exit 1
fi
echo; echo "=== all stay_fresh unprivileged (docker) checks passed ==="
exit 0

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

run_sf() {
  local tmp="$1"; shift
  HOME="$d/home" TMPDIR="$tmp" PATH="$d/bin:/usr/bin:/bin" NO_COLOR=1 \
    "$SF" "$@" </dev/null 2>&1
}

echo "--- run lock under EACCES ---"
# /rootonly is mode 700 and owned by root, so `mkdir -p` of anything beneath it
# fails outright. The run must say it could not create the directory, not blame
# a lock.
out="$(run_sf /rootonly/scratch --yes --no-sudo --only versions)"; rc=$?
assert_eq "an uncreatable TMPDIR fails preflight -> 2" "2" "$rc"
assert_contains "an uncreatable TMPDIR is named" "$out" "to hold the run lock"
assert_not_contains "an uncreatable TMPDIR is not blamed on a stale lock" "$out" \
  "stale stay_fresh lock"

# /rootlocked exists and is traversable but not writable by us, so `mkdir -p`
# succeeds (it is already there) and the lock mkdir is the call that gets EACCES.
# This is the branch that distinguishes "someone else holds the lock" from "we
# cannot create one": before, any mkdir failure was read as contention and the
# recovery path announced a stale lock that never existed.
out="$(run_sf /rootlocked --yes --no-sudo --only versions)"; rc=$?
assert_eq "an unwritable TMPDIR fails preflight -> 2" "2" "$rc"
assert_contains "an unwritable TMPDIR reports the lock it could not take" "$out" \
  "cannot acquire run lock"
assert_not_contains "an unwritable TMPDIR is not blamed on a stale lock" "$out" \
  "stale stay_fresh lock"

echo "--- cache deletion that the filesystem refuses ---"
# A cache entry inside a directory we may not write: rm(1) can unlink neither the
# child nor, therefore, the parent. The step must keep the data, say so, and be
# accounted a warning rather than a clean success.
mkdir -p "$d/home/Library/Caches/protected"
printf 'irreplaceable\n' > "$d/home/Library/Caches/protected/data"
mkdir -p "$d/home/Library/Caches/disposable"
printf 'junk\n' > "$d/home/Library/Caches/disposable/data"
chmod 555 "$d/home/Library/Caches/protected"

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
chmod 755 "$d/home/Library/Caches/protected"
rm -rf "$d"

if (( failures )); then
  echo; echo "=== $failures unprivileged test(s) failed ===" >&2
  exit 1
fi
echo; echo "=== all stay_fresh unprivileged (docker) checks passed ==="
exit 0

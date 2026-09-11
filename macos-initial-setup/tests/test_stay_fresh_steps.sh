#!/usr/bin/env bash
# Per-step behavior tests for stay_fresh.sh, run inside the Linux tester
# container with the repo mounted at /repo.
#
# The sibling suite (test_macos_initial_setup.sh) covers the CLI surface of
# every script: --help, argument rejection, plans, dry runs. What it cannot
# reach is the inside of a step, because a step deletes things. This file runs
# each of the twenty-three steps for real against a scratch HOME and a faked set of
# host binaries, and asserts on what is gone, what survived, and how the run
# accounted for it.
#
# Two of those steps clear absolute system paths (/Library/Caches,
# /Library/Logs/DiagnosticReports). That is the reason this file is
# container-only and refuses to start anywhere else: in a disposable container
# those paths are ours to create and destroy, and on a real macOS host running
# it would delete the caller's system caches.
set -uo pipefail

if [[ "$(uname -s)" != "Linux" || ! -f /.dockerenv ]]; then
  echo "refusing to run: this suite clears absolute system paths and is container-only" >&2
  exit 1
fi
# `compose run` allocates a TTY on a developer terminal unless the runner
# passes -T. Opening /dev/tty then succeeds, cask upgrades take the interactive
# path, and the launchd-shaped assertions below go green for the wrong reason.
if { : < /dev/tty; } >/dev/null 2>&1; then
  echo "refusing to run: this suite needs no controlling terminal (compose run -T)" >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-/repo}"
M="$REPO_ROOT/macos-initial-setup"
SF="$M/stay_fresh.sh"
[[ -x "$SF" ]] || { echo "expected stay_fresh.sh at $SF" >&2; exit 1; }

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
  else err "$label (missing '$needle')"; printf '%s\n' "$haystack" | tail -25 >&2; fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    err "$label (unexpected '$needle')"; printf '%s\n' "$haystack" | tail -25 >&2
  else ok "$label"; fi
}
assert_gone() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then err "$label ($path still exists)"; else ok "$label"; fi
}
assert_exists() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then ok "$label"; else err "$label ($path is missing)"; fi
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

# --- fake host -------------------------------------------------------------
# Write an executable /bin/sh stub. Bodies are passed as separate lines so they
# can be single-quoted and keep their own $variables unexpanded here.
mkbin() {
  local path="$1"; shift
  { echo '#!/bin/sh'; printf '%s\n' "$@"; } > "$path"
  chmod +x "$path"
}

# A fresh, isolated environment root per test. Only the commands that identify
# the host or that the step under test drives are faked; find, rm, du and the
# rest are the real thing, so deletion is really deletion.
new_env() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/home" "$d/tmp"
  mkbin "$d/bin/uname" 'case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac'
  mkbin "$d/bin/id"    'case "${1:-}" in -u) echo 501 ;; -un) echo tester ;; *) /usr/bin/id "$@" ;; esac'
  mkbin "$d/bin/sw_vers" 'case "${1:-}" in -productVersion) echo 15.0 ;; -buildVersion) echo TESTBUILD ;; esac'
  mkbin "$d/bin/df" 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"' \
                    'echo "/dev/test 1000000 200000 800000 20% /"'
  # RUNNING_APPS entries are matched as substrings of any argument, so the
  # fake answers both `pgrep -x Codex` and the bundle-path form the app-cache
  # guard uses, `pgrep -f "/Visual Studio Code.app/Contents/MacOS/"`.
  mkbin "$d/bin/pgrep" '[ -n "${PGREP_RC:-}" ] && exit "$PGREP_RC"' \
                       'for a in "$@"; do' \
                       '  case "$a" in -*) continue ;; esac' \
                       '  for app in ${RUNNING_APPS:-}; do' \
                       '    case "$a" in *"$app"*) exit 0 ;; esac' \
                       '  done' \
                       'done; exit 1'
  mkbin "$d/bin/xcode-select" 'case "${1:-}" in -p) echo /Library/Developer/CommandLineTools ;; esac; exit 0'
  mkbin "$d/bin/pkgutil" 'echo "version: 15.0.0.0.1"; exit 0'
  # sudo is absent from the image. Authenticate trivially and otherwise exec the
  # command, so the sudo-gated steps run their real work against scratch paths.
  mkbin "$d/bin/sudo" 'case "${1:-}" in' \
                      '  -v) exit 0 ;;' \
                      '  -n) shift; case "${1:-}" in true) exit 0 ;; esac ;;' \
                      'esac' \
                      'echo "sudo $*" >> "$CALLS"' \
                      'exec "$@"'
  printf '%s' "$d"
}

# Run stay_fresh.sh inside an environment root. Prints combined output; the
# caller keeps $?.
# Every variable the script reads has to be named here, set to the caller's
# value or to empty. Two reasons, and both bite silently:
#
#   - A caller writes `FOO=x out="$(run_sf ...)"`. That is two assignments,
#     not a command with a prefix, so FOO is an ordinary shell variable and
#     never reaches the child unless this list exports it.
#   - Anything not named here leaks in from the host. BUN_INSTALL is exported
#     on a developer machine and in this suite's own container, so a test that
#     relied on the default path cleared the real cache and passed.
#
# The four cache-location variables are listed even though no test sets most
# of them, precisely so the host's values cannot reach a run that clears
# whatever they point at.
run_sf() {
  local d="$1"; shift
  HOME="$d/home" TMPDIR="$d/tmp" PATH="$d/bin:/usr/bin:/bin" \
    CALLS="$d/calls" NO_COLOR=1 \
    RUNNING_APPS="${RUNNING_APPS:-}" \
    PGREP_RC="${PGREP_RC:-}" \
    DOCKER_ENDPOINT="${DOCKER_ENDPOINT:-unix:///var/run/docker.sock}" \
    DOCKER_INFO_FAIL_AFTER="${DOCKER_INFO_FAIL_AFTER:-}" \
    DOCKER_INFO_N="$d/docker.info.n" \
    NODE_RC="${NODE_RC:-0}" \
    HELM_UPDATE_RC="${HELM_UPDATE_RC:-0}" \
    KREW_UPGRADE_RC="${KREW_UPGRADE_RC:-0}" \
    GCLOUD_COMPONENTS_RC="${GCLOUD_COMPONENTS_RC:-0}" \
    BREW_REPO="${BREW_REPO:-}" \
    STAY_FRESH_NOTIFY="${STAY_FRESH_NOTIFY:-none}" \
    STAY_FRESH_TG_BOT_TOKEN="${STAY_FRESH_TG_BOT_TOKEN:-}" \
    STAY_FRESH_TG_CHAT_ID="${STAY_FRESH_TG_CHAT_ID:-}" \
    SNAPSHOTS="${SNAPSHOTS:-}" \
    TM_RUNNING="${TM_RUNNING:-}" \
    TM_DELETE_HANG="${TM_DELETE_HANG:-}" \
    TM_DELETE_FAIL="${TM_DELETE_FAIL:-}" \
    DOCKER_INFO_HANG="${DOCKER_INFO_HANG:-}" \
    SU_HANG="${SU_HANG:-}" \
    STAY_FRESH_SLACK_WEBHOOK="${STAY_FRESH_SLACK_WEBHOOK:-}" \
    STAY_FRESH_STEP_TIMEOUT="${STAY_FRESH_STEP_TIMEOUT:-}" \
    STAY_FRESH_NOTIFY_WHEN="${STAY_FRESH_NOTIFY_WHEN:-}" \
    STAY_FRESH_NOTIFY_TIMEOUT="${STAY_FRESH_NOTIFY_TIMEOUT:-}" \
    BREW_SERVICES_ERROR="${BREW_SERVICES_ERROR:-}" \
    BUN_INSTALL="${BUN_INSTALL:-}" \
    TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-}" \
    CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-}" \
    UV_CACHE_DIR="${UV_CACHE_DIR:-}" \
    "$SF" "$@" </dev/null 2>&1
}

# /dev/urandom, not /dev/zero: several assertions below compare rendered `du`
# output, and a zero-filled file measures near nothing on a btrfs or ZFS
# runner with compression on, failing tests on code that is correct.
bytes_file() { dd if=/dev/urandom of="$1" bs=1024 count="${2:-512}" status=none; }

section() { echo; echo "--- $* ---"; }

# ===========================================================================
section "memory (sudo purge)"
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/purge" 'echo "purge $*" >> "$CALLS"; exit 0'
out="$(run_sf "$d" --yes --purge-memory --only memory)"; rc=$?
assert_eq "memory step succeeds" "0" "$rc"
assert_called "memory step runs sudo purge" "$d/calls" "sudo purge"
rm -rf "$d"

# ===========================================================================
section "dns (flush + mDNSResponder)"
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/dscacheutil" 'echo "dscacheutil $*" >> "$CALLS"; exit 0'
mkbin "$d/bin/killall"     'echo "killall $*" >> "$CALLS"; exit 0'
out="$(run_sf "$d" --yes --only dns)"; rc=$?
assert_eq "dns step succeeds" "0" "$rc"
assert_called "dns step flushes the resolver cache" "$d/calls" "dscacheutil -flushcache"
assert_called "dns step reloads mDNSResponder"      "$d/calls" "killall -HUP mDNSResponder"
rm -rf "$d"

# ===========================================================================
section "system-caches (root-owned absolute paths)"
# /System/Library/Caches holds the dyld shared cache and the kernel caches:
# what the machine boots from. It is kept unless csrutil positively reports
# System Integrity Protection off AND --force-system-caches is passed. The
# four ways csrutil can fail to answer used to read as "SIP is off" and took
# the branch that runs sudo rm -rf over that directory.
syscache_env() {
  local d; d="$(new_env)"
  rm -rf /Library/Caches /System/Library/Caches
  mkdir -p /Library/Caches/vendor /System/Library/Caches/com.apple.dyld /System/Library/Caches/vendor
  bytes_file /Library/Caches/vendor/blob 256
  : > /System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e
  : > /System/Library/Caches/vendor/entry
  printf '%s' "$d"
}
for csr in missing failing localized unknown; do
  d="$(syscache_env)"; : > "$d/calls"
  case "$csr" in
    missing)   rm -f "$d/bin/csrutil" ;;
    failing)   mkbin "$d/bin/csrutil" 'exit 1' ;;
    localized) mkbin "$d/bin/csrutil" 'echo "Statut de la protection de l integrite du systeme : desactive."' ;;
    unknown)   mkbin "$d/bin/csrutil" 'echo "System Integrity Protection status: unknown (Custom Configuration)."' ;;
  esac
  out="$(run_sf "$d" --yes --only system-caches --force-system-caches)"; rc=$?
  assert_eq "system-caches with csrutil $csr succeeds" "0" "$rc"
  assert_gone   "/Library/Caches is still cleared ($csr)" /Library/Caches/vendor
  assert_exists "the dyld cache survives csrutil $csr" /System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e
  assert_exists "no system cache entry is removed on csrutil $csr" /System/Library/Caches/vendor/entry
  assert_contains "an unreadable SIP state is stated ($csr)" "$out" \
    "could not read the System Integrity Protection state"
  rm -rf /Library/Caches /System/Library/Caches "$d"
done

# SIP positively off, but without the flag: still kept.
d="$(syscache_env)"; : > "$d/calls"
mkbin "$d/bin/csrutil" 'echo "System Integrity Protection status: disabled."'
out="$(run_sf "$d" --yes --only system-caches)"; rc=$?
assert_eq "system-caches with SIP off succeeds" "0" "$rc"
assert_exists "SIP off alone does not clear the system caches" /System/Library/Caches/vendor/entry
assert_contains "the flag that would clear them is named" "$out" "--force-system-caches clears it"
rm -rf /Library/Caches /System/Library/Caches "$d"

# SIP positively off and asked for: cleared, except the boot caches.
d="$(syscache_env)"; : > "$d/calls"
mkbin "$d/bin/csrutil" 'echo "System Integrity Protection status: disabled."'
out="$(run_sf "$d" --yes --only system-caches --force-system-caches)"; rc=$?
assert_eq "forced system-caches succeeds" "0" "$rc"
assert_gone   "an ordinary system cache entry is removed" /System/Library/Caches/vendor
assert_exists "the dyld cache is never removed" /System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e
assert_contains "the kept boot caches are named" "$out" "keeping com.apple.dyld"
rm -rf /Library/Caches /System/Library/Caches "$d"

# --reports is read-only and refuses the flag outright.
d="$(new_env)"
run_sf "$d" --dry-run --reports --force-system-caches >/dev/null; rc=$?
assert_eq "--reports refuses --force-system-caches" "3" "$rc"
rm -rf "$d"

# ===========================================================================
section "system-caches under System Integrity Protection"
# On a Mac with SIP on, every entry of /System/Library/Caches answers
# "Operation not permitted" to root, and the step used to warn on every run.
# With csrutil reporting SIP enabled, the directory is not touched at all.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/csrutil" 'echo "System Integrity Protection status: enabled."'
rm -rf /Library/Caches /System/Library/Caches
mkdir -p /Library/Caches/vendor /System/Library/Caches/writable
bytes_file /Library/Caches/vendor/blob 256
: > /System/Library/Caches/writable/entry
out="$(run_sf "$d" --yes --only system-caches)"; rc=$?
assert_eq "system-caches under SIP succeeds" "0" "$rc"
assert_gone   "/Library/Caches is still cleared under SIP" /Library/Caches/vendor
assert_exists "/System/Library/Caches is left alone under SIP" /System/Library/Caches/writable/entry
assert_contains "the SIP protection is stated" "$out" "protected by System Integrity Protection"
assert_contains "a SIP-protected system cache is not a warning" "$out" "warn steps:  0"
rm -rf /Library/Caches /System/Library/Caches
rm -rf "$d"

# ===========================================================================
section "protected cache entries (SIP / privacy controls) are kept, not warned"
# rm answering "Operation not permitted" is EPERM: SIP or the privacy
# controls, which no run can change. A real ~/Library/Caches has a dozen such
# Apple entries, and warning about them every day is the warning that gets
# muted. A fake rm refuses one entry that way and removes the rest.
d="$(new_env)"; : > "$d/calls"
# find -exec ... {} + hands every path to one rm, and a real rm keeps going
# past the entry it cannot remove; the fake does the same.
mkbin "$d/bin/rm" 'fail=0; opts=""' \
                  'for a in "$@"; do' \
                  '  case "$a" in' \
                  '    -*) opts="$opts $a" ;;' \
                  '    *"/com.apple.homed"*) echo "rm: $a: Operation not permitted" >&2; fail=1 ;;' \
                  '    *) /bin/rm $opts "$a" ;;' \
                  '  esac' \
                  'done' \
                  'exit $fail'
mkdir -p "$d/home/Library/Caches/com.apple.homed" "$d/home/Library/Caches/com.vendor.app"
: > "$d/home/Library/Caches/com.apple.homed/state"
bytes_file "$d/home/Library/Caches/com.vendor.app/blob" 128
out="$(run_sf "$d" --yes --no-sudo --only user-caches)"; rc=$?
assert_eq "a protected entry does not fail the run" "0" "$rc"
assert_exists "the protected entry survives" "$d/home/Library/Caches/com.apple.homed/state"
assert_gone   "the ordinary neighbour is still cleared" "$d/home/Library/Caches/com.vendor.app"
assert_contains "protected entries are reported as kept" "$out" "entries kept: protected by macOS"
assert_contains "a protected entry is not a warning" "$out" "warn steps:  0"
rm -rf "$d"

# "Permission denied" is EACCES: ownership, which sudo can take. With sudo
# available the entry is retried under it; the fake sudo execs the real
# command, so the retry succeeds and the run stays clean.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/rm" 'fail=0; opts=""' \
                  'for a in "$@"; do' \
                  '  case "$a" in' \
                  '    -*) opts="$opts $a" ;;' \
                  '    *"ShipIt"*) if [ -z "${SUDO_RETRY:-}" ]; then echo "rm: $a: Permission denied" >&2; fail=1; else /bin/rm $opts "$a"; fi ;;' \
                  '    *) /bin/rm $opts "$a" ;;' \
                  '  esac' \
                  'done' \
                  'exit $fail'
mkbin "$d/bin/sudo" 'case "${1:-}" in -v) exit 0 ;; -n) shift; case "${1:-}" in true) exit 0 ;; esac ;; esac' \
                    'echo "sudo $*" >> "$CALLS"' \
                    'SUDO_RETRY=1 exec "$@"'
mkdir -p "$d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt"
: > "$d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt/update"
mkdir -p "$d/home/Library/Caches/com.vendor.app"
bytes_file "$d/home/Library/Caches/com.vendor.app/blob" 64
out="$(run_sf "$d" --yes --only user-caches)"; rc=$?
assert_eq "an ownership refusal with sudo available succeeds" "0" "$rc"
assert_contains "the sudo retry is announced with its count" "$out" "retrying 1 entry owned by another user with sudo"
# The retry names the entry rm refused, and nothing else: a sudo sweep of the
# whole directory would also take the entries the privacy controls protect.
assert_called "the retry removes exactly the refused entry through sudo" "$d/calls" \
  "sudo rm -rf -- $d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt"
assert_not_called "the retry does not sweep the whole directory" "$d/calls" "sudo find"
assert_not_called "the retry does not touch the neighbour" "$d/calls" "com.vendor.app"
assert_gone "the root-owned leftover is removed by the retry" "$d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt"
assert_gone "the ordinary neighbour went in the first pass" "$d/home/Library/Caches/com.vendor.app"
assert_contains "a retried ownership refusal is not a warning" "$out" "warn steps:  0"
rm -rf "$d"

# Both kinds at once: the refusal is retried, the protected entry is not.
# Before, the retry was `sudo find ... -exec rm`, which reached for the
# protected one as root too. The refused path is nested here (GNU rm names
# the deepest file it could not unlink), and the retry still targets the
# top-level entry under the cache root. The fake also prints what BSD rm
# prints after a refused file, "Directory not empty" for each parent; those
# lines describe the entry the retry then removed and must not survive it
# as leftovers, or every real Mac would warn after a retry that worked.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/rm" 'fail=0; opts=""' \
                  'for a in "$@"; do' \
                  '  case "$a" in' \
                  '    -*) opts="$opts $a" ;;' \
                  '    *"/com.apple.homed"*) echo "rm: $a: Operation not permitted" >&2; fail=1 ;;' \
                  '    *"ShipIt"*) if [ -z "${SUDO_RETRY:-}" ]; then echo "rm: cannot remove '"'"'$a/pending/update'"'"': Permission denied" >&2; echo "rm: $a/pending: Directory not empty" >&2; echo "rm: $a: Directory not empty" >&2; fail=1; else /bin/rm $opts "$a"; fi ;;' \
                  '    *) /bin/rm $opts "$a" ;;' \
                  '  esac' \
                  'done' \
                  'exit $fail'
mkbin "$d/bin/sudo" 'case "${1:-}" in -v) exit 0 ;; -n) shift; case "${1:-}" in true) exit 0 ;; esac ;; esac' \
                    'echo "sudo $*" >> "$CALLS"' \
                    'SUDO_RETRY=1 exec "$@"'
mkdir -p "$d/home/Library/Caches/com.apple.homed" "$d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt/pending"
: > "$d/home/Library/Caches/com.apple.homed/state"
: > "$d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt/pending/update"
out="$(run_sf "$d" --yes --only user-caches)"; rc=$?
assert_eq "a protected entry beside a refused one is a clean step" "0" "$rc"
assert_called "the nested refusal is retried at its top-level entry" "$d/calls" \
  "sudo rm -rf -- $d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt"
assert_not_called "sudo is not pointed at the protected entry" "$d/calls" "com.apple.homed"
assert_gone   "the refused entry is gone after the retry" "$d/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt"
assert_exists "the protected entry survives the retry" "$d/home/Library/Caches/com.apple.homed/state"
assert_contains "the protected entry is still reported as kept" "$out" "entries kept: protected by macOS"
assert_contains "neither is a warning" "$out" "warn steps:  0"
rm -rf "$d"

# ===========================================================================
section "destructive steps stay inside HOME"
# The bug class this guards: one empty variable upstream and "$HOME/Library/
# Caches" becomes "/Library/Caches", "$HOME/.Trash" becomes "/.Trash". Every
# other assertion here looks only at the scratch HOME, so a step that walked
# out of it would still pass them all. These canaries are the ones that would
# not.
d="$(new_env)"; : > "$d/calls"
rm -rf /Library/Caches /.Trash
mkdir -p /Library/Caches /.Trash "$d/home/Library/Caches/vendor" "$d/home/.Trash"
: > /Library/Caches/CANARY
: > /.Trash/CANARY
bytes_file "$d/home/Library/Caches/vendor/blob" 64
: > "$d/home/.Trash/junk"
out="$(run_sf "$d" --yes --no-sudo --only user-caches,trash,dev-caches,user-logs)"; rc=$?
assert_eq "the sweep succeeds" "0" "$rc"
assert_gone   "the scratch HOME cache was cleared"  "$d/home/Library/Caches/vendor"
assert_gone   "the scratch HOME trash was emptied"  "$d/home/.Trash/junk"
assert_exists "the system cache directory is untouched" /Library/Caches/CANARY
assert_exists "the root .Trash is untouched"            /.Trash/CANARY
rm -rf /Library/Caches /.Trash "$d"

# ===========================================================================
section "user-caches (contents cleared, directories kept, bytes counted)"
d="$(new_env)"
for sub in "Caches/vendor" "Saved Application State/app.savedState" \
           "Developer/Xcode/DerivedData/Proj-abc" "Application Support/Caches/thing"; do
  mkdir -p "$d/home/Library/$sub"
done
bytes_file "$d/home/Library/Caches/vendor/blob" 1024
: > "$d/home/Library/Saved Application State/app.savedState/data"
: > "$d/home/Library/Developer/Xcode/DerivedData/Proj-abc/index"
: > "$d/home/Library/Application Support/Caches/thing/data"
out="$(run_sf "$d" --yes --only user-caches)"; rc=$?
assert_eq "user-caches step succeeds" "0" "$rc"
assert_gone   "user cache contents are removed"   "$d/home/Library/Caches/vendor"
assert_exists "~/Library/Caches itself is kept"   "$d/home/Library/Caches"
assert_gone   "saved application state is removed" "$d/home/Library/Saved Application State/app.savedState"
assert_gone   "Xcode DerivedData is removed"      "$d/home/Library/Developer/Xcode/DerivedData/Proj-abc"
assert_gone   "Application Support caches are removed" "$d/home/Library/Application Support/Caches/thing"
if grep -Eq 'steps freed: +[0-9]+\.[0-9]+[KMG]' <<<"$out"; then
  ok "freed bytes are measured and reported"
else
  err "freed bytes were not reported"; grep -i 'steps freed' <<<"$out" >&2
fi
rm -rf "$d"

# ===========================================================================
section "app-caches (running apps kept, idle apps cleared)"
d="$(new_env)"
as="$d/home/Library/Application Support"
# Spotify's streaming cache is routinely several GB and lives outside
# ~/Library/Caches, so the user-caches step never sees it. Its own settings
# and credentials sit beside it under the same root and must survive.
mkdir -p "$as/Slack/Cache" "$as/Notion/GPUCache" \
         "$as/Spotify/PersistentCache/Storage" "$as/Spotify/Users/serhii-user" \
         "$as/Code/CachedExtensionVSIXs" "$d/home/Library/Containers/com.x/Data/Library/Caches"
: > "$as/Spotify/PersistentCache/Storage/chunk"
: > "$as/Spotify/Users/serhii-user/prefs"
: > "$as/Slack/Cache/data"
: > "$as/Notion/GPUCache/data"
: > "$as/Code/CachedExtensionVSIXs/ext.vsix"
: > "$d/home/Library/Containers/com.x/Data/Library/Caches/blob"
RUNNING_APPS="Slack" out="$(run_sf "$d" --yes --only app-caches)"; rc=$?
assert_eq "app-caches step succeeds" "0" "$rc"
assert_exists "a running app keeps its cache"       "$as/Slack/Cache/data"
assert_gone   "an idle app loses its cache"         "$as/Notion/GPUCache"
assert_gone   "Spotify's streaming cache is cleared when it is idle" \
  "$as/Spotify/PersistentCache/Storage"
assert_exists "Spotify's settings and credentials are untouched" \
  "$as/Spotify/Users/serhii-user/prefs"
assert_gone   "the VSIX download cache is emptied"  "$as/Code/CachedExtensionVSIXs/ext.vsix"
assert_exists "the VSIX directory itself is kept"   "$as/Code/CachedExtensionVSIXs"
assert_exists "sandbox containers are kept by default" \
  "$d/home/Library/Containers/com.x/Data/Library/Caches/blob"
RUNNING_APPS="Slack" out="$(run_sf "$d" --yes --force-active-app-caches --only app-caches)"
assert_gone "--force-active-app-caches clears a running app" "$as/Slack/Cache"
assert_gone "--force-active-app-caches clears sandbox containers" \
  "$d/home/Library/Containers/com.x/Data/Library/Caches/blob"
assert_exists "the sandbox Caches directory itself is kept" \
  "$d/home/Library/Containers/com.x/Data/Library/Caches"
rm -rf "$d"

# Spotify while it is playing: the running-app guard covers it like any other,
# and clearing a streaming cache under a running player is exactly the case
# the guard exists for.
d="$(new_env)"
as="$d/home/Library/Application Support"
mkdir -p "$as/Spotify/PersistentCache/Storage" "$as/Notion/GPUCache"
: > "$as/Spotify/PersistentCache/Storage/chunk"
: > "$as/Notion/GPUCache/data"
RUNNING_APPS="Spotify" out="$(run_sf "$d" --yes --only app-caches)"
assert_exists "a running Spotify keeps its streaming cache" \
  "$as/Spotify/PersistentCache/Storage/chunk"
assert_contains "and it is named among the running apps" "$out" "Spotify"
assert_gone "an idle app beside it is still cleared" "$as/Notion/GPUCache"
rm -rf "$d"

# ===========================================================================
section "ai-caches (temporary data only, active tools kept)"
d="$(new_env)"
as="$d/home/Library/Application Support"
mkdir -p "$as/Codex/Default/GPUCache" "$as/Codex/Default/Session Storage" \
         "$as/Cursor/Code Cache" "$d/home/Library/Caches/Codex" \
         "$d/home/.codex/tmp" "$d/home/.codex/sessions/kept" \
         "$d/home/.cache/codex-runtimes/kept" \
         "$as/Ollama/models/kept"
: > "$as/Codex/Default/GPUCache/data"
: > "$as/Codex/Default/Session Storage/state"
: > "$as/Cursor/Code Cache/data"
: > "$d/home/Library/Caches/Codex/data"
: > "$d/home/.codex/tmp/data"
: > "$d/home/.codex/sessions/kept/session"
: > "$d/home/.cache/codex-runtimes/kept/runtime"
: > "$as/Ollama/models/kept/model"
out="$(run_sf "$d" --yes --only ai-caches)"; rc=$?
assert_eq "ai-caches step succeeds" "0" "$rc"
assert_gone "Codex's disposable GPU cache is removed" "$as/Codex/Default/GPUCache"
assert_gone "Cursor's disposable code cache is removed" "$as/Cursor/Code Cache"
assert_gone "Codex bundle cache contents are removed" "$d/home/Library/Caches/Codex/data"
assert_gone "Codex CLI tmp contents are removed" "$d/home/.codex/tmp/data"
assert_exists "Codex session storage is kept" "$as/Codex/Default/Session Storage/state"
assert_exists "Codex sessions are kept" "$d/home/.codex/sessions/kept/session"
assert_exists "Codex runtimes are kept" "$d/home/.cache/codex-runtimes/kept/runtime"
assert_exists "Ollama models are kept" "$as/Ollama/models/kept/model"
assert_contains "the run states which AI data is preserved" "$out" \
  "credentials, settings, sessions, projects, extensions, runtimes, and models kept"

mkbin "$d/bin/mktemp" 'echo "mktemp $*" >> "$CALLS"; exec /usr/bin/mktemp "$@"'
: > "$d/calls"
out="$(run_sf "$d" --dry-run --only ai-caches)"; rc=$?
assert_eq "ai-caches dry run succeeds" "0" "$rc"
assert_not_called "ai-caches dry run creates no scanner temporary file" \
  "$d/calls" "mktemp"
rm -rf "$d"

d="$(new_env)"
as="$d/home/Library/Application Support"
mkdir -p "$as/Codex/Default/GPUCache" "$d/home/.codex/tmp"
: > "$as/Codex/Default/GPUCache/data"
: > "$d/home/.codex/tmp/data"
RUNNING_APPS="Codex" out="$(run_sf "$d" --yes --only ai-caches)"; rc=$?
assert_eq "a running AI tool does not fail cleanup" "0" "$rc"
assert_exists "a running Codex app keeps its cache" "$as/Codex/Default/GPUCache/data"
assert_exists "a running Codex app keeps its CLI cache" "$d/home/.codex/tmp/data"
assert_contains "the run explains why active AI caches were kept" "$out" \
  "Codex is running - keeping its caches"
rm -rf "$d"

d="$(new_env)"
as="$d/home/Library/Application Support"
mkdir -p "$as/Codex/Default/GPUCache"
: > "$as/Codex/Default/GPUCache/data"
RUNNING_APPS="ChatGPT" out="$(run_sf "$d" --yes --only ai-caches)"; rc=$?
assert_eq "active ChatGPT does not fail Codex cache cleanup" "0" "$rc"
assert_exists "active ChatGPT keeps its Codex data-directory cache" \
  "$as/Codex/Default/GPUCache/data"
rm -rf "$d"

d="$(new_env)"
as="$d/home/Library/Application Support"
mkdir -p "$as/Codex/Default/GPUCache"
: > "$as/Codex/Default/GPUCache/data"
PGREP_RC=2 out="$(PGREP_RC=2 run_sf "$d" --yes --only ai-caches)"; rc=$?
assert_eq "an unavailable process check keeps AI cleanup non-fatal" "0" "$rc"
assert_exists "an unavailable process check fails closed" "$as/Codex/Default/GPUCache/data"
assert_contains "an unavailable process check explains the safe refusal" "$out" \
  "cannot determine whether Codex is running - keeping its caches"
assert_contains "an unavailable process check records a warning" "$out" \
  "warn steps:  1"
rm -rf "$d"

# ===========================================================================
section "workspace-storage (stale entries only)"
d="$(new_env)"
ws="$d/home/Library/Application Support/Code/User/workspaceStorage"
mkdir -p "$ws/deadhash" "$ws/livehash" "$ws/remotehash" "$d/home/project"
printf '{"folder": "file://%s/gone"}' "$d/home"    > "$ws/deadhash/workspace.json"
printf '{"folder": "file://%s/project"}' "$d/home" > "$ws/livehash/workspace.json"
printf '{"folder": "vscode-remote://ssh-remote+host/p"}' > "$ws/remotehash/workspace.json"
out="$(run_sf "$d" --yes --only workspace-storage)"; rc=$?
assert_eq "workspace-storage step succeeds" "0" "$rc"
assert_gone   "an entry for a deleted project is pruned" "$ws/deadhash"
assert_exists "an entry for a live project is kept"      "$ws/livehash"
assert_exists "a remote workspace entry is kept"         "$ws/remotehash"
assert_contains "the classification is reported" "$out" "1 live · 1 stale · 1 unresolved"
rm -rf "$d"

# ===========================================================================
section "trash"
d="$(new_env)"
mkdir -p "$d/home/.Trash/folder"
bytes_file "$d/home/.Trash/big" 256
: > "$d/home/.Trash/.hidden"
: > "$d/home/.Trash/folder/nested"
out="$(run_sf "$d" --yes --only trash)"; rc=$?
assert_eq "trash step succeeds" "0" "$rc"
assert_gone   "visible trash is emptied" "$d/home/.Trash/big"
assert_gone   "hidden trash is emptied"  "$d/home/.Trash/.hidden"
assert_gone   "nested trash is emptied"  "$d/home/.Trash/folder"
assert_exists "~/.Trash itself is kept"  "$d/home/.Trash"
rm -rf "$d"

# ===========================================================================
section "docker (local prune, remote refusal, failure routing)"
docker_fake() {
  mkbin "$1/bin/docker" \
    'echo "docker $*" >> "$CALLS"' \
    'case "${1:-}" in' \
    '  info)' \
    '    [ -n "${DOCKER_INFO_HANG:-}" ] && sleep 60' \
    '    if [ -n "${DOCKER_INFO_FAIL_AFTER:-}" ]; then' \
    '      n=$(cat "$DOCKER_INFO_N" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$DOCKER_INFO_N"' \
    '      [ "$n" -gt "$DOCKER_INFO_FAIL_AFTER" ] && exit 1' \
    '    fi' \
    '    exit 0 ;;' \
    '  context)' \
    '    case "${2:-}" in' \
    '      show) echo default ;;' \
    '      inspect) [ -n "${DOCKER_INSPECT_FAIL:-}" ] && exit 1; echo "$DOCKER_ENDPOINT" ;;' \
    '    esac' \
    '    exit 0 ;;' \
    '  system) printf "Images\t1.5GB\n"; exit 0 ;;' \
    'esac' \
    'exit 0'
}
d="$(new_env)"; : > "$d/calls"; docker_fake "$d"
out="$(run_sf "$d" --yes --only docker)"; rc=$?
assert_eq "docker step succeeds against a local daemon" "0" "$rc"
assert_called "stopped containers are pruned by age, not wholesale" "$d/calls" \
  "docker container prune -f --filter until=168h"
for sub in "network prune -f" \
           "image prune -f" "builder prune -af"; do
  assert_called "docker step runs $sub" "$d/calls" "docker $sub"
done
# Volumes hold data, not cache, and the LaunchAgent runs with --yes — an
# unattended volume prune deletes a stopped project's database volume. The
# default run must not touch them; --prune-docker-volumes is the opt-in.
assert_not_called "docker volumes are untouched by default" "$d/calls" \
  "docker volume prune"
assert_contains "the run says why volumes were kept" "$out" "volumes kept"
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"; docker_fake "$d"
out="$(run_sf "$d" --yes --only docker --prune-docker-volumes)"; rc=$?
assert_eq "docker step succeeds with --prune-docker-volumes" "0" "$rc"
assert_called "--prune-docker-volumes runs volume prune -f" "$d/calls" \
  "docker volume prune -f"
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"; docker_fake "$d"
DOCKER_ENDPOINT="tcp://build-farm.internal:2375" out="$(run_sf "$d" --yes --only docker)"; rc=$?
assert_eq "a remote docker context does not fail the run" "0" "$rc"
assert_contains "a remote docker context is refused" "$out" "points to non-local host"
assert_not_called "nothing is pruned on a remote context" "$d/calls" "prune"
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"; docker_fake "$d"
DOCKER_INSPECT_FAIL=1 out="$(DOCKER_INSPECT_FAIL=1 run_sf "$d" --yes --only docker)"; rc=$?
assert_eq "an unresolved docker endpoint does not fail the broad run" "0" "$rc"
assert_contains "an unresolved docker endpoint is refused" "$out" \
  "cannot resolve the Docker endpoint"
assert_not_called "nothing is pruned when endpoint inspection fails" "$d/calls" "prune"
rm -rf "$d"

# A daemon that answers preflight and then goes away is the case that has to
# reach STEPS_FAIL and exit 1 rather than being reported as a clean run.
d="$(new_env)"; : > "$d/calls"; docker_fake "$d"
DOCKER_INFO_FAIL_AFTER=1 out="$(run_sf "$d" --yes --only docker)"; rc=$?
assert_eq "a step that hard-fails exits 1" "1" "$rc"
assert_contains "a hard failure is counted" "$out" "failed:      1"
rm -rf "$d"

# A daemon that accepts the socket and never answers used to hang the
# preflight probe itself, outside every timeout, with the lock held.
d="$(new_env)"; docker_fake "$d"; : > "$d/calls"
started="$(date +%s)"
out="$(DOCKER_INFO_HANG=1 run_sf "$d" --yes --only docker --step-timeout 1)"; rc=$?
elapsed=$(( $(date +%s) - started ))
assert_eq "a hung docker daemon voids the docker step at preflight" "2" "$rc"
assert_contains "the hung daemon is reported as unreachable" "$out" "daemon unreachable"
if (( elapsed <= 20 )); then ok "the daemon probe was bounded (${elapsed}s)"
else err "the run took ${elapsed}s — the daemon probe was not bounded"; fi
rm -rf "$d"

# ===========================================================================
section "xcode (device support, simulators, archive retention)"
xcode_env() {
  local d; d="$(new_env)"
  mkdir -p "$d/home/Library/Developer/Xcode/iOS DeviceSupport/17.0" \
           "$d/home/Library/Developer/CoreSimulator/Caches/dyld" \
           "$d/home/Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive" \
           "$d/home/Library/Developer/Xcode/Archives/2999-01-01/New.xcarchive"
  : > "$d/home/Library/Developer/Xcode/iOS DeviceSupport/17.0/symbols"
  : > "$d/home/Library/Developer/CoreSimulator/Caches/dyld/cache"
  : > "$d/home/Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive/Info.plist"
  : > "$d/home/Library/Developer/Xcode/Archives/2999-01-01/New.xcarchive/Info.plist"
  touch -d '2020-01-01' "$d/home/Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive"
  mkbin "$d/bin/xcrun" 'echo "xcrun $*" >> "$CALLS"; exit 0'
  printf '%s' "$d"
}
d="$(xcode_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only xcode)"; rc=$?
assert_eq "xcode step succeeds" "0" "$rc"
assert_gone   "iOS DeviceSupport is cleared" \
  "$d/home/Library/Developer/Xcode/iOS DeviceSupport/17.0"
assert_gone   "simulator caches are cleared" \
  "$d/home/Library/Developer/CoreSimulator/Caches/dyld"
assert_exists "archives are kept without an explicit retention" \
  "$d/home/Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive"
assert_contains "the run says archives were kept" "$out" "Xcode Archives kept"
assert_not_called "unavailable simulators are kept by default" "$d/calls" "simctl delete unavailable"
assert_contains "the flag that would delete them is named" "$out" \
  "--prune-unavailable-simulators deletes them and their data"
rm -rf "$d"

d="$(xcode_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --prune-xcode-archives-days 30 --only xcode)"; rc=$?
assert_eq "archive pruning succeeds" "0" "$rc"
assert_gone   "an archive older than the retention is removed" \
  "$d/home/Library/Developer/Xcode/Archives/2020-01-01/Old.xcarchive"
assert_exists "a recent archive survives the retention" \
  "$d/home/Library/Developer/Xcode/Archives/2999-01-01/New.xcarchive"
rm -rf "$d"

# ===========================================================================
section "diagnostics (user always, system only with sudo)"
setup_diag() {
  rm -rf /Library/Logs
  mkdir -p /Library/Logs/DiagnosticReports /Library/Logs/CrashReporter
  : > /Library/Logs/DiagnosticReports/panic.ips
  : > /Library/Logs/CrashReporter/app.crash
  mkdir -p "$1/home/Library/Logs/DiagnosticReports" "$1/home/Library/DiagnosticReports"
  : > "$1/home/Library/Logs/DiagnosticReports/user.ips"
  : > "$1/home/Library/DiagnosticReports/other.ips"
}
d="$(new_env)"; : > "$d/calls"; setup_diag "$d"
out="$(run_sf "$d" --yes --only diagnostics)"; rc=$?
assert_eq "diagnostics step succeeds" "0" "$rc"
assert_gone "user diagnostic reports are removed"  "$d/home/Library/Logs/DiagnosticReports/user.ips"
assert_gone "user crash reports are removed"       "$d/home/Library/DiagnosticReports/other.ips"
assert_gone "system diagnostic reports are removed" /Library/Logs/DiagnosticReports/panic.ips
assert_gone "system crash reports are removed"      /Library/Logs/CrashReporter/app.crash
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"; setup_diag "$d"
out="$(run_sf "$d" --yes --no-sudo --only diagnostics)"; rc=$?
assert_eq "diagnostics runs under --no-sudo" "0" "$rc"
assert_gone   "--no-sudo still clears user reports" "$d/home/Library/Logs/DiagnosticReports/user.ips"
assert_exists "--no-sudo leaves system reports alone" /Library/Logs/DiagnosticReports/panic.ips
assert_contains "--no-sudo says why system reports were skipped" "$out" \
  "skipping system diagnostic reports"
rm -rf /Library/Logs
rm -rf "$d"

# ===========================================================================
section "brew (command sequence and environment)"
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/brew" 'echo "brew $*" >> "$CALLS"' \
                    'echo "env HOMEBREW_NO_AUTO_UPDATE=${HOMEBREW_NO_AUTO_UPDATE:-}" >> "$CALLS"' \
                    'case "${1:-}" in --version) echo "Homebrew 4.0.0" ;; --prefix) echo /opt/homebrew ;; esac' \
                    'exit 0'
out="$(run_sf "$d" --yes --only brew)"; rc=$?
assert_eq "brew step succeeds" "0" "$rc"
assert_called "brew step updates"      "$d/calls" "brew update"
assert_called "brew step upgrades formulae" "$d/calls" "brew upgrade --formula"
assert_called "brew step runs a scrub cleanup" "$d/calls" "brew cleanup -s"
assert_called "brew step autoremoves"  "$d/calls" "brew autoremove"
assert_called "brew step disables nested auto-update" "$d/calls" "env HOMEBREW_NO_AUTO_UPDATE=1"
assert_contains "cask upgrades are skipped without a terminal" "$out" \
  "skipping cask upgrades"
assert_not_called "no cask upgrade is attempted without a terminal" "$d/calls" \
  "brew upgrade --cask"
assert_contains "a terminal-less brew run stays clean" "$out" "warn steps:  0"
assert_not_called "no --yes is passed to a brew whose upgrade help lacks it" "$d/calls" \
  "brew upgrade --formula --yes"
assert_contains "the missing --yes flag is reported" "$out" \
  "has no --yes flag"
rm -rf "$d"

# A current Homebrew documents --yes on brew upgrade; --yes runs pass it through
# so the download confirmation does not stall the LaunchAgent.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/brew" 'echo "brew $*" >> "$CALLS"' \
                    'case "${1:-}" in --version) echo "Homebrew 4.0.0" ;; --prefix) echo /opt/homebrew ;; esac' \
                    'case "${1:-} ${2:-}" in "upgrade --help") echo "  --no-ask, --yes, -y  Do not ask for confirmation" ;; esac' \
                    'exit 0'
out="$(run_sf "$d" --yes --only brew)"; rc=$?
assert_eq "brew step succeeds with a --yes-capable brew" "0" "$rc"
assert_called "--yes reaches brew upgrade when the help documents it" "$d/calls" \
  "brew upgrade --formula --yes"
assert_not_contains "no missing-flag notice for a --yes-capable brew" "$out" \
  "has no --yes flag"
rm -rf "$d"

# ===========================================================================
section "brew (git lock and disabled packages)"
brew_lock_env() {
  local d; d="$(new_env)"
  mkdir -p "$d/brewrepo/.git"
  mkbin "$d/bin/brew" 'echo "brew $*" >> "$CALLS"' \
                      'case "${1:-}" in --version) echo "Homebrew 4.0.0" ;; --prefix) echo /opt/homebrew ;; --repository) echo "$BREW_REPO" ;; esac' \
                      'case "${1:-}" in update) [ -e "$BREW_REPO/.git/index.lock" ] && { echo "fatal: Unable to create '"'"'$BREW_REPO/.git/index.lock'"'"': File exists."; echo "error: could not detach HEAD"; echo "Already up-to-date."; } ;; esac' \
                      'case "${1:-} ${2:-}" in "upgrade --formula") echo "Warning: Not upgrading alacritty, it is disabled because it does not pass the macOS Gatekeeper check! It was disabled on 2026-09-01." ;; esac' \
                      'exit 0'
  printf '%s' "$d"
}
# A lock older than five minutes with no git running is stale: removed, said
# so, and brew update then refreshes the taps.
d="$(brew_lock_env)"; : > "$d/calls"
: > "$d/brewrepo/.git/index.lock"
touch -d '10 minutes ago' "$d/brewrepo/.git/index.lock"
out="$(BREW_REPO="$d/brewrepo" run_sf "$d" --yes --only brew)"; rc=$?
assert_eq "brew with a stale git lock succeeds" "0" "$rc"
assert_gone "the stale lock is removed" "$d/brewrepo/.git/index.lock"
assert_contains "the stale lock removal is announced" "$out" "removed a stale Homebrew git lock"
assert_contains "a removed stale lock is not a warning" "$out" "warn steps:  0"
assert_contains "a package Homebrew disabled is named" "$out" "disabled by Homebrew, no longer upgraded"
assert_contains "the disabled package and its reason are shown" "$out" \
  "alacritty: it does not pass the macOS Gatekeeper check"
rm -rf "$d"

# A fresh lock may belong to a live brew in another terminal: left alone,
# named, and the update that then cannot refresh the taps is a warning rather
# than the clean [ ok ] it used to be.
d="$(brew_lock_env)"; : > "$d/calls"
: > "$d/brewrepo/.git/index.lock"
out="$(BREW_REPO="$d/brewrepo" run_sf "$d" --yes --only brew)"; rc=$?
assert_eq "brew with a fresh git lock does not fail the run" "0" "$rc"
assert_exists "a fresh lock is left in place" "$d/brewrepo/.git/index.lock"
assert_contains "the fresh lock is named with the remedy" "$out" "Homebrew git lock present at"
assert_contains "an update that could not refresh the taps is reported" "$out" \
  "brew update did not refresh the taps"
assert_contains "the blocked update is accounted a warning" "$out" "warn steps:  1"
rm -rf "$d"

# ===========================================================================
section "dev-caches (each toolchain, and an unusable node)"
devcache_env() {
  local d; d="$(new_env)"
  mkbin "$d/bin/node"  'echo "node $*" >> "$CALLS"; exit "${NODE_RC:-0}"'
  for t in npm yarn pnpm gem go uv; do
    mkbin "$d/bin/$t" "echo \"$t \$*\" >> \"\$CALLS\"; exit 0"
  done
  # A bun that knows `pm cache`, so the step uses the tool's own command.
  mkbin "$d/bin/bun" 'echo "bun $*" >> "$CALLS"; exit 0'
  mkdir -p "$d/home/.bun/install/cache/pkg"
  bytes_file "$d/home/.bun/install/cache/pkg/tarball.tgz" 256
  # pip prints this even with -q on an already-empty cache. It belongs in the
  # log, not on the terminal of a quiet run.
  mkbin "$d/bin/pip3" 'echo "pip3 $*" >> "$CALLS"; echo "WARNING: No matching packages"; exit 0'
  # minikube re-downloads its ISO, kic base image and preload tarballs on
  # demand; machines/, profiles/ and certs/ are the cluster and its
  # credentials, and clearing those would destroy a running cluster.
  mkdir -p "$d/home/.minikube/cache/iso" "$d/home/.minikube/machines/minikube" \
           "$d/home/.minikube/profiles/minikube" "$d/home/.minikube/certs"
  bytes_file "$d/home/.minikube/cache/iso/minikube-v1.33.iso" 512
  : > "$d/home/.minikube/machines/minikube/config.json"
  : > "$d/home/.minikube/profiles/minikube/config.json"
  : > "$d/home/.minikube/certs/client.pem"
  mkdir -p "$d/home/.kube/cache/discovery/cluster_a" "$d/home/.kube/cache/http"
  : > "$d/home/.kube/cache/discovery/cluster_a/servergroups.json"
  : > "$d/home/.kube/cache/http/entry"
  : > "$d/home/.kube/config"
  mkbin "$d/bin/pre-commit" 'echo "pre-commit $*" >> "$CALLS"; exit 0'
  mkdir -p "$d/home/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/null/3.2.0"
  : > "$d/home/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/null/3.2.0/provider"
  mkdir -p "$d/home/.config/gcloud/logs/2026.08.01" "$d/home/.config/gcloud/logs/recent"
  : > "$d/home/.config/gcloud/logs/2026.08.01/cmd.log"
  : > "$d/home/.config/gcloud/logs/recent/cmd.log"
  touch -d '30 days ago' "$d/home/.config/gcloud/logs/2026.08.01" "$d/home/.config/gcloud/logs/2026.08.01/cmd.log"
  printf '%s' "$d"
}
d="$(devcache_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only dev-caches)"; rc=$?
assert_eq "dev-caches step succeeds" "0" "$rc"
assert_contains "bun's own cache command is used when it has one" \
  "$(grep '^bun ' "$d/calls")" "pm cache rm"
assert_gone   "the minikube cache is cleared" "$d/home/.minikube/cache/iso"
assert_exists "the minikube cache directory itself stays" "$d/home/.minikube/cache"
assert_exists "the minikube machines are untouched" "$d/home/.minikube/machines/minikube/config.json"
assert_exists "the minikube profiles are untouched" "$d/home/.minikube/profiles/minikube/config.json"
assert_exists "the minikube certificates are untouched" "$d/home/.minikube/certs/client.pem"
assert_called "npm cache is cleaned"   "$d/calls" "npm cache clean --force"
assert_called "yarn cache is cleaned"  "$d/calls" "yarn cache clean"
assert_called "pnpm store is pruned"   "$d/calls" "pnpm store prune"
assert_called "pip cache is purged"    "$d/calls" "pip3 cache purge"
assert_not_contains "pip's empty-cache notice stays out of a quiet run" "$out" \
  "WARNING: No matching packages"
assert_called "uv cache is cleaned"    "$d/calls" "uv cache clean"
assert_not_called "installed gems are kept by default" "$d/calls" "gem cleanup"
assert_contains "the run explains how to clean old gems explicitly" "$out" \
  "pass --cleanup-old-gems"
assert_called "go caches are cleaned"  "$d/calls" "go clean -cache -modcache -testcache"
assert_gone   "kubectl discovery cache is cleared" "$d/home/.kube/cache/discovery"
assert_gone   "kubectl http cache is cleared"      "$d/home/.kube/cache/http"
assert_exists "~/.kube/cache itself is kept"       "$d/home/.kube/cache"
assert_exists "~/.kube/config is untouched"        "$d/home/.kube/config"
assert_gone   "the Terraform provider cache is cleared" "$d/home/.terraform.d/plugin-cache/registry.terraform.io"
assert_exists "the Terraform plugin-cache directory itself is kept" "$d/home/.terraform.d/plugin-cache"
assert_gone   "a gcloud log directory older than a week goes" "$d/home/.config/gcloud/logs/2026.08.01"
assert_exists "a recent gcloud log directory is kept" "$d/home/.config/gcloud/logs/recent"
assert_called "pre-commit garbage-collects its repos" "$d/calls" "pre-commit gc"
assert_contains "dev-caches stays clean with pip's notice" "$out" "warn steps:  0"
rm -rf "$d"

# Under --verbose the pip line is still filtered from the live stream, while
# the rest of pip's output would reach the terminal like every other command.
d="$(devcache_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --verbose --only dev-caches)"; rc=$?
assert_eq "dev-caches step succeeds under --verbose" "0" "$rc"
assert_not_contains "pip's empty-cache notice is filtered under --verbose" "$out" \
  "WARNING: No matching packages"
rm -rf "$d"

# A dev-caches run on a machine without kubectl state must not invent one.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/go" 'echo "go $*" >> "$CALLS"; exit 0'
out="$(run_sf "$d" --yes --only dev-caches)"; rc=$?
assert_eq "dev-caches without a kube cache succeeds" "0" "$rc"
assert_gone "no ~/.kube is created when none existed" "$d/home/.kube"
rm -rf "$d"

d="$(devcache_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only dev-caches --cleanup-old-gems)"; rc=$?
assert_eq "explicit old-gem cleanup succeeds" "0" "$rc"
assert_called "explicit old-gem cleanup runs gem cleanup" "$d/calls" "gem cleanup"
rm -rf "$d"

# A node that is on PATH but cannot run is the common broken-Homebrew state.
# The npm/yarn/pnpm cleaners must be skipped and the step must report WARN, not
# a clean OK.
d="$(devcache_env)"; : > "$d/calls"
NODE_RC=1 out="$(run_sf "$d" --yes --only dev-caches)"; rc=$?
assert_eq "an unusable node does not fail the run" "0" "$rc"
assert_contains "an unusable node is reported" "$out" "node is not runnable"
assert_not_called "npm cache clean is skipped when node is broken" "$d/calls" "npm cache clean"
assert_contains "the step is accounted as a warning" "$out" "warn steps:  1"
rm -rf "$d"

# ===========================================================================
section "helm-plugins"
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/helm" 'echo "helm $*" >> "$CALLS"' \
                    'case "${1:-} ${2:-}" in' \
                    '  "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n"; printf "secrets\t4.5\n"; exit 0 ;;' \
                    '  "plugin update") exit "${HELM_UPDATE_RC:-0}" ;;' \
                    'esac' \
                    'exit 0'
out="$(run_sf "$d" --yes --only helm-plugins)"; rc=$?
assert_eq "helm-plugins step succeeds" "0" "$rc"
assert_called "the first installed plugin is updated"  "$d/calls" "helm plugin update diff"
assert_called "the second installed plugin is updated" "$d/calls" "helm plugin update secrets"
rm -rf "$d"

# ===========================================================================
section "krew (kubectl plugin refresh)"
krew_env() {
  local d; d="$(new_env)"
  # The table shape krew prints to a terminal; the pipe shape is names only,
  # and the parser has to take both.
  mkbin "$d/bin/kubectl" 'echo "kubectl $*" >> "$CALLS"' \
    'case "${1:-} ${2:-}" in' \
    '  "krew list") printf "PLUGIN  VERSION\n"; printf "ctx  v0.9.5\n"; printf "ns  v0.9.5\n"; exit 0 ;;' \
    '  "krew update") exit 0 ;;' \
    '  "krew upgrade") exit "${KREW_UPGRADE_RC:-0}" ;;' \
    'esac; exit 0'
  mkbin "$d/bin/kubectl-krew" 'exit 0'
  printf '%s' "$d"
}
d="$(krew_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only krew)"; rc=$?
assert_eq "krew step succeeds" "0" "$rc"
assert_called "the krew index is refreshed first" "$d/calls" "kubectl krew update"
assert_called "the first installed plugin is upgraded"  "$d/calls" "kubectl krew upgrade ctx"
assert_called "the second installed plugin is upgraded" "$d/calls" "kubectl krew upgrade ns"
assert_not_called "the table header is not taken for a plugin" "$d/calls" "kubectl krew upgrade PLUGIN"
rm -rf "$d"

d="$(krew_env)"; : > "$d/calls"
out="$(KREW_UPGRADE_RC=1 run_sf "$d" --yes --only krew)"; rc=$?
assert_eq "a failed plugin upgrade does not fail the run" "0" "$rc"
assert_contains "a failed plugin upgrade is accounted a warning" "$out" "warn steps:  1"
rm -rf "$d"

# --skip-devtools covers krew like the other refresh steps.
d="$(krew_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --no-sudo --skip-devtools --skip-dns --skip-syscaches \
  --skip-usercaches --skip-appcaches --skip-aicaches --skip-workspacestorage \
  --skip-trash --skip-brew --skip-devcaches --skip-snapshots --skip-docker \
  --skip-xcode --skip-diagnostics --skip-os-updates)"; rc=$?
assert_eq "--skip-devtools run succeeds" "0" "$rc"
assert_not_called "--skip-devtools skips krew" "$d/calls" "kubectl krew"
rm -rf "$d"

# kubectl without krew, and no kubectl at all, are both clean steps.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/kubectl" 'echo "kubectl $*" >> "$CALLS"; exit 0'
out="$(run_sf "$d" --yes --only krew)"; rc=$?
assert_eq "krew step without krew succeeds" "0" "$rc"
assert_contains "krew step without krew says so" "$out" "krew not installed"
assert_not_called "nothing is run through kubectl without krew" "$d/calls" "kubectl krew"
rm -rf "$d"

# ===========================================================================
section "step timeout (a hung command is stopped, its children with it)"
# A plugin update that never returns stands in for brew, gcloud or
# softwareupdate hanging on the network. The run has no terminal here, as the
# agent has none, so the command runs in its own process group and the sleep
# it forked must go with it: an orphan would hold the log open and the space.
# /proc rather than ps: the tester image has no procps, and a probe that
# cannot run would report every orphan as dead. A zombie is dead enough: it
# holds no file and no CPU, only a pid until init reaps it.
proc_alive() {
  [[ -d "/proc/$1" ]] || return 1
  [[ "$(awk '/^State:/ { print $2 }' "/proc/$1/status" 2>/dev/null)" != Z* ]]
}
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/helm" 'case "${1:-} ${2:-}" in' \
  '  "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n"; exit 0 ;;' \
  '  "plugin update") sleep 60 & echo $! > "$CALLS.sleep"; wait ;;' \
  'esac; exit 0'
started="$(date +%s)"
out="$(run_sf "$d" --yes --only helm-plugins --step-timeout 1)"; rc=$?
elapsed=$(( $(date +%s) - started ))
assert_eq "a timed-out step does not fail the run" "0" "$rc"
assert_contains "the timeout is reported with the limit" "$out" \
  "helm plugin update diff stopped after 1s (--step-timeout)"
assert_contains "a timed-out step is accounted a warning" "$out" "warn steps:  1"
if (( elapsed <= 20 )); then ok "the run returned promptly (${elapsed}s)"
else err "the run took ${elapsed}s — the timeout did not stop the command"; fi
sleep_pid="$(cat "$d/calls.sleep" 2>/dev/null)"
if [[ -n "$sleep_pid" ]] && proc_alive "$sleep_pid"; then
  err "the hung command's child (pid $sleep_pid) outlived the timeout"; kill "$sleep_pid" 2>/dev/null
else ok "the hung command's child was stopped with it"; fi
saved="$(find "$d/home/Library/Logs/stay_fresh" -name 'stay_fresh-*.log' | head -n 1)"
assert_contains "the kept log records the timeout" "$(cat "$saved" 2>/dev/null)" \
  "stopped after 1s by --step-timeout"
rm -rf "$d"

# A probe whose output the step parses (capture_cmd) is under the same limit
# and counts the same way: the help says the step is warned, and the agent's
# --fail-on-warn depends on it. It used to be reported and then booked [ ok ].
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/softwareupdate" 'echo "softwareupdate $*" >> "$CALLS"; sleep 60'
started="$(date +%s)"
out="$(run_sf "$d" --yes --only os-updates --step-timeout 1 --fail-on-warn)"; rc=$?
elapsed=$(( $(date +%s) - started ))
assert_eq "a timed-out probe fails a --fail-on-warn run" "1" "$rc"
assert_contains "the timed-out probe is reported" "$out" "softwareupdate --list stopped after 1s (--step-timeout)"
assert_contains "a timed-out probe counts as a warning" "$out" "warn steps:  1"
if (( elapsed <= 20 )); then ok "the probe was stopped promptly (${elapsed}s)"
else err "the run took ${elapsed}s — the probe timeout did not fire"; fi
rm -rf "$d"

# A command run through sudo belongs to root, and the unprivileged watchdog
# cannot signal it: the kill is refused, the wrapper waited for the command
# to finish on its own, and then reported a timeout for work that completed.
# The stop goes through `sudo -n kill` for those, on the credential the
# preflight warmed. The fake sudo records the call and execs it.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/tmutil" 'echo "tmutil $*" >> "$CALLS"' \
  'case "${1:-}" in' \
  '  listlocalsnapshots) echo "Snapshots for disk /:"; echo "com.apple.TimeMachine.2026-09-01-101010.local" ;;' \
  '  status) echo "{ Running = 0; }" ;;' \
  '  deletelocalsnapshots) sleep 60 ;;' \
  'esac; exit 0'
started="$(date +%s)"
out="$(run_sf "$d" --yes --only snapshots --thin-snapshots --step-timeout 1)"; rc=$?
elapsed=$(( $(date +%s) - started ))
assert_eq "a timed-out sudo command does not fail the run" "0" "$rc"
assert_called "a sudo command is stopped through sudo" "$d/calls" "sudo kill -TERM --"
assert_contains "the stopped sudo command is reported" "$out" "stopped after 1s (--step-timeout)"
if (( elapsed <= 20 )); then ok "the sudo command was stopped promptly (${elapsed}s)"
else err "the run took ${elapsed}s — the sudo command was not stopped"; fi
rm -rf "$d"

# Ctrl-C. A terminal delivers SIGINT to the whole foreground process group:
# the script, the wrapper and, at a terminal, the command. The wrapper stops
# the command and then dies of SIGINT itself; bash then sees a child killed
# by the interrupt and aborts the run, releasing the lock. The wrapper used
# to exit 130 normally instead, which bash reads as "the child handled it":
# the interrupted command was booked a warning and the run went on to the
# next step, and the next, one Ctrl-C per command.
#
# setsid gives the run a process group of its own to signal; perl resets the
# disposition first, because a background job inherits SIGINT ignored from
# a non-interactive shell and the run would otherwise never see it.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/helm" 'case "${1:-} ${2:-}" in' \
  '  "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n"; exit 0 ;;' \
  '  "plugin update") sleep 60 & echo $! > "$CALLS.sleep"; echo started > "$CALLS.started"; wait ;;' \
  'esac; exit 0'
HOME="$d/home" TMPDIR="$d/tmp" PATH="$d/bin:/usr/bin:/bin" CALLS="$d/calls" NO_COLOR=1 \
  STAY_FRESH_NOTIFY=none SF="$SF" \
  setsid perl -e '$SIG{INT} = "DEFAULT"; exec $ENV{SF}, "--yes", "--no-sudo", "--only", "helm-plugins,versions"' \
  <"/dev/null" >"$d/calls.out" 2>&1 &
run_pid=$!
for _ in $(seq 1 100); do [[ -f "$d/calls.started" ]] && break; sleep 0.1; done
run_pgid="$(awk '{ print $5 }' "/proc/$run_pid/stat" 2>/dev/null)"
if [[ -f "$d/calls.started" && -n "$run_pgid" ]]; then
  kill -INT -- "-$run_pgid"
  for _ in $(seq 1 100); do kill -0 "$run_pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$run_pid" 2>/dev/null; then
    err "the run survived Ctrl-C"; kill -9 -- "-$run_pgid" 2>/dev/null; wait "$run_pid" 2>/dev/null
  else
    wait "$run_pid"; rc=$?
    assert_eq "Ctrl-C ends the run with 130" "130" "$rc"
    assert_not_contains "an interrupted run reaches no summary" "$(cat "$d/calls.out")" "stay_fresh: summary"
    assert_not_contains "an interrupted run does not go on to the next step" "$(cat "$d/calls.out")" "Active tool versions"
  fi
  sleep_pid="$(cat "$d/calls.sleep" 2>/dev/null)"
  if [[ -n "$sleep_pid" ]] && proc_alive "$sleep_pid"; then
    err "the interrupted command's child (pid $sleep_pid) survived"; kill "$sleep_pid" 2>/dev/null
  else ok "the interrupted command's child was stopped with it"; fi
  if [[ ! -d "$d/home/Library/Application Support/stay_fresh/run.lock" ]]; then
    ok "the lock is released on Ctrl-C"
  else err "the lock survived Ctrl-C"; fi
else
  err "the interruptible command never started"; kill -9 "$run_pid" 2>/dev/null
fi
rm -rf "$d"

# 0 disables the limit, and a fast command under the default limit is untouched.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/helm" 'echo "helm $*" >> "$CALLS"' \
  'case "${1:-} ${2:-}" in "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n" ;; esac; exit 0'
out="$(run_sf "$d" --yes --only helm-plugins --step-timeout 0)"; rc=$?
assert_eq "--step-timeout 0 runs the step" "0" "$rc"
assert_called "--step-timeout 0 still runs the command" "$d/calls" "helm plugin update diff"
assert_not_contains "--step-timeout 0 stops nothing" "$out" "stopped after"
out="$(run_sf "$d" --yes --only helm-plugins)"; rc=$?
assert_not_contains "a fast command is untouched by the default limit" "$out" "stopped after"
assert_contains "the fast run is clean" "$out" "warn steps:  0"
rm -rf "$d"

# Without perl the limit cannot be enforced; that is said once before the
# run, and the run itself is unaffected.
d="$(new_env)"; : > "$d/calls"
mkdir -p "$d/nobin"
for b in /usr/bin/* /bin/*; do
  [[ "$(basename "$b")" == perl* ]] && continue
  ln -sf "$b" "$d/nobin/$(basename "$b")" 2>/dev/null || true
done
mkbin "$d/bin/helm" 'echo "helm $*" >> "$CALLS"' \
  'case "${1:-} ${2:-}" in "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n" ;; esac; exit 0'
out="$(HOME="$d/home" TMPDIR="$d/tmp" PATH="$d/bin:$d/nobin" CALLS="$d/calls" NO_COLOR=1 \
  STAY_FRESH_NOTIFY=none "$SF" --yes --no-sudo --only helm-plugins </dev/null 2>&1)"; rc=$?
assert_eq "a run without perl succeeds" "0" "$rc"
assert_contains "the missing perl is said before the run" "$out" \
  "perl not found — --step-timeout cannot be enforced"
assert_called "the command still runs without the wrapper" "$d/calls" "helm plugin update diff"
out="$(HOME="$d/home" TMPDIR="$d/tmp" PATH="$d/bin:$d/nobin" CALLS="$d/calls" NO_COLOR=1 \
  STAY_FRESH_NOTIFY=none "$SF" --yes --no-sudo --only helm-plugins --step-timeout 0 </dev/null 2>&1)"
assert_not_contains "with the limit off, missing perl is not mentioned" "$out" "perl not found"
rm -rf "$d"

# ===========================================================================
section "gcloud"
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/gcloud" 'echo "gcloud $*" >> "$CALLS"' \
                      'case "${1:-} ${2:-}" in' \
                      '  "components list") exit 0 ;;' \
                      '  "components update") exit "${GCLOUD_COMPONENTS_RC:-0}" ;;' \
                      '  "help components") exit 1 ;;' \
                      'esac' \
                      'exit 0'
out="$(run_sf "$d" --yes --only gcloud)"; rc=$?
assert_eq "gcloud step succeeds" "0" "$rc"
assert_called "gcloud components are updated" "$d/calls" "gcloud components update --quiet"
assert_not_called "an unsupported macos-python update is not attempted" "$d/calls" \
  "gcloud components update-macos-python --quiet"
rm -rf "$d"

# ===========================================================================
section "versions (read-only reporting)"
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/pyenv" 'echo 3.12.1'
mkbin "$d/bin/goenv" 'echo 1.22.0'
mkbin "$d/bin/tfenv" 'echo 1.7.5'
mkbin "$d/bin/helm"  'echo "v3.14.0"'
mkbin "$d/bin/kubectl" 'case "$*" in "version --client") echo "Client Version: v1.31.2" ;; "krew version") printf "OPTION VALUE\nGitTag v0.4.4\n" ;; esac'
mkbin "$d/bin/kubectl-krew" 'exit 0'
mkbin "$d/bin/terraform" 'echo "terraform $*" >> "$CALLS"; echo "env CHECKPOINT_DISABLE=${CHECKPOINT_DISABLE:-}" >> "$CALLS"; echo "Terraform v1.9.5"; echo "on darwin_arm64"'
mkbin "$d/bin/docker" 'echo "Docker version 27.3.1, build ce12230"'
out="$(run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "versions step succeeds" "0" "$rc"
assert_contains "the active python version is reported"    "$out" "pyenv active:  3.12.1"
assert_contains "the active go version is reported"        "$out" "goenv active:  1.22.0"
assert_contains "the active terraform version is reported" "$out" "tfenv active:  1.7.5"
assert_contains "the kubectl client version is reported"   "$out" "kubectl:       v1.31.2"
assert_contains "the krew version is reported"             "$out" "krew:          v0.4.4"
assert_contains "the terraform binary version is reported" "$out" "terraform:     v1.9.5"
assert_contains "the docker version is reported"           "$out" "docker:        27.3.1"
assert_called "terraform is asked without phoning home" "$d/calls" "env CHECKPOINT_DISABLE=1"
rm -rf "$d"

# ===========================================================================
section "os-updates (read-only report of pending macOS / App Store updates)"
# softwareupdate --list writes the label lines to stderr on a real Mac and the
# "No new software available." verdict to stdout; both are captured together.
os_env() {
  local d; d="$(new_env)"
  mkbin "$d/bin/softwareupdate" 'echo "softwareupdate $*" >> "$CALLS"' \
    'if [ -n "${SU_RC:-}" ]; then echo "Failed to check for updates" >&2; exit "$SU_RC"; fi' \
    'if [ -n "${SU_PENDING:-}" ]; then' \
    '  echo "Software Update Tool"' \
    '  echo "Finding available software"' \
    '  echo "Software Update found the following new or updated software:" >&2' \
    '  echo "* Label: macOS Sequoia 15.6.1-24G90" >&2' \
    '  echo "	Title: macOS Sequoia 15.6.1, Version: 15.6.1, Size: 1234567KiB, Recommended: YES, Action: restart," >&2' \
    'else' \
    '  echo "Software Update Tool"' \
    '  echo "No new software available."' \
    'fi; exit 0'
  mkbin "$d/bin/mas" 'echo "mas $*" >> "$CALLS"' \
    'if [ -n "${MAS_RC:-}" ]; then echo "Error: not signed in" >&2; exit "$MAS_RC"; fi' \
    'if [ -n "${MAS_STDERR:-}" ]; then echo "Warning: could not look up an app" >&2; fi' \
    'if [ -n "${MAS_PENDING:-}" ]; then echo "497799835 Xcode (16.4 -> 26.0)"; fi; exit 0'
  printf '%s' "$d"
}
run_os() {
  local d="$1"; shift
  SU_PENDING="${SU_PENDING:-}" SU_RC="${SU_RC:-}" MAS_PENDING="${MAS_PENDING:-}" MAS_RC="${MAS_RC:-}" \
    MAS_STDERR="${MAS_STDERR:-}" \
    run_sf "$d" "$@"
}
d="$(os_env)"; : > "$d/calls"
out="$(run_os "$d" --yes --only os-updates)"; rc=$?
assert_eq "os-updates step succeeds when everything is current" "0" "$rc"
assert_called "os-updates queries softwareupdate" "$d/calls" "softwareupdate --list"
assert_called "os-updates queries mas"            "$d/calls" "mas outdated"
assert_contains "an up-to-date macOS is reported as such" "$out" "macOS is up to date"
assert_contains "up-to-date App Store apps are reported"  "$out" "App Store apps are up to date"
assert_not_called "os-updates never installs macOS updates" "$d/calls" "softwareupdate --install"
assert_not_called "os-updates never upgrades App Store apps" "$d/calls" "mas upgrade"
rm -rf "$d"

d="$(os_env)"; : > "$d/calls"
out="$(SU_PENDING=1 MAS_PENDING=1 run_os "$d" --yes --only os-updates)"; rc=$?
assert_eq "pending updates do not fail the run" "0" "$rc"
assert_contains "a pending macOS update is named" "$out" "macOS Sequoia 15.6.1-24G90"
assert_contains "the macOS install path is given" "$out" "sudo softwareupdate --install --all"
assert_contains "a pending App Store update is named" "$out" "Xcode (16.4 -> 26.0)"
assert_contains "the App Store install path is given" "$out" "mas upgrade"
# Pending updates are the normal state of a workstation between patch days,
# not a fault: the scheduled agent runs with --fail-on-warn and must not go
# red every morning until somebody reboots into an update.
assert_contains "pending updates are information, not a warning" "$out" "warn steps:  0"
assert_not_called "pending updates are still never installed" "$d/calls" "softwareupdate --install"
rm -rf "$d"

d="$(os_env)"; : > "$d/calls"
out="$(SU_RC=1 MAS_RC=1 run_os "$d" --yes --only os-updates)"; rc=$?
assert_eq "an unreachable update server does not fail the run" "0" "$rc"
assert_contains "a failed macOS query is reported" "$out" "could not query macOS updates"
assert_contains "a failed App Store query is reported" "$out" "could not query App Store updates"
# Reported, not counted: the agent runs with --fail-on-warn, and a Mac with mas
# installed but no App Store sign-in must not fail every scheduled run.
assert_contains "a failed query does not count against the step" "$out" "warn steps:  0"
rm -rf "$d"

d="$(os_env)"; : > "$d/calls"
out="$(MAS_STDERR=1 run_os "$d" --yes --only os-updates)"; rc=$?
assert_eq "mas stderr chatter does not fail the run" "0" "$rc"
assert_not_contains "mas stderr chatter is not reported as a pending update" "$out" \
  "App Store updates pending"
assert_contains "mas stderr chatter still leaves the apps reported current" "$out" \
  "App Store apps are up to date"
rm -rf "$d"

# A dry run answers quickly and touches nothing: the catalogue scan is a
# system action and is only named, not run.
d="$(os_env)"; : > "$d/calls"
out="$(run_os "$d" --dry-run --only os-updates)"; rc=$?
assert_eq "os-updates dry run succeeds" "0" "$rc"
assert_not_called "a dry run does not scan for macOS updates" "$d/calls" "softwareupdate"
assert_not_called "a dry run does not query mas" "$d/calls" "mas"
assert_contains "a dry run names the softwareupdate probe" "$out" "(dry-run) softwareupdate --list"
rm -rf "$d"

# Neither tool present: still a clean step, and it says so.
d="$(new_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only os-updates)"; rc=$?
assert_eq "os-updates with no tools succeeds" "0" "$rc"
assert_contains "os-updates with no tools says nothing to report" "$out" \
  "neither softwareupdate nor mas is available"
rm -rf "$d"

# ===========================================================================
section "quick preset, history, verdict"
# --quick is a fixed --only list: the user-level cleanup, nothing that needs
# sudo, Homebrew or the network.
d="$(new_env)"
out="$(run_sf "$d" --dry-run --quick)"; rc=$?
assert_eq "--quick previews" "0" "$rc"
for want in "clear user caches" "clear per-app caches" "clear AI tool caches" \
            "prune workspace storage" "empty trash" "old user logs" "dev-tool caches"; do
  assert_contains "--quick runs: $want" "$(grep "$want" <<<"$out")" "run"
done
for keep in "homebrew update" "flush DNS" "clear system caches" "pending OS" "docker" "xcode"; do
  assert_contains "--quick skips: $keep" "$(grep -i "$keep" <<<"$out")" "skip"
done
# --quick's help says "No sudo (not even a cached credential)". The only thing
# enforcing that is one QUICK == 0 in clear_dir's retry condition, and the
# retry's other arm reaches for a warm timestamp with `sudo -n true`. Run it
# for real against an entry the user cannot unlink, with a sudo that would
# answer if asked.
qd="$(new_env)"; : > "$qd/calls"
mkbin "$qd/bin/rm" 'fail=0; opts=""' \
                   'for a in "$@"; do' \
                   '  case "$a" in' \
                   '    -*) opts="$opts $a" ;;' \
                   '    *"ShipIt"*) echo "rm: $a: Permission denied" >&2; fail=1 ;;' \
                   '    *) /bin/rm $opts "$a" ;;' \
                   '  esac' \
                   'done' \
                   'exit $fail'
mkbin "$qd/bin/sudo" 'echo "sudo $*" >> "$CALLS"' \
                     'case "${1:-}" in -v) exit 0 ;; -n) shift; case "${1:-}" in true) exit 0 ;; esac ;; esac' \
                     'exec "$@"'
mkdir -p "$qd/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt" "$qd/home/Library/Caches/vendor"
: > "$qd/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt/update"
bytes_file "$qd/home/Library/Caches/vendor/blob" 64
out="$(run_sf "$qd" --yes --quick)"; rc=$?
assert_eq "--quick runs for real" "0" "$rc"
assert_not_called "--quick never reaches for sudo, warm or otherwise" "$qd/calls" "sudo"
assert_exists "--quick leaves the entry it cannot unlink" "$qd/home/Library/Caches/com.tinyspeck.slackmacgap.ShipIt"
assert_gone   "--quick still clears what it can" "$qd/home/Library/Caches/vendor"
assert_contains "--quick reports the entry it could not take" "$out" "entries owned by another user remain"
rm -rf "$qd"

run_sf "$d" --dry-run --quick --only trash >/dev/null; rc=$?
assert_eq "--quick refuses --only" "3" "$rc"
run_sf "$d" --dry-run --quick --skip-brew >/dev/null; rc=$?
assert_eq "--quick refuses --skip-* flags" "3" "$rc"
run_sf "$d" --dry-run --notify pager >/dev/null; rc=$?
assert_eq "an unknown --notify mode is refused" "3" "$rc"
out="$(run_sf "$d" --dry-run --notify macos,pager)"; rc=$?
assert_eq "an unknown channel in a --notify list is refused" "3" "$rc"
assert_contains "the unknown channel is named" "$out" "(got: pager)"
run_sf "$d" --dry-run --notify none,macos >/dev/null; rc=$?
assert_eq "--notify none does not combine with a channel" "3" "$rc"
run_sf "$d" --dry-run --notify auto,slack >/dev/null; rc=$?
assert_eq "--notify auto does not combine with a channel" "3" "$rc"
# The environment variable goes through the same check as the flag: `30m`
# used to become a 30-second limit through perl, and `abc` disabled it.
out="$(STAY_FRESH_STEP_TIMEOUT=30m run_sf "$d" --dry-run --only versions)"; rc=$?
assert_eq "a non-numeric STAY_FRESH_STEP_TIMEOUT is refused" "3" "$rc"
assert_contains "the refused environment value is named" "$out" "STAY_FRESH_STEP_TIMEOUT must be a whole number of seconds (got: 30m)"
run_sf "$d" --dry-run --only versions --step-timeout 30m >/dev/null; rc=$?
assert_eq "a non-numeric --step-timeout is refused" "3" "$rc"
out="$(STAY_FRESH_STEP_TIMEOUT=600 run_sf "$d" --dry-run --only versions)"; rc=$?
assert_eq "a numeric STAY_FRESH_STEP_TIMEOUT is accepted" "0" "$rc"
out="$(run_sf "$d" --dry-run --notify=macos,slack --only versions)"; rc=$?
assert_eq "a channel list is accepted" "0" "$rc"
assert_contains "a dry run names every channel it would use" "$out" "would notify via macos, slack"
rm -rf "$d"

# --reports is the read-only preset: the four reporting steps, nothing that
# deletes or upgrades, and no way to smuggle --thin-snapshots into it.
d="$(new_env)"
out="$(run_sf "$d" --dry-run --reports)"; rc=$?
assert_eq "--reports previews" "0" "$rc"
for want in "report active versions" "pending OS / App Store updates" \
            "local Time Machine snapshots" "old downloads" "orphaned launch agents" "disk report"; do
  assert_contains "--reports runs: $want" "$(grep "$want" <<<"$out")" "run"
done
for keep in "clear user caches" "empty trash" "homebrew update" "dev-tool caches" "old user logs"; do
  assert_contains "--reports skips: $keep" "$(grep -i "$keep" <<<"$out")" "skip"
done
run_sf "$d" --dry-run --reports --only trash >/dev/null; rc=$?
assert_eq "--reports refuses --only" "3" "$rc"
run_sf "$d" --dry-run --reports --quick >/dev/null; rc=$?
assert_eq "--reports refuses --quick" "3" "$rc"
run_sf "$d" --dry-run --reports --skip-brew >/dev/null; rc=$?
assert_eq "--reports refuses --skip-* flags" "3" "$rc"
out="$(run_sf "$d" --dry-run --reports --thin-snapshots)"; rc=$?
assert_eq "--reports refuses --thin-snapshots" "3" "$rc"
assert_contains "--reports says why it refuses --thin-snapshots" "$out" "read-only"
run_sf "$d" --dry-run --reports --prune-downloads-days 30 >/dev/null; rc=$?
assert_eq "--reports refuses --prune-downloads-days" "3" "$rc"
run_sf "$d" --dry-run --reports --prune-orphan-agents >/dev/null; rc=$?
assert_eq "--reports refuses --prune-orphan-agents" "3" "$rc"
out="$(run_sf "$d" --yes --reports)"; rc=$?
assert_eq "a real --reports run succeeds" "0" "$rc"
assert_contains "a real --reports run runs the six reporting steps" "$out" "6 ok, 17 skipped"
# The history row and last-run.json are the only files a real run leaves.
if [[ -z "$(find "$d/home" -type f -not -path '*/Library/Logs/stay_fresh/*' -print -quit)" ]]; then
  ok "--reports writes nothing but its own history"
else
  err "--reports wrote outside its state directory"; find "$d/home" -type f >&2
fi
rm -rf "$d"

# A dry run adds up what the deletions would remove, so the preview answers
# the question it is run for: how much would this free.
d="$(new_env)"
mkdir -p "$d/home/Library/Caches/com.vendor.app" "$d/home/.Trash"
bytes_file "$d/home/Library/Caches/com.vendor.app/blob" 2048
bytes_file "$d/home/.Trash/old" 1024
out="$(run_sf "$d" --dry-run --only user-caches,trash)"; rc=$?
assert_eq "a dry run with an estimate succeeds" "0" "$rc"
assert_contains "the dry run totals what would go" "$(grep 'would free:' <<<"$out")" "3."
assert_contains "the estimate names its unit" "$out" "would free:"
assert_contains "the real freed total stays zero under a dry run" "$out" "steps freed: 0B"
assert_exists "the estimate removed nothing" "$d/home/Library/Caches/com.vendor.app/blob"
rm -rf "$d"

# Every id --list-steps prints is one --only accepts, and the run loop runs
# the step under the same label the plan used. One table drives all three;
# this is the check that nothing bypasses it.
d="$(new_env)"
ids="$(run_sf "$d" --list-steps | awk '{ print $1 }')"
assert_eq "--list-steps prints twenty-three ids" "23" "$(grep -c . <<<"$ids")"
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  extra=(); [[ "$id" == memory ]] && extra=(--purge-memory)
  out="$(run_sf "$d" --dry-run --only "$id" ${extra[@]+"${extra[@]}"})"; rc=$?
  assert_eq "--only $id is accepted" "0" "$rc"
  # Exactly the one step in the plan - or none, when preflight found the
  # machine cannot run it (no Homebrew, no Docker, no Xcode data here), in
  # which case the selection is named as voided rather than dropped quietly.
  runs="$(grep -cE '^  [^ ].{33} run( |$)' <<<"$out")"
  if [[ "$runs" == "1" ]]; then
    ok "--only $id previews exactly one step"
  elif [[ "$runs" == "0" ]]; then
    assert_contains "--only $id is voided by preflight, and says so" "$out" "--only $id: "
  else
    err "--only $id previews $runs steps"
  fi
done <<<"$ids"
rm -rf "$d"

# History: nothing before the first real run, one row and a JSON summary after.
d="$(new_env)"
out="$(run_sf "$d" --history)"; rc=$?
assert_eq "--history works before any run" "0" "$rc"
assert_contains "--history says when there is nothing yet" "$out" "no history yet"
out="$(run_sf "$d" --dry-run --only versions)"
assert_gone "a dry run records no history" "$d/home/Library/Logs/stay_fresh/history.tsv"
assert_gone "a dry run records no per-step figures either" "$d/home/Library/Logs/stay_fresh/steps.tsv"
# The kernel boot time feeds the "up Nd Nh" part of the verdict.
mkbin "$d/bin/sysctl" 'echo "{ sec = $(( $(date +%s) - 93600 )), usec = 0 } Mon Sep  7 10:00:00 2026"'
out="$(run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a real run succeeds" "0" "$rc"
assert_contains "the verdict line is printed" "$out" "stay_fresh OK: freed"
assert_contains "the verdict counts the steps" "$out" "1 ok, 22 skipped"
assert_contains "the verdict carries the uptime" "$out" "up 1d 2h"
hist="$d/home/Library/Logs/stay_fresh/history.tsv"
assert_exists "history.tsv is written" "$hist"
assert_eq "history has one row" "1" "$(wc -l <"$hist" | tr -d ' ')"
assert_contains "the history row carries the result" "$(cut -f2 "$hist")" "OK"
# The thirteenth column is free space after the run. RECLAIMED_B beside it is a
# delta, and a delta alone cannot say whether the disk is filling up anyway.
if [[ "$(cut -f13 "$hist")" =~ ^[0-9]+$ ]]; then
  ok "the history row records free space after the run"
else
  err "the history row has no free-space column: [$(cut -f13 "$hist")]"
fi
# One row per step per run, in its own file: the row count differs from
# history.tsv's, and a separate file needs no migration for rows already there.
steps_tsv="$d/home/Library/Logs/stay_fresh/steps.tsv"
assert_exists "steps.tsv is written" "$steps_tsv"
assert_eq "the run that ran one step recorded one step row" "1" \
  "$(wc -l <"$steps_tsv" | tr -d ' ')"
assert_eq "the step row names the step by id" "versions" "$(cut -f2 "$steps_tsv")"
assert_eq "the step row carries its outcome" "ok" "$(cut -f5 "$steps_tsv")"
assert_eq "the step row is stamped with the same run time as the history row" \
  "$(cut -f1 "$hist")" "$(cut -f1 "$steps_tsv")"
if python3 - "$d/home/Library/Logs/stay_fresh/last-run.json" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
assert data["result"] == "OK", data
assert data["ok"] and data["ok"][0].startswith("Active tool versions"), data
assert isinstance(data["freed_bytes"], int) and isinstance(data["elapsed_s"], int), data
assert data["log"] == "", data
PY
then ok "last-run.json is valid and carries the verdict"
else err "last-run.json is missing or malformed"; cat "$d/home/Library/Logs/stay_fresh/last-run.json" >&2 2>/dev/null; fi
out="$(run_sf "$d" --history)"; rc=$?
assert_eq "--history prints after a run" "0" "$rc"
assert_contains "--history shows the row" "$out" "OK"
assert_contains "--history shows the step counts" "$out" "1/0/0/22"
rm -rf "$d"

# ===========================================================================
section "notifications (macOS banner, Telegram, Slack)"
# The banner goes through osascript; the verdict is the title.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'echo "osascript $*" >> "$CALLS"; exit 0'
out="$(STAY_FRESH_NOTIFY=macos run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a run with a macOS notification succeeds" "0" "$rc"
assert_called "the banner is posted through osascript" "$d/calls" 'display notification'
assert_called "the banner title is the verdict" "$d/calls" 'with title "stay_fresh OK: freed'
assert_contains "the preflight names the channel" "$out" "notify: macos"
rm -rf "$d"

# A dry run notifies nobody, whatever the mode says.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'echo "osascript $*" >> "$CALLS"; exit 0'
out="$(STAY_FRESH_NOTIFY=macos run_sf "$d" --dry-run --only versions)"
assert_contains "a dry run says it would notify" "$out" "would notify via macos"
assert_not_called "a dry run posts no banner" "$d/calls" "display notification"
rm -rf "$d"

# Telegram: the token rides in a curl config on stdin, never on the command
# line, and the chat id and text are form fields.
tg_env() {
  local d; d="$(new_env)"
  mkbin "$d/bin/curl" 'echo "curl $*" >> "$CALLS"; cat > "$CALLS.curl-config"; exit 0'
  printf '%s' "$d"
}
d="$(tg_env)"; : > "$d/calls"
out="$(STAY_FRESH_NOTIFY=telegram STAY_FRESH_TG_BOT_TOKEN=123:secret-token STAY_FRESH_TG_CHAT_ID=42 \
  run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a run with a Telegram notification succeeds" "0" "$rc"
assert_contains "the Telegram send is reported" "$out" "telegram notification sent"
assert_called "the chat id is a form field" "$d/calls" "chat_id=42"
assert_called "the text starts with the verdict" "$d/calls" "text=stay_fresh OK: freed"
assert_not_called "the token is not on the curl command line" "$d/calls" "secret-token"
assert_contains "the token is in the stdin config" "$(cat "$d/calls.curl-config")" \
  'url = "https://api.telegram.org/bot123:secret-token/sendMessage"'
rm -rf "$d"

# Without the environment, the login Keychain answers.
d="$(tg_env)"; : > "$d/calls"
mkbin "$d/bin/security" 'echo "security $*" >> "$CALLS"' \
  'case "$*" in *"-a bot-token"*) echo "kc:token" ;; *"-a chat-id"*) echo 77 ;; esac'
out="$(STAY_FRESH_NOTIFY=telegram run_sf "$d" --yes --only versions)"; rc=$?
assert_called "the Keychain is asked for the token" "$d/calls" "find-generic-password -s stay_fresh-telegram -a bot-token -w"
assert_called "the Keychain chat id is used" "$d/calls" "chat_id=77"
assert_contains "the Keychain token reaches curl" "$(cat "$d/calls.curl-config")" "botkc:token/"
rm -rf "$d"

# No credentials anywhere: said once, the run itself is still fine.
d="$(tg_env)"; : > "$d/calls"
out="$(STAY_FRESH_NOTIFY=telegram run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "missing Telegram credentials do not fail the run" "0" "$rc"
assert_contains "missing credentials are explained" "$out" "telegram notification skipped"
assert_not_called "nothing is sent without credentials" "$d/calls" "curl"
rm -rf "$d"

# A send that fails is reported with curl's reason, on the terminal, and the
# token stays out of it. It used to vanish into a log already discarded.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/curl" 'echo "curl $*" >> "$CALLS"; cat >/dev/null; echo "curl: (6) Could not resolve host: api.telegram.org" >&2; exit 6'
out="$(STAY_FRESH_NOTIFY=telegram STAY_FRESH_TG_BOT_TOKEN=123:secret-token STAY_FRESH_TG_CHAT_ID=42 \
  run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a failed Telegram send does not fail the run" "0" "$rc"
assert_contains "a failed Telegram send is reported with the reason" "$out" \
  "telegram notification failed (curl exited 6): curl: (6) Could not resolve host"
assert_not_contains "a failed Telegram send is not reported as sent" "$out" "telegram notification sent"
assert_not_contains "the token stays out of the report" "$out" "secret-token"
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'echo "osascript: execution error: Notification Center is not available (-1743)" >&2; exit 1'
out="$(STAY_FRESH_NOTIFY=macos run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a failed banner does not fail the run" "0" "$rc"
assert_contains "a failed banner is reported with the reason" "$out" \
  "macOS notification failed (osascript exited 1): osascript: execution error"
rm -rf "$d"

# A notifier that never returns must not hold the run open after the work is
# done: a locked keychain raises a prompt nobody at a scheduled run can
# answer, and osascript can wait on Notification Center. Each call is under
# the notifier timeout, and a timed-out Keychain lookup is named.
d="$(tg_env)"; : > "$d/calls"
mkbin "$d/bin/security" 'echo "security $*" >> "$CALLS"; sleep 60'
started="$(date +%s)"
out="$(STAY_FRESH_NOTIFY=telegram STAY_FRESH_NOTIFY_TIMEOUT=1 run_sf "$d" --yes --only versions)"; rc=$?
elapsed=$(( $(date +%s) - started ))
assert_eq "a hung Keychain lookup does not fail the run" "0" "$rc"
assert_contains "the hung lookup is named" "$out" \
  "Keychain lookup for stay_fresh-telegram/bot-token timed out after 1s"
assert_contains "the notification is then skipped as unconfigured" "$out" "telegram notification skipped"
if (( elapsed <= 20 )); then ok "the run returned promptly (${elapsed}s)"
else err "the run took ${elapsed}s — the Keychain lookup was not bounded"; fi
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'sleep 60'
started="$(date +%s)"
out="$(STAY_FRESH_NOTIFY=macos STAY_FRESH_NOTIFY_TIMEOUT=1 run_sf "$d" --yes --only versions)"; rc=$?
elapsed=$(( $(date +%s) - started ))
assert_eq "a hung osascript does not fail the run" "0" "$rc"
assert_contains "the hung banner is reported as timed out" "$out" "macOS notification failed (osascript exited 124)"
if (( elapsed <= 20 )); then ok "the banner call was bounded (${elapsed}s)"
else err "the run took ${elapsed}s — osascript was not bounded"; fi
run_sf "$d" --dry-run --only versions >/dev/null; rc=$?
out="$(STAY_FRESH_NOTIFY_TIMEOUT=soon run_sf "$d" --dry-run --only versions)"; rc=$?
assert_eq "a non-numeric notifier timeout is refused" "3" "$rc"
rm -rf "$d"

# Slack: an incoming webhook. The URL is the credential, so it rides in the
# curl config on stdin exactly like the Telegram token, and the message is a
# JSON body with the verdict as text.
slack_env() {
  local d; d="$(new_env)"
  mkbin "$d/bin/curl" 'echo "curl $*" >> "$CALLS"; cat > "$CALLS.curl-config"; exit 0'
  printf '%s' "$d"
}
hook="https://hooks.slack.com/services/T000/B000/secret-hook"
d="$(slack_env)"; : > "$d/calls"
out="$(STAY_FRESH_NOTIFY=slack STAY_FRESH_SLACK_WEBHOOK="$hook" run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a run with a Slack notification succeeds" "0" "$rc"
assert_contains "the preflight names the Slack channel" "$out" "notify: slack"
assert_contains "the Slack send is reported" "$out" "slack notification sent"
assert_called "the body is JSON" "$d/calls" "Content-type: application/json"
assert_called "the text starts with the verdict" "$d/calls" '{"text": "stay_fresh OK: freed'
assert_not_called "the webhook is not on the curl command line" "$d/calls" "secret-hook"
assert_contains "the webhook is in the stdin config" "$(cat "$d/calls.curl-config")" "url = \"$hook\""
rm -rf "$d"

# Without the environment, the login Keychain answers.
d="$(slack_env)"; : > "$d/calls"
mkbin "$d/bin/security" 'echo "security $*" >> "$CALLS"' \
  'case "$*" in *"-s stay_fresh-slack -a webhook"*) echo "https://hooks.slack.com/services/kc/hook" ;; esac'
out="$(STAY_FRESH_NOTIFY=slack run_sf "$d" --yes --only versions)"; rc=$?
assert_called "the Keychain is asked for the webhook" "$d/calls" "find-generic-password -s stay_fresh-slack -a webhook -w"
assert_contains "the Keychain webhook reaches curl" "$(cat "$d/calls.curl-config")" "services/kc/hook"
assert_contains "the Keychain-backed Slack send is reported" "$out" "slack notification sent"
rm -rf "$d"

# No webhook anywhere: said once, the run itself is still fine.
d="$(slack_env)"; : > "$d/calls"
out="$(STAY_FRESH_NOTIFY=slack run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a missing Slack webhook does not fail the run" "0" "$rc"
assert_contains "a missing webhook is explained" "$out" "slack notification skipped"
assert_not_called "nothing is sent without a webhook" "$d/calls" "curl"
rm -rf "$d"

# A failed post is reported with curl's reason, and the webhook stays out of it.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/curl" 'echo "curl $*" >> "$CALLS"; cat >/dev/null; echo "curl: (22) The requested URL returned error: 403 for '"$hook"'" >&2; exit 22'
out="$(STAY_FRESH_NOTIFY=slack STAY_FRESH_SLACK_WEBHOOK="$hook" run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a failed Slack post does not fail the run" "0" "$rc"
assert_contains "a failed Slack post is reported with the reason" "$out" \
  "slack notification failed (curl exited 22): curl: (22) The requested URL returned error: 403"
assert_not_contains "the webhook stays out of the report" "$out" "secret-hook"
assert_contains "the webhook is scrubbed, not just omitted" "$out" "403 for ***"
rm -rf "$d"

# More than one channel: each one is sent, and the preflight names them all.
d="$(slack_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'echo "osascript $*" >> "$CALLS"; exit 0'
out="$(STAY_FRESH_NOTIFY=macos,slack STAY_FRESH_SLACK_WEBHOOK="$hook" run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a run with two channels succeeds" "0" "$rc"
assert_contains "the preflight names both channels" "$out" "notify: macos, slack"
assert_called "the banner is posted" "$d/calls" "display notification"
assert_called "the Slack message is posted" "$d/calls" "Content-type: application/json"
assert_contains "the Slack send is reported" "$out" "slack notification sent"
rm -rf "$d"

# --notify-when: a banner every morning gets swiped away unread; `warn`
# keeps the channel for the runs that need reading. `fail` for FAILED only.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'echo "osascript $*" >> "$CALLS"; exit 0'
out="$(STAY_FRESH_NOTIFY=macos STAY_FRESH_NOTIFY_WHEN=warn run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "an OK run under --notify-when warn succeeds" "0" "$rc"
assert_contains "the preflight names the condition" "$out" "notify: macos (only on warn)"
assert_not_called "an OK run under --notify-when warn posts nothing" "$d/calls" "display notification"
assert_contains "the withheld notification is explained" "$out" \
  "notification not sent: the run was OK and --notify-when is warn"
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'echo "osascript $*" >> "$CALLS"; exit 0'
mkbin "$d/bin/helm" 'case "${1:-} ${2:-}" in "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n"; exit 0 ;; "plugin update") exit 1 ;; esac; exit 0'
out="$(STAY_FRESH_NOTIFY=macos run_sf "$d" --yes --only helm-plugins --notify-when warn)"; rc=$?
assert_contains "the warned run is a WARN" "$out" "stay_fresh WARN"
assert_called "a WARN run under --notify-when warn posts the banner" "$d/calls" "display notification"
: > "$d/calls"
out="$(STAY_FRESH_NOTIFY=macos run_sf "$d" --yes --only helm-plugins --notify-when=fail)"; rc=$?
assert_not_called "a WARN run under --notify-when fail posts nothing" "$d/calls" "display notification"
assert_contains "the withheld WARN notification is explained" "$out" \
  "notification not sent: the run was WARN and --notify-when is fail"
run_sf "$d" --dry-run --notify-when sometimes >/dev/null; rc=$?
assert_eq "an unknown --notify-when is refused" "3" "$rc"
rm -rf "$d"

# `both` is still macos + telegram, from before Slack existed.
d="$(slack_env)"; : > "$d/calls"
mkbin "$d/bin/osascript" 'echo "osascript $*" >> "$CALLS"; exit 0'
out="$(STAY_FRESH_NOTIFY=both STAY_FRESH_TG_BOT_TOKEN=123:tok STAY_FRESH_TG_CHAT_ID=42 \
  STAY_FRESH_SLACK_WEBHOOK="$hook" run_sf "$d" --yes --only versions)"; rc=$?
assert_contains "both means macos and telegram" "$out" "notify: macos, telegram"
assert_called "both posts the banner" "$d/calls" "display notification"
assert_called "both posts to Telegram" "$d/calls" "chat_id=42"
assert_not_called "both does not post to Slack" "$d/calls" "application/json"
rm -rf "$d"

# ===========================================================================
section "snapshots (listed by default, deleted only with --thin-snapshots)"
snap_env() {
  local d; d="$(new_env)"
  mkbin "$d/bin/tmutil" 'echo "tmutil $*" >> "$CALLS"' \
    'case "${1:-}" in' \
    '  listlocalsnapshots) echo "Snapshots for disk /:"' \
    '    [ -n "${SNAPSHOTS:-}" ] && { echo "com.apple.TimeMachine.2026-09-01-101010.local"; echo "com.apple.TimeMachine.2026-09-07-030000.local"; } ;;' \
    '  deletelocalsnapshots) [ -n "${TM_DELETE_FAIL:-}" ] && exit 1 ;;' \
  '  status) echo "Backup session status:"; echo "{"' \
    '    if [ -n "${TM_RUNNING:-}" ]; then echo "    BackupPhase = Copying;"; echo "    Running = 1;"; else echo "    Running = 0;"; fi' \
    '    echo "}" ;;' \
    'esac; exit 0'
  printf '%s' "$d"
}
d="$(snap_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only snapshots)"; rc=$?
assert_eq "no snapshots is a clean step" "0" "$rc"
assert_contains "no snapshots is said" "$out" "no local Time Machine snapshots"
rm -rf "$d"

d="$(snap_env)"; : > "$d/calls"
out="$(SNAPSHOTS=1 run_sf "$d" --yes --only snapshots)"; rc=$?
assert_eq "listing snapshots succeeds" "0" "$rc"
assert_contains "snapshots are counted" "$out" "2 local snapshot(s):"
assert_contains "snapshot dates are listed" "$out" "2026-09-07-030000"
assert_contains "the thinning flag is pointed at" "$out" "remove with --thin-snapshots"
assert_not_called "nothing is deleted without --thin-snapshots" "$d/calls" "deletelocalsnapshots"
assert_contains "the verdict mentions kept snapshots" "$out" "2 local snapshot(s) kept"
assert_contains "listing is not a warning" "$out" "warn steps:  0"
rm -rf "$d"

d="$(snap_env)"; : > "$d/calls"
out="$(SNAPSHOTS=1 run_sf "$d" --yes --only snapshots --thin-snapshots)"; rc=$?
assert_eq "thinning succeeds" "0" "$rc"
assert_called "thinning first asks whether a backup is running" "$d/calls" "tmutil status"
assert_called "each snapshot is deleted through sudo" "$d/calls" "sudo tmutil deletelocalsnapshots 2026-09-01-101010"
assert_called "the second snapshot too" "$d/calls" "sudo tmutil deletelocalsnapshots 2026-09-07-030000"
assert_contains "the verdict mentions thinned snapshots" "$out" "2 local snapshot(s) thinned"
rm -rf "$d"

# A backup in progress copies from the newest snapshot; deleting it under the
# backup restarts the pass. The run lists and leaves thinning to the next one.
d="$(snap_env)"; : > "$d/calls"
out="$(SNAPSHOTS=1 TM_RUNNING=1 run_sf "$d" --yes --only snapshots --thin-snapshots)"; rc=$?
assert_eq "a running backup is a clean step" "0" "$rc"
assert_contains "a running backup is named as the reason" "$out" "a Time Machine backup is running"
assert_not_called "nothing is deleted under a running backup" "$d/calls" "deletelocalsnapshots"
assert_contains "the snapshots are still listed" "$out" "2 local snapshot(s):"
assert_contains "the verdict says kept, not thinned" "$out" "2 local snapshot(s) kept"
assert_contains "a running backup is not a warning" "$out" "warn steps:  0"
rm -rf "$d"

# tmutil can refuse every date — a snapshot pinned by a mount, a sudo
# credential gone stale mid-run. The flag that drives the verdict used to be
# set before the loop rather than from it, so a run that deleted nothing still
# announced the snapshots thinned, and the disk stayed full while the report
# said otherwise.
d="$(snap_env)"; : > "$d/calls"
out="$(SNAPSHOTS=1 TM_DELETE_FAIL=1 run_sf "$d" --yes --only snapshots --thin-snapshots)"; rc=$?
assert_eq "every deletion failing is a warned run, not a failed one" "0" "$rc"
assert_contains "and it is counted as a warning" "$out" "warn steps:  1"
assert_called "the deletions were attempted" "$d/calls" "sudo tmutil deletelocalsnapshots 2026-09-01-101010"
assert_contains "each failure is named" "$out" "could not delete snapshot 2026-09-01-101010"
assert_contains "the verdict says kept when nothing was deleted" "$out" "2 local snapshot(s) kept"
assert_not_contains "a run that deleted nothing does not claim to have thinned" "$out" "snapshot(s) thinned"
rm -rf "$d"

# Listing never asks: tmutil status is only consulted before a deletion.
d="$(snap_env)"; : > "$d/calls"
out="$(SNAPSHOTS=1 TM_RUNNING=1 run_sf "$d" --yes --only snapshots)"; rc=$?
assert_not_called "a listing does not probe the backup state" "$d/calls" "tmutil status"
rm -rf "$d"

d="$(snap_env)"; : > "$d/calls"
out="$(SNAPSHOTS=1 run_sf "$d" --yes --no-sudo --only snapshots --thin-snapshots)"; rc=$?
assert_eq "--no-sudo still lists" "0" "$rc"
assert_contains "--no-sudo explains that thinning is off" "$out" "listed, not deleted"
assert_not_called "--no-sudo deletes nothing" "$d/calls" "deletelocalsnapshots"
assert_contains "the snapshots are still listed" "$out" "2 local snapshot(s):"
rm -rf "$d"

# ===========================================================================
section "user-logs (files older than 30 days; directories, DiagnosticReports and stay_fresh's own kept)"
logs_env() {
  local d; d="$(new_env)"
  local L="$d/home/Library/Logs"
  mkdir -p "$L/Homebrew" "$L/DiagnosticReports" "$L/stay_fresh" "$L/Adobe/empty"
  bytes_file "$L/Homebrew/old.log" 64;           touch -d '40 days ago' "$L/Homebrew/old.log"
  bytes_file "$L/Homebrew/fresh.log" 64;         touch -d '2 days ago'  "$L/Homebrew/fresh.log"
  bytes_file "$L/top-old.log" 64;                touch -d '90 days ago' "$L/top-old.log"
  bytes_file "$L/DiagnosticReports/old.ips" 64;  touch -d '90 days ago' "$L/DiagnosticReports/old.ips"
  bytes_file "$L/stay_fresh/history.tsv" 64;     touch -d '90 days ago' "$L/stay_fresh/history.tsv"
  bytes_file "$L/stay_fresh/stay_fresh-20260101-000000.log" 64
  touch -d '90 days ago' "$L/stay_fresh/stay_fresh-20260101-000000.log"
  printf '%s' "$d"
}
d="$(logs_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only user-logs)"; rc=$?
assert_eq "user-logs step succeeds" "0" "$rc"
assert_gone   "an old nested log is removed"      "$d/home/Library/Logs/Homebrew/old.log"
assert_gone   "an old top-level log is removed"   "$d/home/Library/Logs/top-old.log"
assert_exists "a recent log is kept"              "$d/home/Library/Logs/Homebrew/fresh.log"
assert_exists "the log directory itself is kept"  "$d/home/Library/Logs/Homebrew"
assert_exists "an empty log directory is kept"    "$d/home/Library/Logs/Adobe/empty"
assert_exists "DiagnosticReports belongs to the diagnostics step" "$d/home/Library/Logs/DiagnosticReports/old.ips"
assert_exists "the run history is not a log to prune" "$d/home/Library/Logs/stay_fresh/history.tsv"
assert_exists "a kept run log is not pruned either" "$d/home/Library/Logs/stay_fresh/stay_fresh-20260101-000000.log"
assert_contains "the removed files are counted" "$out" "log files older than 30 days: 2 path(s)"
assert_contains "the freed size is reported" "$out" "freed 128.00K (log files older than 30 days)"
assert_contains "pruning old logs is not a warning" "$out" "warn steps:  0"
rm -rf "$d"

# The machine this step exists for has tens of thousands of eligible files,
# more than one argument vector holds. The list never becomes one: it stays
# in a file and every pass over it is batched.
d="$(new_env)"; : > "$d/calls"
big="$d/home/Library/Logs/CoreSimulator/$(printf 'device-%0120d' 1)"
mkdir -p "$big"
seq 1 20000 | sed "s|^|$big/session-|; s|\$|.log|" | xargs touch -d '40 days ago'
: > "$big/today.log"
out="$(run_sf "$d" --yes --only user-logs)"; rc=$?
assert_eq "twenty thousand old logs are a clean step" "0" "$rc"
assert_contains "all of them are counted" "$out" "log files older than 30 days: 20000 path(s)"
assert_eq "all of them are removed" "1" "$(find "$big" -type f | wc -l | tr -d ' ')"
assert_exists "the recent one among them is kept" "$big/today.log"
assert_contains "the large sweep is not a warning" "$out" "warn steps:  0"
rm -rf "$d"

d="$(logs_env)"; : > "$d/calls"
out="$(run_sf "$d" --dry-run --only user-logs)"; rc=$?
assert_eq "user-logs dry run succeeds" "0" "$rc"
assert_exists "a dry run removes nothing" "$d/home/Library/Logs/top-old.log"
assert_contains "a dry run says what it would clear" "$out" "(dry-run) would clear 2 path(s)"
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only user-logs)"; rc=$?
assert_eq "user-logs with no log directory succeeds" "0" "$rc"
assert_contains "user-logs with no log directory says so" "$out" "nothing to do"
rm -rf "$d"

d="$(logs_env)"; : > "$d/calls"
out="$(run_sf "$d" --dry-run --skip-user-logs)"; rc=$?
assert_eq "--skip-user-logs is accepted" "0" "$rc"
assert_contains "--skip-user-logs takes the step off the plan" "$(grep "old user logs" <<<"$out")" "skip"
rm -rf "$d"

# ===========================================================================
section "a cache path named by the environment must look like one"
# TF_PLUGIN_CACHE_DIR set one component short of Terraform's own documented
# value is ~/.terraform.d, which holds credentials.tfrc.json. clear_dir
# removes whatever it is handed.
d="$(new_env)"; : > "$d/calls"
mkdir -p "$d/home/.terraform.d/plugin-cache"
: > "$d/home/.terraform.d/credentials.tfrc.json"
bytes_file "$d/home/.terraform.d/plugin-cache/provider" 64
out="$(TF_PLUGIN_CACHE_DIR="$d/home/.terraform.d" run_sf "$d" --yes --only dev-caches)"; rc=$?
assert_eq "a suspicious TF_PLUGIN_CACHE_DIR does not fail the run" "0" "$rc"
assert_exists "the terraform credentials survive" "$d/home/.terraform.d/credentials.tfrc.json"
assert_exists "so does the cache it wrongly named" "$d/home/.terraform.d/plugin-cache/provider"
assert_contains "the refusal is explained" "$out" "does not end in plugin-cache"
# The documented value is still cleared.
out="$(TF_PLUGIN_CACHE_DIR="$d/home/.terraform.d/plugin-cache" run_sf "$d" --yes --only dev-caches)"
assert_gone   "the real plugin cache is still cleared" "$d/home/.terraform.d/plugin-cache/provider"
assert_exists "and the credentials beside it are still there" "$d/home/.terraform.d/credentials.tfrc.json"
rm -rf "$d"

# A bun old enough not to have `pm cache` (it arrived in 1.0.x). The cache
# directory is the fallback. BUN_INSTALL is set explicitly in both cases: the
# variable is often already exported on a developer's machine — it is in this
# container — and a test that inherits it would clear the real cache and pass
# for the wrong reason.
d="$(devcache_env)"; : > "$d/calls"
mkbin "$d/bin/bun" 'echo "bun $*" >> "$CALLS"; [ "$1" = "pm" ] && exit 1; exit 0'
out="$(BUN_INSTALL="$d/home/.bun" run_sf "$d" --yes --only dev-caches)"; rc=$?
assert_eq "dev-caches succeeds with a bun that has no pm cache" "0" "$rc"
assert_gone   "the bun cache is cleared through the directory instead" \
  "$d/home/.bun/install/cache/pkg"
assert_exists "the bun cache directory itself stays" "$d/home/.bun/install/cache"
rm -rf "$d"

# BUN_INSTALL relocates the cache, and the fallback must follow it there
# rather than clearing the default path.
d="$(devcache_env)"; : > "$d/calls"
mkbin "$d/bin/bun" 'echo "bun $*" >> "$CALLS"; [ "$1" = "pm" ] && exit 1; exit 0'
mkdir -p "$d/home/elsewhere/install/cache/pkg"
bytes_file "$d/home/elsewhere/install/cache/pkg/tarball.tgz" 128
out="$(BUN_INSTALL="$d/home/elsewhere" run_sf "$d" --yes --only dev-caches)"
assert_gone   "BUN_INSTALL relocates which cache is cleared" \
  "$d/home/elsewhere/install/cache/pkg"
assert_exists "and the default location is left alone" \
  "$d/home/.bun/install/cache/pkg/tarball.tgz"
rm -rf "$d"

# ===========================================================================
section "dev-caches (Gradle and Maven caches only with --prune-build-caches)"
build_env() {
  local d; d="$(new_env)"
  mkdir -p "$d/home/.gradle/caches/modules-2" "$d/home/.m2/repository/org"
  # A full Gradle distribution per version any project's wrapper asked for,
  # around 150 MB each and never pruned. Re-downloaded by the next build, so
  # it belongs with the build caches rather than the always-cleared ones.
  mkdir -p "$d/home/.gradle/wrapper/dists/gradle-8.5-bin/abc123"
  bytes_file "$d/home/.gradle/wrapper/dists/gradle-8.5-bin/abc123/gradle-8.5.zip" 128
  bytes_file "$d/home/.gradle/caches/modules-2/dep.jar" 256
  bytes_file "$d/home/.m2/repository/org/dep.pom" 64
  printf '%s' "$d"
}
d="$(build_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only dev-caches)"; rc=$?
assert_eq "dev-caches with build caches present succeeds" "0" "$rc"
assert_exists "the Gradle cache is kept by default" "$d/home/.gradle/caches/modules-2/dep.jar"
assert_exists "the Maven repository is kept by default" "$d/home/.m2/repository/org/dep.pom"
assert_contains "the kept Gradle cache is named" "$out" "~/.gradle/caches kept; pass --prune-build-caches to clear it"
assert_contains "the kept Maven repository is named" "$out" "~/.m2/repository kept; pass --prune-build-caches to clear it"
assert_exists "the Gradle wrapper distributions are kept by default" \
  "$d/home/.gradle/wrapper/dists/gradle-8.5-bin/abc123/gradle-8.5.zip"
assert_contains "the kept wrapper distributions are named" "$out" \
  "~/.gradle/wrapper/dists kept; pass --prune-build-caches to clear it"
assert_not_contains "build caches count as a toolchain" "$out" "no known developer toolchains found"
rm -rf "$d"

d="$(build_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only dev-caches --prune-build-caches)"; rc=$?
assert_eq "--prune-build-caches succeeds" "0" "$rc"
assert_gone   "--prune-build-caches clears the Gradle cache"   "$d/home/.gradle/caches/modules-2"
assert_gone   "--prune-build-caches clears the Maven repository" "$d/home/.m2/repository/org"
assert_gone   "--prune-build-caches clears the Gradle wrapper distributions" \
  "$d/home/.gradle/wrapper/dists/gradle-8.5-bin"
assert_exists "the wrapper dists directory itself stays" "$d/home/.gradle/wrapper/dists"
assert_exists "the Gradle cache directory itself stays"   "$d/home/.gradle/caches"
assert_exists "the Maven repository directory itself stays" "$d/home/.m2/repository"
assert_contains "the plan names the build caches" "$(grep "dev-tool caches" <<<"$out")" "gradle/maven caches"
assert_contains "the Gradle sweep reports its size" "$(grep 'freed .* from .*/.gradle/caches' <<<"$out")" "freed 2"
assert_contains "the Maven sweep reports its size"  "$(grep 'freed .* from .*/.m2/repository' <<<"$out")" "freed 6"
rm -rf "$d"

d="$(build_env)"; : > "$d/calls"
out="$(run_sf "$d" --dry-run --only dev-caches --prune-build-caches)"; rc=$?
assert_exists "a dry run keeps the Gradle cache" "$d/home/.gradle/caches/modules-2/dep.jar"
assert_contains "a dry run previews the Gradle sweep" "$out" "(dry-run) would remove contents of $d/home/.gradle/caches"
rm -rf "$d"

# ===========================================================================
section "downloads (reported by default, removed only with --prune-downloads-days)"
dl_env() {
  local d; d="$(new_env)"
  local dl="$d/home/Downloads"
  mkdir -p "$dl/old-project" "$dl/fresh-project"
  bytes_file "$dl/installer.dmg" 2048;   touch -d '120 days ago' "$dl/installer.dmg"
  bytes_file "$dl/old-project/a.txt" 64; touch -d '120 days ago' "$dl/old-project/a.txt" "$dl/old-project"
  bytes_file "$dl/recent.zip" 512
  : > "$dl/.DS_Store";                    touch -d '400 days ago' "$dl/.DS_Store"
  printf '%s' "$d"
}
d="$(dl_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only downloads)"; rc=$?
assert_eq "downloads step succeeds" "0" "$rc"
assert_contains "old entries are counted with their size" "$out" "2 entries in ~/Downloads untouched for 90 days: 2.07M"
assert_contains "the largest old entry is named first" "$(grep -A1 'untouched for 90 days' <<<"$out")" "installer.dmg"
assert_contains "the report says how to remove them" "$out" "--prune-downloads-days 90 removes them"
assert_exists "the report removes nothing" "$d/home/Downloads/installer.dmg"
assert_contains "old downloads reach the verdict" "$out" "2 old download(s) kept"
assert_contains "a report is not a warning" "$out" "warn steps:  0"
assert_not_contains "hidden entries are not counted" "$out" ".DS_Store"
rm -rf "$d"

d="$(dl_env)"; : > "$d/calls"
out="$(run_sf "$d" --dry-run --only downloads --prune-downloads-days 100)"; rc=$?
assert_eq "a downloads prune dry run succeeds" "0" "$rc"
assert_contains "the dry run names what would go" "$out" "(dry-run) would clear 2 path(s)"
assert_exists "the dry run removes nothing" "$d/home/Downloads/installer.dmg"
out="$(run_sf "$d" --yes --only downloads --prune-downloads-days 100)"; rc=$?
assert_eq "a downloads prune succeeds" "0" "$rc"
assert_gone   "an old file is removed"            "$d/home/Downloads/installer.dmg"
assert_gone   "an old directory is removed whole" "$d/home/Downloads/old-project"
assert_exists "a recent file is kept"             "$d/home/Downloads/recent.zip"
assert_exists "a recent directory is kept"        "$d/home/Downloads/fresh-project"
assert_exists "hidden entries are never removed"  "$d/home/Downloads/.DS_Store"
assert_contains "removed downloads reach the verdict" "$out" "2 old download(s) removed"
run_sf "$d" --dry-run --prune-downloads-days 0 >/dev/null; rc=$?
assert_eq "--prune-downloads-days rejects zero" "3" "$rc"
rm -rf "$d"

d="$(new_env)"; : > "$d/calls"
mkdir -p "$d/home/Downloads"; : > "$d/home/Downloads/today.pdf"
out="$(run_sf "$d" --yes --only downloads)"; rc=$?
assert_contains "a Downloads folder with nothing old says so" "$out" "nothing in ~/Downloads untouched for 90 days"
rm -rf "$d"

# ===========================================================================
section "launch-agents (orphaned plists reported; user-level removed only on request)"
agents_env() {
  local d; d="$(new_env)"
  local la="$d/home/Library/LaunchAgents"
  mkdir -p "$la" /Library/LaunchAgents /Library/LaunchDaemons "$d/home/bin"
  : > "$d/home/bin/present.sh"
  # An uninstalled app's helper, arguments on one line.
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict>' \
    '<key>Label</key><string>com.gone.helper</string>' \
    '<key>ProgramArguments</key><array><string>/Applications/Gone.app/Contents/MacOS/helper</string><string>--daemon</string></array>' \
    '</dict></plist>' > "$la/com.gone.helper.plist"
  # A script handed to an interpreter: the script is what must exist.
  printf '%s\n' '<plist version="1.0"><dict><key>ProgramArguments</key><array>' \
    '  <string>/bin/sh</string>' "  <string>$d/home/gone/backup.sh</string>" '</array></dict></plist>' \
    > "$la/com.wrapped.gone.plist"
  printf '%s\n' '<plist version="1.0"><dict><key>ProgramArguments</key><array>' \
    '  <string>/bin/sh</string>' "  <string>$d/home/bin/present.sh</string>" '</array></dict></plist>' \
    > "$la/com.wrapped.ok.plist"
  printf '%s\n' '<plist version="1.0"><dict><key>Program</key>' '<string>/bin/ls</string></dict></plist>' \
    > "$la/com.ok.plist"
  printf 'bplist00binarycontent' > "$la/com.binary.plist"
  # A path with a character XML has to escape. The file is really there, so
  # the only way this reads as orphaned is comparing the escaped spelling
  # against the filesystem — and --prune-orphan-agents then deletes a live
  # agent. "R&D Tools" is an ordinary application name.
  mkdir -p "$d/home/R&D Tools"
  : > "$d/home/R&D Tools/helper"
  printf '%s\n' '<plist version="1.0"><dict><key>Program</key>' \
    "<string>$d/home/R&amp;D Tools/helper</string></dict></plist>" \
    > "$la/com.amp.ok.plist"
  printf '%s\n' '<plist version="1.0"><dict><key>Program</key><string>/Library/Gone/daemon</string></dict></plist>' \
    > /Library/LaunchDaemons/com.gone.daemon.plist
  printf '%s\n' '<plist version="1.0"><dict><key>Program</key><string>/bin/ls</string></dict></plist>' \
    > /Library/LaunchAgents/com.ok.system.plist
  mkbin "$d/bin/launchctl" 'echo "launchctl $*" >> "$CALLS"; exit 0'
  printf '%s' "$d"
}
d="$(agents_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only launch-agents)"; rc=$?
assert_eq "launch-agents step succeeds" "0" "$rc"
assert_contains "an uninstalled app's helper is named" "$out" \
  "com.gone.helper.plist -> /Applications/Gone.app/Contents/MacOS/helper (missing)"
assert_contains "a script handed to an interpreter is checked, not the interpreter" "$out" \
  "com.wrapped.gone.plist -> $d/home/gone/backup.sh (missing)"
assert_not_contains "an interpreter with a present script is fine" "$out" "com.wrapped.ok.plist"
assert_not_contains "a present program is fine" "$out" "com.ok.plist ->"
assert_contains "a system-level orphan is named with its command" "$out" \
  "sudo launchctl bootout system/com.gone.daemon; sudo rm -f '/Library/LaunchDaemons/com.gone.daemon.plist'"
assert_contains "a binary plist without plutil is left uninspected" "$out" "1 binary plist(s) not inspected"
assert_not_contains "an XML-escaped program path is resolved before it is judged" "$out" "com.amp.ok.plist"
assert_contains "user-level orphans are kept by default" "$out" "2 user-level plist(s) kept; --prune-orphan-agents"
assert_contains "orphans reach the verdict" "$out" "3 orphaned launch agent(s)"
assert_exists "nothing is removed by default" "$d/home/Library/LaunchAgents/com.gone.helper.plist"
assert_not_called "nothing is unloaded by default" "$d/calls" "launchctl bootout"
assert_contains "a report is not a warning" "$out" "warn steps:  0"
rm -rf /Library/LaunchAgents /Library/LaunchDaemons "$d"

d="$(agents_env)"; : > "$d/calls"
out="$(run_sf "$d" --dry-run --only launch-agents --prune-orphan-agents)"; rc=$?
assert_contains "a prune dry run names the unload" "$out" "(dry-run) launchctl bootout gui/501/com.gone.helper"
assert_not_called "a prune dry run unloads nothing" "$d/calls" "launchctl"
assert_exists "a prune dry run removes nothing" "$d/home/Library/LaunchAgents/com.gone.helper.plist"
out="$(run_sf "$d" --yes --only launch-agents --prune-orphan-agents)"; rc=$?
assert_eq "pruning orphans succeeds" "0" "$rc"
assert_called "the orphan is unloaded first" "$d/calls" "launchctl bootout gui/501/com.gone.helper"
assert_called "the wrapped orphan is unloaded too" "$d/calls" "launchctl bootout gui/501/com.wrapped.gone"
assert_gone   "the orphaned plist is removed"          "$d/home/Library/LaunchAgents/com.gone.helper.plist"
assert_gone   "the wrapped orphan is removed"          "$d/home/Library/LaunchAgents/com.wrapped.gone.plist"
assert_exists "a plist with a present program stays"  "$d/home/Library/LaunchAgents/com.ok.plist"
assert_exists "the uninspected binary plist stays"     "$d/home/Library/LaunchAgents/com.binary.plist"
assert_exists "a system-level orphan is never removed" /Library/LaunchDaemons/com.gone.daemon.plist
assert_not_called "system-level plists are never unloaded" "$d/calls" "system/com.gone.daemon"
rm -rf /Library/LaunchAgents /Library/LaunchDaemons "$d"

d="$(new_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only launch-agents)"; rc=$?
assert_contains "no plists anywhere is a clean step" "$out" "no launchd plists under"
rm -rf "$d"

# ===========================================================================
section "disk-report (opt-in, read-only, largest first)"
d="$(new_env)"
mkdir -p "$d/home/Library/Caches/bigapp" "$d/home/Library/Caches/smallapp" "$d/home/Downloads" \
         "$d/home/Library/Application Support/MobileSync/Backup/device"
bytes_file "$d/home/Library/Caches/bigapp/blob" 512
bytes_file "$d/home/Library/Caches/smallapp/blob" 8
bytes_file "$d/home/Downloads/iso" 64
bytes_file "$d/home/Library/Application Support/MobileSync/Backup/device/data" 128
out="$(run_sf "$d" --dry-run --only disk-report)"
assert_contains "a dry run names the roots without measuring" "$out" "would measure the largest entries under ~/Library/Caches"
out="$(run_sf "$d" --yes --only disk-report)"; rc=$?
assert_eq "disk-report succeeds" "0" "$rc"
assert_contains "the report is read-only" "$out" "read-only; nothing above was changed"
big_line="$(grep -n 'bigapp' <<<"$out" | head -1 | cut -d: -f1)"
small_line="$(grep -n 'smallapp' <<<"$out" | head -1 | cut -d: -f1)"
if [[ -n "$big_line" && -n "$small_line" ]] && (( big_line < small_line )); then
  ok "entries are listed largest first"
else err "entries are not listed largest first (big=$big_line small=$small_line)"; fi
assert_contains "Downloads are covered" "$out" "iso"
assert_contains "device backups are sized" "$out" "iPhone/iPad backups:"
assert_exists "the report deletes nothing" "$d/home/Library/Caches/bigapp/blob"
assert_exists "the report deletes nothing (Downloads)" "$d/home/Downloads/iso"
out="$(run_sf "$d" --dry-run)"
assert_contains "disk-report is off by default" "$(grep 'disk report' <<<"$out")" "skip"
out="$(run_sf "$d" --dry-run --disk-report)"
assert_contains "--disk-report turns it on" "$(grep 'disk report' <<<"$out")" "run"
rm -rf "$d"

# ===========================================================================
section "trash on external volumes"
# Each mounted volume keeps its own .Trashes/<uid>. The boot volume shows up
# under /Volumes as a symlink and is skipped; a real second volume is emptied.
# The volumes come from the mount table, never from a glob of /Volumes: a
# glob stats each entry, and stat on the mount point of a share whose server
# went away blocks before any type check can run. mount(8) is faked in the
# macOS shape here; a name with spaces and parentheses is parsed whole.
d="$(new_env)"
mkdir -p /Volumes/Ext/.Trashes/501/folder /Volumes/Empty/.Trashes/501 "$d/home/.Trash" \
  "/Volumes/Time Machine (1)/.Trashes/501" /Volumes/Unmounted/.Trashes/501
ln -s / "/Volumes/Macintosh HD"
bytes_file /Volumes/Ext/.Trashes/501/old 128
: > /Volumes/Ext/.Trashes/501/folder/nested
: > "/Volumes/Time Machine (1)/.Trashes/501/old"
: > /Volumes/Unmounted/.Trashes/501/keep
: > "$d/home/.Trash/file"
mkbin "$d/bin/mount" 'echo "/dev/disk3s1 on / (apfs, sealed, local, journaled)"' \
  'echo "/dev/disk5s1 on /Volumes/Ext (apfs, local, nodev, nosuid, journaled, noowners)"' \
  'echo "/dev/disk6s1 on /Volumes/Empty (apfs, local, nodev, nosuid, journaled, noowners)"' \
  'echo "/dev/disk7s2 on /Volumes/Time Machine (1) (apfs, local, nodev, nosuid, journaled)"'
out="$(run_sf "$d" --yes --only trash)"; rc=$?
assert_eq "trash with external volumes succeeds" "0" "$rc"
assert_gone "~/.Trash is still emptied" "$d/home/.Trash/file"
assert_gone "the external volume's Trash is emptied" "/Volumes/Ext/.Trashes/501/old"
assert_gone "nested external entries too" "/Volumes/Ext/.Trashes/501/folder"
assert_exists "the external .Trashes/<uid> directory itself is kept" "/Volumes/Ext/.Trashes/501"
assert_contains "the external volume is named" "$out" "K from Trash on Ext"
assert_not_contains "an empty external Trash is not mentioned" "$out" "Trash on Empty"
assert_not_contains "the boot volume symlink is skipped" "$out" "Trash on Macintosh HD"
assert_gone "a volume name with spaces and parentheses is parsed whole" "/Volumes/Time Machine (1)/.Trashes/501/old"
assert_exists "a directory under /Volumes that is not mounted is not touched" /Volumes/Unmounted/.Trashes/501/keep
rm -rf /Volumes "$d"

# A network share is never asked: find(1) on a share whose server went away
# blocks until somebody kills the run. mount(8) says what each volume is, in
# macOS's "(smbfs, ...)" shape here; a local disk is still emptied.
d="$(new_env)"
mkdir -p /Volumes/NAS/.Trashes/501 /Volumes/USB/.Trashes/501
: > /Volumes/NAS/.Trashes/501/keep
: > /Volumes/USB/.Trashes/501/old
mkbin "$d/bin/mount" 'echo "/dev/disk3s1 on / (apfs, sealed, local, journaled)"' \
  'echo "//serhii@nas.local/share on /Volumes/NAS (smbfs, nodev, nosuid, mounted by serhii)"' \
  'echo "/dev/disk5s1 on /Volumes/USB (apfs, local, nodev, nosuid, journaled, noowners)"' \
  'echo "nas:/export on /Volumes/Dead NFS type nfs (rw,hard,intr)"'
# /Volumes/Dead NFS is listed and does not exist: a mount the kernel would
# block on is skipped by its type, before the path is looked at.
out="$(run_sf "$d" --yes --only trash)"; rc=$?
assert_eq "trash with a network volume succeeds" "0" "$rc"
assert_exists "the network volume's Trash is left alone" /Volumes/NAS/.Trashes/501/keep
assert_contains "the network volume is named and typed" "$out" \
  "Trash on NAS skipped: network volume (smbfs)"
assert_contains "a hard NFS mount is skipped by type without being touched" "$out" \
  "Trash on Dead NFS skipped: network volume (nfs)"
assert_gone "the local volume's Trash is still emptied" /Volumes/USB/.Trashes/501/old
rm -rf /Volumes "$d"

# Without a uid the per-user directory would be ".Trashes/" - the shared
# parent holding every user's trash on that volume - and the sweep would take
# all of it. ~/.Trash needs no uid and is still emptied.
d="$(new_env)"; : > "$d/calls"
mkdir -p /Volumes/USB/.Trashes/501 /Volumes/USB/.Trashes/502 "$d/home/.Trash"
: > /Volumes/USB/.Trashes/501/mine
: > /Volumes/USB/.Trashes/502/someone-elses
: > "$d/home/.Trash/own"
mkbin "$d/bin/id" 'case "${1:-}" in -u) exit 1 ;; -un) echo tester ;; *) /usr/bin/id "$@" ;; esac'
mkbin "$d/bin/mount" 'echo "/dev/disk5s1 on /Volumes/USB (apfs, local)"'
out="$(run_sf "$d" --yes --only trash)"; rc=$?
assert_eq "an unavailable uid does not fail the run" "0" "$rc"
assert_contains "the missing uid is named" "$out" \
  "cannot determine the current uid — leaving the Trash on mounted volumes alone"
assert_exists "another user's trash on the volume survives" /Volumes/USB/.Trashes/502/someone-elses
assert_exists "the volume's own trash is left alone too" /Volumes/USB/.Trashes/501/mine
assert_gone   "~/.Trash is still emptied without a uid" "$d/home/.Trash/own"
rm -rf /Volumes "$d"

# ===========================================================================
section "df unreadable (the summary reports no measurement rather than a wrong one)"
# An empty free-space reading used to flow into every later size calculation,
# so this asserted it was "treated as zero" and the summary printed
# 0B -> 0B (0B reclaimed). That reads as a run which freed nothing, which is a
# measurement; what actually happened is that nothing was measured. Worse, only
# one of the two readings has to fail for the subtraction to invent a number —
# a working df before and a failing df after made RECLAIMED_B the negative of
# the whole disk, and it travelled into last-run.json, history.tsv and every
# --trend average built on them. The assertions are rewritten to the new
# intent: an unmeasured run says so, and the per-step total, which is counted
# rather than subtracted, still stands.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/df" 'exit 1'
out="$(run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "an unreadable df does not fail the run" "0" "$rc"
assert_contains "the unreadable df is reported once" "$out" \
  "could not read free space on / — this run will report no reclaimed total"
assert_contains "the preflight still prints a number" "$out" "disk free on /: 0B"
assert_contains "the summary declines to invent a figure" "$out" "disk free:   unknown (df could not read /)"
assert_not_contains "and does not present the absence as a measurement" "$out" "0B reclaimed"
assert_not_contains "no printf complains about an empty number" "$out" "invalid number"
assert_contains "the run still reaches its verdict" "$out" "stay_fresh OK"
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d['reclaimed_bytes'], int), d" \
     "$d/home/Library/Logs/stay_fresh/last-run.json" 2>/dev/null; then
  ok "last-run.json still carries a numeric reclaimed_bytes"
else
  err "last-run.json reclaimed_bytes is not a number"
fi
rm -rf "$d"

# ===========================================================================
section "brew (upgrade count and outdated casks in the verdict)"
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/brew" 'echo "brew $*" >> "$CALLS"' \
  'case "${1:-}" in --version) echo "Homebrew 4.0.0" ;; --prefix) echo /opt/homebrew ;; --repository) echo "$HOME/brewrepo" ;; esac' \
  'case "${1:-} ${2:-}" in' \
  '  "upgrade --help") echo "--yes" ;;' \
  '  "upgrade --formula") echo "==> Upgrading 2 outdated packages:"; echo "fzf 0.60 -> 0.61"; echo "jq 1.7 -> 1.8"; echo "==> Upgrading fzf"; echo "==> Upgrading jq" ;;' \
  '  "outdated --cask") echo alacritty; echo unetbootin ;;' \
  'esac; exit 0'
out="$(run_sf "$d" --yes --only brew)"; rc=$?
assert_eq "brew step succeeds" "0" "$rc"
assert_contains "upgraded packages are counted and named" "$out" "upgraded 2 package(s): fzf jq"
assert_called "outdated casks are asked for" "$d/calls" "brew outdated --cask --quiet"
assert_contains "outdated casks are named" "$out" "2 cask(s) still outdated:"
assert_contains "the manual cask command is given" "$out" "brew upgrade --cask alacritty unetbootin"
assert_contains "the verdict carries the brew facts" "$out" "brew upgraded 2; 2 cask(s) still outdated"
assert_contains "history records the upgrade count" "$(cut -f10 "$d/home/Library/Logs/stay_fresh/history.tsv")" "2"
rm -rf "$d"

# A brew service in "error" state is a daemon launchd gave up restarting;
# nothing else in the run would mention it. Named, and in the verdict, but
# not counted: the run cannot fix it. An Intel Homebrew beside the Apple
# silicon one is named once too.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/brew" 'echo "brew $*" >> "$CALLS"' \
  'case "${1:-}" in --version) echo "Homebrew 4.0.0" ;; --prefix) echo /opt/homebrew ;; esac' \
  'case "${1:-} ${2:-}" in' \
  '  "services list") printf "Name       Status  User    File\n"; printf "postgresql@16 error   serhii  ~/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist\n"; printf "redis      started serhii  ~/Library/LaunchAgents/homebrew.mxcl.redis.plist\n"; printf "nginx      none\n" ;;' \
  'esac; exit 0'
mkdir -p /usr/local/Homebrew
out="$(run_sf "$d" --yes --only brew)"; rc=$?
assert_eq "a brew service in error does not fail the run" "0" "$rc"
assert_called "brew services are listed" "$d/calls" "brew services list"
assert_contains "the errored service is named" "$out" \
  "1 brew service(s) in error state: postgresql@16"
assert_contains "the errored service reaches the verdict" "$out" "1 brew service(s) in error"
assert_contains "an errored service is information, not a warning" "$out" "warn steps:  0"
assert_contains "an Intel Homebrew beside the Apple silicon one is named" "$out" \
  "an Intel Homebrew is also installed at /usr/local/Homebrew"
rmdir /usr/local/Homebrew
: > "$d/calls"
out="$(run_sf "$d" --dry-run --only brew)"
assert_not_called "a dry run does not list services" "$d/calls" "brew services"
rm -rf "$d"

# Pending OS updates reach the verdict as a count.
d="$(os_env)"; : > "$d/calls"
out="$(SU_PENDING=1 MAS_PENDING=1 run_os "$d" --yes --only os-updates)"
assert_contains "the verdict counts pending OS updates" "$out" "2 OS/App Store update(s) pending"
rm -rf "$d"

# ===========================================================================
section "sudo keep-alive does not outlive the run"
# The keep-alive subshell forks `sleep`, and the EXIT trap kills the subshell
# but not that grandchild. When it inherited the script's stdio, the orphan held
# the write end of the caller's pipe and every caller that captures output —
# `out="$(stay_fresh ...)"`, a CI step, the LaunchAgent's log redirect — blocked
# until it expired. A --only dns run does two trivial things and must return
# immediately; the unfixed script did not return for over a minute.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/dscacheutil" 'exit 0'
mkbin "$d/bin/killall" 'exit 0'
started="$(date +%s)"
out="$(run_sf "$d" --yes --only dns)"; rc=$?
elapsed=$(( $(date +%s) - started ))
assert_eq "a captured sudo run succeeds" "0" "$rc"
if (( elapsed <= 20 )); then
  ok "capturing a sudo run's output returns promptly (${elapsed}s)"
else
  err "capturing a sudo run's output blocked for ${elapsed}s — the keep-alive is holding stdout"
fi
rm -rf "$d"

# ===========================================================================
section "the kept log says what warned"
# A log is kept precisely because something warned, and it was the one
# artefact that did not name it: warn/err printed to the terminal only, so a
# step that warns without running a command left zero bytes behind.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/helm" 'case "${1:-} ${2:-}" in' \
  '  "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n"; exit 0 ;;' \
  '  "plugin update") echo "helm: plugin diff is broken" >&2; exit 1 ;;' \
  'esac; exit 0'
out="$(run_sf "$d" --yes --no-sudo --only helm-plugins)"; rc=$?
assert_contains "the run warned" "$out" "warn steps:  1"
saved="$(find "$d/home/Library/Logs/stay_fresh" -name 'stay_fresh-*.log' | head -n 1)"
if [[ -n "$saved" ]]; then
  saved_text="$(cat "$saved")"
  assert_contains "the kept log names the step that warned" "$saved_text" "== Helm plugin refresh =="
  assert_contains "the kept log carries the warning itself" "$saved_text" "[warn] 'helm plugin update diff' failed"
  assert_contains "the kept log still carries the command output" "$saved_text" "plugin diff is broken"
else
  err "no log was kept for a warned run"
fi
rm -rf "$d"

# A dry run still writes nothing, warnings included.
d="$(new_env)"; : > "$d/calls"
out="$(run_sf "$d" --dry-run --only versions)"
if [[ -z "$(find "$d/tmp" "$d/home" -type f -print -quit 2>/dev/null)" ]]; then
  ok "a dry run writes no log even though warnings now reach one"
else
  err "a dry run wrote a file"; find "$d/tmp" "$d/home" -type f >&2
fi
rm -rf "$d"

# ===========================================================================
section "log lifecycle"
# A clean run leaves nothing behind.
d="$(new_env)"
mkbin "$d/bin/pyenv" 'echo 3.12.1'
out="$(run_sf "$d" --yes --only versions)"
assert_contains "a clean run discards its log" "$out" "run clean — log discarded"
if [[ -z "$(find "$d/tmp" -name 'stay_fresh-*.log' -print -quit)" ]]; then
  ok "a clean run leaves no log in TMPDIR"
else
  err "a clean run left a log in TMPDIR"
fi
rm -rf "$d"

# A clean run that notifies leaves nothing behind either. The notifiers log
# into the run's log; with the discard ahead of them, every notified clean
# run recreated an empty log in TMPDIR on its way out.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/pyenv" 'echo 3.12.1'
mkbin "$d/bin/osascript" 'echo "osascript $*" >> "$CALLS"; exit 0'
out="$(STAY_FRESH_NOTIFY=macos run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a clean notified run succeeds" "0" "$rc"
assert_called "the banner was posted" "$d/calls" "display notification"
assert_contains "the clean notified run discards its log" "$out" "run clean — log discarded"
if [[ -z "$(find "$d/tmp" -type f -print -quit)" ]]; then
  ok "a clean notified run leaves nothing in TMPDIR"
else
  err "a clean notified run left a file in TMPDIR: $(find "$d/tmp" -type f)"
fi
# The discard is the last thing said: the verdict comes before it.
verdict_line="$(grep -n 'stay_fresh OK: freed' <<<"$out" | head -n 1 | cut -d: -f1)"
discard_line="$(grep -n 'run clean — log discarded' <<<"$out" | head -n 1 | cut -d: -f1)"
if [[ -n "$verdict_line" && -n "$discard_line" ]] && (( discard_line > verdict_line )); then
  ok "the log is discarded after the verdict and the notification"
else
  err "the log discard (line ${discard_line:-?}) precedes the verdict (line ${verdict_line:-?})"
fi
rm -rf "$d"

# history.tsv is capped at 500 rows, newest kept.
d="$(new_env)"
mkbin "$d/bin/pyenv" 'echo 3.12.1'
mkdir -p "$d/home/Library/Logs/stay_fresh"
for i in $(seq 1 600); do printf '2000-01-01 00:00:%03d\tOK\t0\t0\t0\t1\t0\t0\t0\t0\t0\t\n' "$i"; done \
  > "$d/home/Library/Logs/stay_fresh/history.tsv"
out="$(run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "a run against a long history succeeds" "0" "$rc"
assert_eq "history is trimmed to 500 rows" "500" \
  "$(wc -l < "$d/home/Library/Logs/stay_fresh/history.tsv" | tr -d ' ')"
assert_contains "the newest row survives the trim" \
  "$(tail -n 1 "$d/home/Library/Logs/stay_fresh/history.tsv")" "$(date '+%Y-%m')"
assert_not_contains "the oldest row is the one dropped" \
  "$(cat "$d/home/Library/Logs/stay_fresh/history.tsv")" "2000-01-01 00:00:001"
rm -rf "$d"

# A run that warned keeps its log, and retention caps the directory at ten.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/helm" 'echo "helm $*" >> "$CALLS"' \
                    'case "${1:-} ${2:-}" in' \
                    '  "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n"; exit 0 ;;' \
                    '  "plugin update") exit 1 ;;' \
                    'esac' \
                    'exit 0'
mkdir -p "$d/home/Library/Logs/stay_fresh"
for i in $(seq -w 1 12); do
  : > "$d/home/Library/Logs/stay_fresh/stay_fresh-200001$i-000000.log"
done
out="$(run_sf "$d" --yes --only helm-plugins)"; rc=$?
assert_eq "a warning does not fail the run" "0" "$rc"
assert_contains "a failed plugin update warns" "$out" "warn steps:  1"
assert_contains "the log is retained after a warning" "$out" "log saved:"
kept="$(find "$d/home/Library/Logs/stay_fresh" -name 'stay_fresh-*.log' | wc -l | tr -d ' ')"
assert_eq "log retention keeps ten files" "10" "$kept"
rm -rf "$d"

# Scheduled runs opt into strict warning handling so launchd reports partial
# maintenance failures instead of recording a successful last exit status.
d="$(new_env)"; : > "$d/calls"
mkbin "$d/bin/helm" 'case "${1:-} ${2:-}" in' \
                    '  "plugin list") printf "NAME\tVERSION\n"; printf "diff\t3.9\n"; exit 0 ;;' \
                    '  "plugin update") exit 1 ;;' \
                    'esac; exit 0'
out="$(run_sf "$d" --yes --fail-on-warn --only helm-plugins)"; rc=$?
assert_eq "--fail-on-warn turns a warned step into exit 1" "1" "$rc"
assert_contains "strict warning failure is explained" "$out" \
  "warnings are fatal because --fail-on-warn was requested"
rm -rf "$d"

# ===========================================================================
if (( failures )); then
  echo; echo "=== $failures stay_fresh step test(s) failed ===" >&2
  exit 1
fi
echo; echo "=== all stay_fresh step (docker) checks passed ==="
exit 0

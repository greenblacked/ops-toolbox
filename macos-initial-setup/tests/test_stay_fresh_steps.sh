#!/usr/bin/env bash
# Per-step behavior tests for stay_fresh.sh, run inside the Linux tester
# container with the repo mounted at /repo.
#
# The sibling suite (test_macos_initial_setup.sh) covers the CLI surface of
# every script: --help, argument rejection, plans, dry runs. What it cannot
# reach is the inside of a step, because a step deletes things. This file runs
# each of the fifteen steps for real against a scratch HOME and a faked set of
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
  mkbin "$d/bin/pgrep" 'for a in "$@"; do' \
                       '  case " ${RUNNING_APPS:-} " in *" $a "*) exit 0 ;; esac' \
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
run_sf() {
  local d="$1"; shift
  HOME="$d/home" TMPDIR="$d/tmp" PATH="$d/bin:/usr/bin:/bin" \
    CALLS="$d/calls" NO_COLOR=1 \
    RUNNING_APPS="${RUNNING_APPS:-}" \
    DOCKER_ENDPOINT="${DOCKER_ENDPOINT:-unix:///var/run/docker.sock}" \
    DOCKER_INFO_FAIL_AFTER="${DOCKER_INFO_FAIL_AFTER:-}" \
    DOCKER_INFO_N="$d/docker.info.n" \
    NODE_RC="${NODE_RC:-0}" \
    HELM_UPDATE_RC="${HELM_UPDATE_RC:-0}" \
    GCLOUD_COMPONENTS_RC="${GCLOUD_COMPONENTS_RC:-0}" \
    "$SF" "$@" </dev/null 2>&1
}

bytes_file() { dd if=/dev/zero of="$1" bs=1024 count="${2:-512}" status=none; }

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
d="$(new_env)"; : > "$d/calls"
rm -rf /Library/Caches /System/Library/Caches
mkdir -p /Library/Caches/vendor /System/Library/Caches/writable /System/Library/Caches/locked
bytes_file /Library/Caches/vendor/blob 256
: > /System/Library/Caches/writable/entry
: > /System/Library/Caches/locked/entry
chmod 555 /System/Library/Caches/locked
out="$(run_sf "$d" --yes --only system-caches)"; rc=$?
assert_eq "system-caches step succeeds" "0" "$rc"
assert_gone   "/Library/Caches contents are removed"      /Library/Caches/vendor
assert_exists "/Library/Caches itself is kept"            /Library/Caches
assert_gone   "writable /System/Library/Caches entry goes" /System/Library/Caches/writable
assert_exists "unwritable /System/Library/Caches entry stays" /System/Library/Caches/locked
chmod 755 /System/Library/Caches/locked
rm -rf /Library/Caches /System/Library/Caches
rm -rf "$d"

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
mkdir -p "$as/Slack/Cache" "$as/Notion/GPUCache" \
         "$as/Code/CachedExtensionVSIXs" "$d/home/Library/Containers/com.x/Data/Library/Caches"
: > "$as/Slack/Cache/data"
: > "$as/Notion/GPUCache/data"
: > "$as/Code/CachedExtensionVSIXs/ext.vsix"
: > "$d/home/Library/Containers/com.x/Data/Library/Caches/blob"
RUNNING_APPS="Slack" out="$(run_sf "$d" --yes --only app-caches)"; rc=$?
assert_eq "app-caches step succeeds" "0" "$rc"
assert_exists "a running app keeps its cache"       "$as/Slack/Cache/data"
assert_gone   "an idle app loses its cache"         "$as/Notion/GPUCache"
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
    '    if [ -n "${DOCKER_INFO_FAIL_AFTER:-}" ]; then' \
    '      n=$(cat "$DOCKER_INFO_N" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$DOCKER_INFO_N"' \
    '      [ "$n" -gt "$DOCKER_INFO_FAIL_AFTER" ] && exit 1' \
    '    fi' \
    '    exit 0 ;;' \
    '  context)' \
    '    case "${2:-}" in show) echo default ;; inspect) echo "$DOCKER_ENDPOINT" ;; esac' \
    '    exit 0 ;;' \
    '  system) printf "Images\t1.5GB\n"; exit 0 ;;' \
    'esac' \
    'exit 0'
}
d="$(new_env)"; : > "$d/calls"; docker_fake "$d"
out="$(run_sf "$d" --yes --only docker)"; rc=$?
assert_eq "docker step succeeds against a local daemon" "0" "$rc"
for sub in "container prune -f" "network prune -f" \
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

# A daemon that answers preflight and then goes away is the case that has to
# reach STEPS_FAIL and exit 1 rather than being reported as a clean run.
d="$(new_env)"; : > "$d/calls"; docker_fake "$d"
DOCKER_INFO_FAIL_AFTER=1 out="$(run_sf "$d" --yes --only docker)"; rc=$?
assert_eq "a step that hard-fails exits 1" "1" "$rc"
assert_contains "a hard failure is counted" "$out" "failed:      1"
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
assert_called "unavailable simulators are deleted" "$d/calls" "xcrun simctl delete unavailable"
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
rm -rf "$d"

# ===========================================================================
section "dev-caches (each toolchain, and an unusable node)"
devcache_env() {
  local d; d="$(new_env)"
  mkbin "$d/bin/node"  'echo "node $*" >> "$CALLS"; exit "${NODE_RC:-0}"'
  for t in npm yarn pnpm pip3 gem go; do
    mkbin "$d/bin/$t" "echo \"$t \$*\" >> \"\$CALLS\"; exit 0"
  done
  printf '%s' "$d"
}
d="$(devcache_env)"; : > "$d/calls"
out="$(run_sf "$d" --yes --only dev-caches)"; rc=$?
assert_eq "dev-caches step succeeds" "0" "$rc"
assert_called "npm cache is cleaned"   "$d/calls" "npm cache clean --force"
assert_called "yarn cache is cleaned"  "$d/calls" "yarn cache clean"
assert_called "pnpm store is pruned"   "$d/calls" "pnpm store prune"
assert_called "pip cache is purged"    "$d/calls" "pip3 cache purge"
assert_called "gem cache is cleaned"   "$d/calls" "gem cleanup"
assert_called "go caches are cleaned"  "$d/calls" "go clean -cache -modcache -testcache"
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
out="$(run_sf "$d" --yes --only versions)"; rc=$?
assert_eq "versions step succeeds" "0" "$rc"
assert_contains "the active python version is reported"    "$out" "pyenv active:  3.12.1"
assert_contains "the active go version is reported"        "$out" "goenv active:  1.22.0"
assert_contains "the active terraform version is reported" "$out" "tfenv active:  1.7.5"
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

# ===========================================================================
if (( failures )); then
  echo; echo "=== $failures stay_fresh step test(s) failed ===" >&2
  exit 1
fi
echo; echo "=== all stay_fresh step (docker) checks passed ==="
exit 0

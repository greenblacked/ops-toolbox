#!/usr/bin/env bash
# Run from the Linux tester container; repo root is mounted at /repo.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
M="$REPO_ROOT/macos-initial-setup"

if [[ ! -d "$M" ]]; then
  echo "expected macos-initial-setup at $M" >&2
  exit 1
fi

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
  if [[ "$expected" == "$actual" ]]; then
    ok "$label"
  else
    err "$label (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    err "$label (missing '$needle')"
    printf '%s\n' "$haystack" | head -20 >&2
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    err "$label (unexpected '$needle')"
    printf '%s\n' "$haystack" | head -20 >&2
  else
    ok "$label"
  fi
}

# --- discovery -------------------------------------------------------------
# Discovered rather than listed. The hardcoded array this replaced named four
# scripts and the package has grown to nine, so brewfile.sh, macos_defaults.sh,
# workstation_doctor.sh and launchd/stay_fresh_agent.sh had no coverage here at
# all — for long enough that the omission is quoted as the cautionary tale in
# git/tests and test-env/lib/discover_clis.sh.
#
# Depth 2 so launchd/ is included; tests/ is the one subdirectory left out,
# because this file lives in it. zsh_aliases.zsh is not in the glob and is
# handled separately below: it is sourced, not run, so the --help and
# unknown-flag contracts do not apply to it. Built without mapfile to stay
# Bash 3.2-clean (see CONTRIBUTING.md).
sh_scripts=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  sh_scripts+=("$f")
done < <(find "$M" -maxdepth 2 -name '*.sh' -type f ! -path "$M/tests/*" | sort)

if (( ${#sh_scripts[@]} == 0 )); then
  echo "discovered no scripts under $M — discovery is broken" >&2
  exit 1
fi
ok "discovered ${#sh_scripts[@]} scripts under macos-initial-setup/"

# --- bash -n (syntax) ---
for f in "${sh_scripts[@]}"; do
  if bash -n "$f"; then
    ok "bash -n ${f#"$REPO_ROOT/"}"
  else
    err "bash -n ${f#"$REPO_ROOT/"}"
  fi
done

# --- shellcheck (errors only; warnings are too noisy for legacy/v1 script style) ---
for f in "${sh_scripts[@]}"; do
  rel="${f#"$REPO_ROOT/"}"
  if shellcheck --severity=error -x -s bash "$f"; then
    ok "shellcheck (bash) $rel"
  else
    err "shellcheck (bash) $rel"
  fi
done

zsh_file="$M/zsh_aliases.zsh"
if [[ -f "$zsh_file" ]]; then
  set +e
  sc_err="$(shellcheck --severity=error -s zsh "$zsh_file" 2>&1)"
  sc_rc=$?
  set -e
  if [[ "$sc_rc" -eq 0 ]]; then
    ok "shellcheck (zsh) ${zsh_file#"$REPO_ROOT/"}"
  elif grep -q "Unknown shell" <<<"$sc_err"; then
    ok "shellcheck (zsh) skipped (no zsh in this shellcheck build)"
  else
    echo "$sc_err" >&2
    err "shellcheck (zsh) ${zsh_file#"$REPO_ROOT/"}"
  fi
else
  err "missing $zsh_file"
fi

# --- --help (must work before macOS preflight) ---
for f in "${sh_scripts[@]}"; do
  if "$f" --help >/dev/null 2>&1; then
    ok "${f#"$M/"} --help"
  else
    err "${f#"$M/"} --help"
  fi
done

# --- HOME: every path the script clears is built from it ------------------
# Unset, `set -u` aborted with a bare "HOME: unbound variable" before --help
# could answer. Empty was worse and silent: "$HOME/Library/Caches" is
# "/Library/Caches", the system cache directory, and "$HOME/.Trash" is
# "/.Trash", so a run meant for one home directory addressed the machine.
# The flags that need no home directory still work; anything that touches a
# path stops with exit 2 and says why.
sf="$M/stay_fresh.sh"
set +e
out="$(env -u HOME "$sf" --help 2>&1)"; rc=$?
set -e
assert_eq "stay_fresh --help works with HOME unset" "0" "$rc"
assert_contains "the help is the real help" "$out" "macOS housekeeping in one script"
set +e
out="$(env -u HOME "$sf" --list-steps 2>&1)"; rc=$?
set -e
assert_eq "stay_fresh --list-steps works with HOME unset" "0" "$rc"
assert_contains "the step ids are listed without a home directory" "$out" "user-caches"
# The agent asks this exact question to validate --notify, so it must not
# need a home directory either.
set +e
env -u HOME "$sf" --list-steps --notify macos,slack >/dev/null 2>&1; rc=$?
set -e
assert_eq "the agent's --notify probe works with HOME unset" "0" "$rc"
for home_case in unset empty; do
  set +e
  if [[ "$home_case" == unset ]]; then
    out="$(env -u HOME "$sf" --yes --no-sudo --only user-caches 2>&1)"; rc=$?
  else
    out="$(HOME="" "$sf" --yes --no-sudo --only user-caches 2>&1)"; rc=$?
  fi
  set -e
  assert_eq "a run with HOME $home_case is refused -> 2" "2" "$rc"
  assert_contains "a run with HOME $home_case says why" "$out" "HOME is not set"
  assert_not_contains "a run with HOME $home_case never names a system path" "$out" "/Library/Caches"
done
set +e
out="$(HOME="$M/stay_fresh.sh" "$sf" --yes --no-sudo --only user-caches 2>&1)"; rc=$?
set -e
assert_eq "a HOME that is not a directory is refused -> 2" "2" "$rc"
assert_contains "a non-directory HOME is named" "$out" "HOME is not a directory"

# --- unknown CLI -> exit 3 (parsed before preflight) ---
for f in "${sh_scripts[@]}"; do
  set +e
  out="$("$f" --definitely-not-a-valid-flag-12345 2>&1)"; rc=$?
  set -e
  if [[ "$rc" -eq 3 ]]; then
    ok "${f#"$M/"} unknown flag -> exit 3"
  else
    err "${f#"$M/"} unknown flag: expected exit 3, got $rc: $(printf '%s' "$out" | head -3)"
  fi
done

# --- Linux / non-Darwin: preflight should reject (documented exit 2) ---
# Discovery again, with a table for the two scripts that need an argument to
# reach their preflight at all. Naming exceptions rather than subjects is what
# keeps this from rotting the way the old list did: a new script is covered the
# day it lands, and only a script that genuinely differs has to be touched.
preflight_args() {
  case "${1##*/}" in
    brewfile.sh)         printf '%s\n' "check" ;;
    stay_fresh_agent.sh) printf '%s\n' "status" ;;
    *)                   printf '%s\n' "" ;;
  esac
}

if [[ "$(uname -s)" == "Linux" ]]; then
  for f in "${sh_scripts[@]}"; do
    name="${f##*/}"
    # v1_stay_fresh.sh has no platform guard by design: it is the preserved
    # original and its documented exit codes are 0, 1 (no usable home) and 2
    # (bad arguments), with no 'wrong OS' among them.
    if [[ "$name" == "v1_stay_fresh.sh" ]]; then
      ok "$name: skipped, it has no platform guard by design"
      continue
    fi
    set +e
    # shellcheck disable=SC2046  # an empty argument list must vanish, not become ''
    out="$("$f" $(preflight_args "$f") 2>&1)"; rc=$?
    set -e
    if [[ "$rc" -ne 2 ]]; then
      err "$name: expected exit 2 on Linux, got $rc"
    elif ! grep -q "macOS" <<<"$out"; then
      err "$name: expected 'macOS' in the output on Linux"
    else
      ok "$name: Linux preflight -> exit 2 (macOS only)"
    fi
  done
else
  ok "skipping Linux preflight assertions (unusual host OS: $(uname -s))"
fi

# --- selection CLIs validate before macOS-only preflight -------------------
tools_out="$("$M/install_devtools.sh" --list-tools)"
for tool in python terraform go helm; do
  assert_contains "install_devtools lists selectable $tool" "$tools_out" "$tool"
done
set +e
"$M/install_devtools.sh" --only python,nosuch >/dev/null 2>&1; rc=$?
set -e
assert_eq "install_devtools rejects unknown --only tool -> 3" "3" "$rc"

steps_out="$("$M/stay_fresh.sh" --list-steps)"
for step_id in brew docker workspace-storage krew versions os-updates; do
  assert_contains "stay_fresh lists selectable $step_id" "$steps_out" "$step_id"
done
set +e
"$M/stay_fresh.sh" --only nosuch >/dev/null 2>&1; rc=$?
set -e
assert_eq "stay_fresh rejects unknown --only step -> 3" "3" "$rc"
set +e
"$M/stay_fresh.sh" --only memory >/dev/null 2>&1; rc=$?
set -e
assert_eq "stay_fresh keeps memory purge behind explicit opt-in" "3" "$rc"
set +e
"$M/stay_fresh.sh" --step-timeout abc >/dev/null 2>&1; rc=$?
set -e
assert_eq "stay_fresh rejects a non-numeric --step-timeout -> 3" "3" "$rc"
set +e
"$M/stay_fresh.sh" --step-timeout >/dev/null 2>&1; rc=$?
set -e
assert_eq "stay_fresh rejects --step-timeout without a value -> 3" "3" "$rc"

set +e
"$M/install_apps.sh" --only-formulae nosuch >/dev/null 2>&1; rc=$?
set -e
assert_eq "install_apps rejects unknown --only-formulae -> 3" "3" "$rc"

legacy_help="$("$M/v1_stay_fresh.sh" --help)"
assert_contains "legacy maintenance help carries deprecation warning" "$legacy_help" "DEPRECATED"

# --- stay_fresh safety contracts ------------------------------------------
# Fake only the three host-identification commands. Everything that can mutate
# is either dry-run or confined to a scratch HOME/TMPDIR below.
fake_macos="$(mktemp -d)"
mkdir -p "$fake_macos/bin" "$fake_macos/home" "$fake_macos/tmp"
printf '%s\n' '#!/bin/sh' \
  'case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac' \
  > "$fake_macos/bin/uname"
printf '%s\n' '#!/bin/sh' \
  'case "${1:-}" in -u) echo 501 ;; -un) echo tester ;; *) /usr/bin/id "$@" ;; esac' \
  > "$fake_macos/bin/id"
printf '%s\n' '#!/bin/sh' \
  'case "${1:-}" in -productVersion) echo 15.0 ;; -buildVersion) echo TESTBUILD ;; esac' \
  > "$fake_macos/bin/sw_vers"
# Substring match, so the fake answers both `pgrep -x Slack` and the bundle
# path form the app-cache guard uses, `pgrep -f "/Slack.app/Contents/MacOS/"`.
printf '%s\n' '#!/bin/sh' \
  'for arg in "$@"; do case "$arg" in *Slack*) exit 0 ;; esac; done; exit 1' \
  > "$fake_macos/bin/pgrep"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_macos/bin/curl"
printf '%s\n' '#!/bin/sh' \
  'case "${1:-}" in -p) echo /Library/Developer/CommandLineTools ;; esac' \
  'exit 0' > "$fake_macos/bin/xcode-select"
printf '%s\n' '#!/bin/sh' \
  'echo "Filesystem 1G-blocks Used Available Capacity Mounted on"' \
  'echo "/dev/test 100 20 80 20% /"' > "$fake_macos/bin/df"
printf '%s\n' '#!/bin/sh' \
  'if [ "${1:-}" = read ]; then [ "${DEFAULTS_READ_EMPTY:-0}" = 1 ] && exit 1; echo false; exit 0; fi' \
  'if [ "${1:-}" = write ]; then printf "%s\n" "$*" >> "$DEFAULTS_CALLS"; exit 0; fi' \
  'if [ "${1:-}" = delete ]; then printf "%s\n" "$*" >> "$DEFAULTS_CALLS"; [ "${DEFAULTS_FAIL_DELETE:-0}" = 1 ] && exit 73; exit 0; fi' \
  'exit 0' > "$fake_macos/bin/defaults"
chmod +x "$fake_macos/bin/"*

set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" </dev/null 2>&1)"
rc=$?
set -e
assert_eq "stay_fresh refuses non-interactive mutation without --yes" "2" "$rc"
assert_contains "stay_fresh explains the non-interactive guard" "$out" \
  "non-interactive execution requires --yes"
if [[ -z "$(find "$fake_macos/home" "$fake_macos/tmp" -mindepth 1 -print -quit)" ]]; then
  ok "non-interactive refusal writes nothing"
else
  err "non-interactive refusal modified HOME or TMPDIR"
fi

out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  --no-sudo --only versions 2>&1)"
assert_contains "stay_fresh --only selects the requested step" "$out" \
  "Active tool versions"
if grep -Eq 'Clear user caches[[:space:]]+run' <<<"$out"; then
  err "stay_fresh --only versions unexpectedly selected cache deletion"
else
  ok "stay_fresh --only versions leaves mutating cache steps skipped"
fi

skip_for_plan=(
  --skip-dns --skip-syscaches --skip-usercaches --skip-appcaches
  --skip-workspacestorage --skip-trash --skip-brew --skip-devcaches
  --skip-docker --skip-xcode --skip-diagnostics --skip-devtools
)
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  "${skip_for_plan[@]}" 2>&1)"
if grep -Eq 'purge disk caches[[:space:]]+skip' <<<"$out"; then
  ok "stay_fresh keeps purge opt-in by default"
else
  err "stay_fresh planned purge without --purge-memory"
fi
if grep -Eq 'krew plugin refresh[[:space:]]+skip' <<<"$out"; then
  ok "--skip-devtools also skips the krew refresh"
else
  err "--skip-devtools left the krew refresh planned"
fi

mkdir -p "$fake_macos/home/Library/Developer/Xcode/Archives/2020-01-01/Test.xcarchive"
touch -t 202001010000 "$fake_macos/home/Library/Developer/Xcode/Archives/2020-01-01/Test.xcarchive"
xcode_skip=(
  --skip-dns --skip-syscaches --skip-usercaches --skip-appcaches
  --skip-workspacestorage --skip-trash --skip-brew --skip-devcaches
  --skip-docker --skip-diagnostics --skip-devtools
)
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  "${xcode_skip[@]}" 2>&1)"
assert_contains "Xcode Archives are retained by default" "$out" "Archives kept"
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  --prune-xcode-archives-days 30 "${xcode_skip[@]}" 2>&1)"
assert_contains "age-based Xcode archive pruning finds old bundles" "$out" \
  "Xcode Archives older than 30d: 1 path(s)"

mkdir -p "$fake_macos/home/Library/Application Support/Slack/Cache"
printf 'payload\n' > "$fake_macos/home/Library/Application Support/Slack/Cache/data"
app_skip=(
  --skip-dns --skip-syscaches --skip-usercaches --skip-workspacestorage
  --skip-trash --skip-brew --skip-devcaches --skip-docker --skip-xcode
  --skip-diagnostics --skip-devtools
)
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  "${app_skip[@]}" 2>&1)"
assert_contains "running application cache is retained" "$out" \
  "their cache roots will be kept"
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  --force-active-app-caches "${app_skip[@]}" 2>&1)"
assert_contains "force flag includes a running application cache" "$out" \
  "Electron/Chromium caches: 1 path(s)"
if [[ -z "$(find "$fake_macos/tmp" -mindepth 1 -print -quit)" ]]; then
  ok "populated dry runs leave no log or scanner artifacts"
else
  err "populated dry run modified TMPDIR"
fi

# The lock lives under HOME, not TMPDIR. The LaunchAgent's environment
# carries only PATH, so a TMPDIR-based lock resolved to /tmp for the agent
# and /var/folders/... for a terminal — two different directories, and the
# manual-vs-agent overlap the lock exists to prevent went unprevented.
mkdir -p "$fake_macos/home/Library/Application Support/stay_fresh/run.lock"
printf '%s\n' "$$" > "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/pid"
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${skip_for_plan[@]}" 2>&1)"
rc=$?
set -e
assert_eq "overlapping stay_fresh run is rejected" "2" "$rc"
assert_contains "overlap refusal identifies the active run" "$out" \
  "another stay_fresh run is active"

# The case the TMPDIR lock could not catch: same machine, different TMPDIR —
# exactly what an agent-context run looks like next to a terminal run.
mkdir -p "$fake_macos/tmp2"
set +e
HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp2" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${skip_for_plan[@]}" >/dev/null 2>&1
rc=$?
set -e
assert_eq "overlap is rejected even from a different TMPDIR" "2" "$rc"
rm -f "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/pid"
rmdir "$fake_macos/home/Library/Application Support/stay_fresh/run.lock"

# A lock from before the last reboot is stale whatever its pid says: after a
# reboot an unrelated process can wear the old number, and kill -0 then
# reported a run that ended with the power as active. The boot time recorded
# beside the pid settles it. The pid here is this very shell, alive by
# definition, and the run must still go ahead.
mkdir -p "$fake_macos/home/Library/Application Support/stay_fresh/run.lock"
printf '%s\n' "$$" > "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/pid"
printf '1\n' > "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/boot"
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${skip_for_plan[@]}" 2>&1)"
rc=$?
set -e
assert_eq "a lock from before the last reboot does not block the run" "0" "$rc"
assert_contains "the pre-reboot lock is named as such" "$out" \
  "removing stale stay_fresh lock from before the last reboot"
if [[ ! -d "$fake_macos/home/Library/Application Support/stay_fresh/run.lock" ]]; then
  ok "the lock is released after recovering from a pre-reboot one"
else
  err "the lock directory survived the run"
fi

# kern.boottime is not a constant: XNU re-derives it whenever the clock is
# stepped, which NTP and sleep/wake do, by seconds. A lock whose recorded
# boot is thirty seconds off, held by a live pid, is a run still going,
# not one from before a reboot; only minutes of difference mean a reboot.
boot_now="$( { /usr/sbin/sysctl -n kern.boottime 2>/dev/null || true; } | sed -n 's/.*{ *sec = \([0-9]*\).*/\1/p')"
[[ -n "$boot_now" ]] || boot_now="$(awk '/^btime /{ print $2 }' /proc/stat 2>/dev/null || true)"
if [[ "$boot_now" =~ ^[0-9]+$ ]]; then
  mkdir -p "$fake_macos/home/Library/Application Support/stay_fresh/run.lock"
  printf '%s\n' "$$" > "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/pid"
  printf '%s\n' $(( boot_now - 30 )) > "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/boot"
  set +e
  out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
    PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
    "${skip_for_plan[@]}" 2>&1)"
  rc=$?
  set -e
  assert_eq "a live lock whose boot time drifted by seconds is still respected" "2" "$rc"
  assert_contains "the drifted live lock is reported as active" "$out" "another stay_fresh run is active"
  rm -f "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/pid" \
        "$fake_macos/home/Library/Application Support/stay_fresh/run.lock/boot"
  rmdir "$fake_macos/home/Library/Application Support/stay_fresh/run.lock"
else
  err "could not read the boot time to test the lock's drift tolerance"
fi

# A kill can land after mkdir(2) but before the pid file is written. That empty
# directory is stale and must not disable maintenance forever.
mkdir -p "$fake_macos/home/Library/Application Support/stay_fresh/run.lock"
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${skip_for_plan[@]}" 2>&1)"
assert_contains "empty stale lock is recovered" "$out" \
  "removing stale stay_fresh lock without a live pid"
if [[ ! -d "$fake_macos/home/Library/Application Support/stay_fresh/run.lock" ]]; then
  ok "recovered stale lock is released after the run"
else
  err "recovered stale lock remained after the run"
fi

# Volumes hold data, not cache: the LaunchAgent runs this script with --yes,
# so a default `docker volume prune` would delete a stopped project's database
# volume unattended. The stub is a healthy local docker so the step actually
# plans; both assertions are against the dry-run plan output.
cat > "$fake_macos/bin/docker" <<'DOCKER_EOF'
#!/bin/sh
case "$1" in
  info) exit 0 ;;
  context)
    case "$2" in
      show)    echo default ;;
      inspect) echo "unix:///var/run/docker.sock" ;;
    esac ;;
  *) exit 0 ;;
esac
DOCKER_EOF
chmod +x "$fake_macos/bin/docker"
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  --only docker 2>&1)"
if grep -q "docker volume prune" <<<"$out"; then
  err "docker volume prune is planned without --prune-docker-volumes"
else
  ok "docker volumes are kept by default"
fi
assert_contains "the plan says volumes are kept" "$out" "volumes kept"
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  --only docker --prune-docker-volumes 2>&1)"
assert_contains "--prune-docker-volumes plans the volume prune" "$out" \
  "docker volume prune -f"
rm -f "$fake_macos/bin/docker"

# Every id printed by --list-steps must be accepted by --only, or the two
# halves of the interface drift apart: a step gets renamed in one place and
# the documented spelling starts exiting 3.
while IFS= read -r step_id; do
  [[ -n "$step_id" ]] || continue
  extra=()
  [[ "$step_id" == memory ]] && extra=(--purge-memory)
  if HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
    PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
    --only "$step_id" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1; then
    ok "--only accepts listed step id: $step_id"
  else
    err "--only rejects a step id that --list-steps advertises: $step_id"
  fi
done < <("$M/stay_fresh.sh" --list-steps | awk '{print $1}')

# TMPDIR is where both the log and the run lock live, and nothing guarantees it
# exists: launchd hands a job its own per-user temp dir, and `TMPDIR=... stay_fresh`
# is a normal thing to type. The lock used to be the first thing to touch that
# path, so a missing TMPDIR surfaced as "removing stale stay_fresh lock" followed
# by a refusal to run — a lock that never existed, blamed for a directory that
# was simply not there.
missing_tmp="$fake_macos/tmp/not/created/yet"
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$missing_tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  --only versions 2>&1)"
rc=$?
set -e
assert_eq "stay_fresh creates a missing TMPDIR rather than failing the lock" "0" "$rc"
assert_not_contains "missing TMPDIR is not misreported as a stale lock" "$out" \
  "stale stay_fresh lock"
if [[ -d "$missing_tmp" ]]; then
  ok "stay_fresh created the missing TMPDIR"
else
  err "stay_fresh did not create the missing TMPDIR"
fi
rm -rf "$fake_macos/tmp/not"

# --only names the work you want done. Preflight can take a step straight back
# off that list (no Homebrew, no Docker daemon, --no-sudo), and the run then
# reached the summary having done nothing at all while exiting 0 — a silent
# no-op that reads as success.
#
# The docker stub answers `command -v` but fails `docker info`, pinning the
# auto-skip reason to "daemon unreachable" on every machine. The previous
# version relied on docker being absent from PATH, which held in the CI
# container and nowhere that has a docker CLI at /usr/bin — the same suite
# then failed on a developer machine for reasons that had nothing to do with
# the code under test.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$fake_macos/bin/docker"
chmod +x "$fake_macos/bin/docker"
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  --only docker 2>&1)"
rc=$?
set -e
assert_eq "a fully voided --only selection fails preflight -> 2" "2" "$rc"
assert_contains "voided --only names the step that cannot run" "$out" \
  "--only docker: the Docker daemon is unreachable"

# The same reconciliation must respect --no-sudo, which disables root-owned
# steps just as effectively as a missing binary does.
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  --only system-caches 2>&1)"
rc=$?
set -e
assert_eq "--only system-caches under --no-sudo fails preflight -> 2" "2" "$rc"
assert_contains "--no-sudo explains the voided selection" "$out" \
  "--only system-caches: --no-sudo was passed"

# A partially voided selection is a warning, not a failure: the steps that can
# run still should.
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  --only docker,versions 2>&1)"
rc=$?
set -e
assert_eq "a partially voided --only still runs the rest" "0" "$rc"
assert_contains "partially voided --only warns about the lost step" "$out" \
  "--only docker: the Docker daemon is unreachable"
assert_contains "partially voided --only runs the surviving step" "$out" \
  "Active tool versions"
rm -f "$fake_macos/bin/docker"

# A dry run previews rather than stopping, matching every other preflight check.
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --dry-run --yes \
  --only docker 2>&1)"
rc=$?
set -e
assert_eq "a voided --only still previews under --dry-run" "0" "$rc"
assert_contains "the dry-run preview says a real run would stop" "$out" \
  "a real run would stop here"

# An auto-skipped step was booked twice: once by preflight pushing its own
# STEPS_SKIP entry and again by run_or_skip, so the summary claimed 16 skips
# for 15 steps and listed Homebrew under two different names.
brew_absent_skip=(
  --skip-dns --skip-syscaches --skip-usercaches --skip-appcaches
  --skip-workspacestorage --skip-trash --skip-devcaches --skip-docker
  --skip-xcode --skip-diagnostics --skip-user-logs --skip-downloads --skip-launch-agents
  --skip-devtools --skip-snapshots
)
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${brew_absent_skip[@]}" 2>&1)"
assert_contains "an all-skipped run counts each step exactly once" "$out" \
  "skipped:     21"
assert_not_contains "the auto-skipped step is not booked a second time" "$out" \
  "brew (not installed)"
assert_contains "a skipped step reports why it was skipped" "$out" \
  "Homebrew update / upgrade / cleanup (Homebrew is not installed)"
assert_not_contains "opt-in memory is not blamed on --no-sudo" "$out" \
  "Purge inactive memory (--no-sudo was passed)"

# --only already took every unnamed step off the list. Tagging those with
# "--no-sudo was passed" makes a versions-only run look like three root-owned
# steps were refused, when they were never selected.
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  --only versions 2>&1)"
rc=$?
set -e
assert_eq "--only versions under --no-sudo still runs" "0" "$rc"
assert_not_contains "--only does not blame unselected dns on --no-sudo" "$out" \
  "Flush DNS cache (--no-sudo was passed)"
assert_not_contains "--only does not blame unselected system-caches on --no-sudo" "$out" \
  "Clear system caches (--no-sudo was passed)"
assert_not_contains "an --only run does not warn about unselected sudo steps" "$out" \
  "--no-sudo set:"

# Force find(1) to fail during a real cleanup confined to the scratch HOME. The
# target must remain and the step must be yellow, not falsely green.
mkdir -p "$fake_macos/failbin" "$fake_macos/home/Library/Caches/protected"
printf 'keep\n' > "$fake_macos/home/Library/Caches/protected/data"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$fake_macos/failbin/find"
chmod +x "$fake_macos/failbin/find"
cleanup_skip=(
  --skip-dns --skip-syscaches --skip-appcaches --skip-workspacestorage
  --skip-trash --skip-brew --skip-devcaches --skip-docker --skip-xcode
  --skip-diagnostics --skip-devtools
)
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/failbin:$fake_macos/bin:/usr/bin:/bin" \
  "$M/stay_fresh.sh" --yes --no-sudo "${cleanup_skip[@]}" 2>&1)"
assert_contains "failed cache deletion is reported" "$out" "could not fully clear"
if [[ -f "$fake_macos/home/Library/Caches/protected/data" ]]; then
  ok "failed cache deletion leaves the target visible"
else
  err "failed cache deletion unexpectedly removed the target"
fi

# Exercise the LaunchAgent's effective Homebrew mode: --yes --no-sudo must run
# formulae exactly once and must never start a cask pass. The fake is a
# current Homebrew, so its upgrade help documents --yes and the flag is
# expected to reach the formula pass.
brew_calls="$fake_macos/brew.calls"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$BREW_CALLS"' \
  'case "${1:-}" in --version) echo "Homebrew test" ;; --prefix) echo /opt/homebrew ;; esac' \
  'case "${1:-} ${2:-}" in "upgrade --help") echo "  --no-ask, --yes, -y  Do not ask for confirmation" ;; esac' \
  'exit 0' > "$fake_macos/bin/brew"
printf '%s\n' '#!/bin/sh' \
  'case "${1:-}" in version) echo v3.17.0 ;; esac' \
  'exit 0' > "$fake_macos/bin/helm"
printf '%s\n' '#!/bin/sh' \
  'case "${1:-}" in activate) echo : ;; esac' \
  'exit 0' > "$fake_macos/bin/mise"
chmod +x "$fake_macos/bin/brew"
chmod +x "$fake_macos/bin/helm" "$fake_macos/bin/mise"
: > "$brew_calls"
brew_skip=(
  --skip-dns --skip-syscaches --skip-usercaches --skip-appcaches
  --skip-workspacestorage --skip-trash --skip-devcaches --skip-docker
  --skip-xcode --skip-diagnostics --skip-devtools
)
BREW_CALLS="$brew_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${brew_skip[@]}" >/dev/null 2>&1
assert_eq "unattended Homebrew formula pass runs once" "1" \
  "$(grep -c '^upgrade --formula --yes$' "$brew_calls")"
if grep -q '^upgrade --cask' "$brew_calls"; then
  err "--no-sudo unexpectedly attempted a Homebrew cask upgrade"
else
  ok "--no-sudo skips Homebrew cask upgrades"
fi

# Both bootstrap scripts can now target small, reviewable subsets. Their dry
# runs stop at the plan, so fake host commands are sufficient and no state is
# written outside this scratch HOME/TMPDIR.
out="$(BREW_CALLS="$brew_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  SHELL=/bin/zsh PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/install_devtools.sh" --dry-run --only terraform 2>&1)"
assert_contains "install_devtools --only keeps Terraform" "$out" "terraform:     install"
assert_contains "install_devtools --only skips Python" "$out" "python:        SKIP"

out="$(BREW_CALLS="$brew_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  SHELL=/bin/zsh PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/install_devtools.sh" --yes --only helm --manager mise --no-helm-plugins 2>&1)"
assert_contains "Helm-only run needs no shell setup" "$out" \
  "no shell setup is required for the selected tools"
assert_not_contains "Helm-only mise selection does not suggest mise activation" "$out" \
  'mise activate'
assert_not_contains "Helm-only run does not suggest pyenv" "$out" 'pyenv init'
assert_not_contains "Helm-only run does not suggest goenv" "$out" 'goenv init'

out="$(BREW_CALLS="$brew_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  SHELL=/bin/zsh PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/install_devtools.sh" --yes --only terraform --manager mise \
  --terraform-version 1.2.3 2>&1)"
assert_contains "selected mise-managed Terraform suggests mise activation" "$out" \
  'eval "$(mise activate zsh)"'
assert_not_contains "mise-managed Terraform does not suggest pyenv" "$out" 'pyenv init'
assert_not_contains "mise-managed Terraform does not suggest goenv" "$out" 'goenv init'

out="$(BREW_CALLS="$brew_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/install_apps.sh" --dry-run \
  --only brave-browser --skip-gcloud --only-formulae jq,yq 2>&1)"
assert_contains "install_apps reports the selected formula count" "$out" \
  "CLI formulae (2 selected)"
if grep -Eq '^[[:space:]]*k9s[[:space:]]' <<<"$out"; then
  err "install_apps --only-formulae unexpectedly planned k9s"
else
  ok "install_apps --only-formulae excludes unselected formulae"
fi

# Brewfile reconciliation previews without --force and mutates only when that
# explicit flag is present.
brewfile_fixture="$fake_macos/Brewfile"
printf 'brew "jq"\n' > "$brewfile_fixture"
: > "$brew_calls"
BREW_CALLS="$brew_calls" HOME="$fake_macos/home" PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/brewfile.sh" cleanup --file "$brewfile_fixture" >/dev/null
if grep -q -- '--force' "$brew_calls"; then
  err "brewfile cleanup preview passed --force"
else
  ok "brewfile cleanup preview is non-mutating"
fi
BREW_CALLS="$brew_calls" HOME="$fake_macos/home" PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/brewfile.sh" cleanup --file "$brewfile_fixture" --force >/dev/null
if grep -q '^bundle cleanup .*--force' "$brew_calls"; then
  ok "brewfile cleanup requires and forwards explicit --force"
else
  err "brewfile cleanup --force did not reach Homebrew"
fi
: > "$brew_calls"
BREW_CALLS="$brew_calls" HOME="$fake_macos/home" PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/brewfile.sh" cleanup --file "$brewfile_fixture" --force --dry-run >/dev/null
if grep -q -- '--force' "$brew_calls"; then
  err "brewfile cleanup --dry-run did not override --force"
else
  ok "brewfile cleanup --dry-run overrides destructive --force"
fi

# An explicitly selected defaults backup is validated before any setting is
# restored. Dry-run proves the chosen file, rather than the newest glob match,
# drives the plan.
selected_backup="$fake_macos/selected-defaults-backup.txt"
printf '%s\n' '# macos_defaults.sh backup - test' \
  'com.apple.finder|ShowPathbar|bool|false' > "$selected_backup"
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/macos_defaults.sh" \
  --revert-from "$selected_backup" --dry-run 2>&1)"
assert_contains "macos_defaults identifies the selected backup" "$out" "$selected_backup"
assert_contains "macos_defaults plans the validated restore" "$out" \
  "defaults write com.apple.finder ShowPathbar -bool false"
bad_backup="$fake_macos/bad-defaults-backup.txt"
printf 'not a trusted backup\n' > "$bad_backup"
set +e
HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/macos_defaults.sh" \
  --revert-from "$bad_backup" --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "macos_defaults rejects an unrecognized backup -> 1" "1" "$rc"
set +e
HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/macos_defaults.sh" \
  --revert-from "$selected_backup" --apply --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "macos_defaults rejects mixed apply/revert modes -> 3" "3" "$rc"
set +e
HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/macos_defaults.sh" \
  --revert-from "$selected_backup" --only finder --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "macos_defaults rejects --only with revert -> 3" "3" "$rc"

# A real apply remains confined to the fake defaults binary and scratch backup
# path. This catches backup-creation bugs that a dry run cannot reach.
defaults_calls="$fake_macos/defaults.calls"
apply_backup="$fake_macos/applied-defaults-backup.txt"
: > "$defaults_calls"
DEFAULTS_CALLS="$defaults_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/macos_defaults.sh" \
  --apply --only finder --backup-file "$apply_backup" >/dev/null
if [[ -s "$apply_backup" ]] && grep -q '^write ' "$defaults_calls"; then
  ok "macos_defaults real apply writes a new backup before fake defaults calls"
else
  err "macos_defaults real apply did not create its backup/apply settings"
fi
set +e
DEFAULTS_CALLS="$defaults_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/macos_defaults.sh" \
  --apply --only nosuch --backup-file "$fake_macos/must-not-exist.txt" >/dev/null 2>&1
rc=$?
set -e
assert_eq "macos_defaults validates --only before backup creation -> 3" "3" "$rc"
if [[ ! -e "$fake_macos/must-not-exist.txt" ]]; then
  ok "macos_defaults invalid --only leaves no backup artifact"
else
  err "macos_defaults invalid --only created a backup artifact"
fi

unset_backup="$fake_macos/unset-defaults-backup.txt"
printf '%s\n' '# macos_defaults.sh backup - test' \
  'com.apple.finder|ShowPathbar|bool|(unset)' > "$unset_backup"
set +e
DEFAULTS_FAIL_DELETE=1 DEFAULTS_CALLS="$defaults_calls" HOME="$fake_macos/home" \
  TMPDIR="$fake_macos/tmp" PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/macos_defaults.sh" --revert-from "$unset_backup" >/dev/null 2>&1
rc=$?
set -e
assert_eq "macos_defaults reports a failed revert delete -> 1" "1" "$rc"

set +e
DEFAULTS_FAIL_DELETE=1 DEFAULTS_READ_EMPTY=1 DEFAULTS_CALLS="$defaults_calls" \
  HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/macos_defaults.sh" --revert-from "$unset_backup" >/dev/null 2>&1
rc=$?
set -e
assert_eq "macos_defaults accepts delete failure when the key is already absent" "0" "$rc"

set +e
"$M/stay_fresh.sh" --prune-xcode-archives-days zero >/dev/null 2>&1
rc=$?
set -e
assert_eq "archive retention rejects a non-number -> 3" "3" "$rc"

# The doctor keeps its historical report-only exit code unless strict mode is
# explicitly requested.
doctor_args=(--skip-brew-doctor --skip-login-items --skip-time-machine --skip-log-sizes --skip-launchd)
set +e
BREW_CALLS="$brew_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/workstation_doctor.sh" \
  "${doctor_args[@]}" >/dev/null 2>&1
doctor_default_rc=$?
BREW_CALLS="$brew_calls" HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/workstation_doctor.sh" \
  --strict "${doctor_args[@]}" >/dev/null 2>&1
doctor_strict_rc=$?
set -e
assert_eq "workstation_doctor default remains report-only" "0" "$doctor_default_rc"
assert_eq "workstation_doctor --strict fails on warnings" "1" "$doctor_strict_rc"

# Agent log inspection is read-only and chooses the newest bounded log.
mkdir -p "$fake_macos/home/Library/Logs/stay_fresh"
printf 'old\n' > "$fake_macos/home/Library/Logs/stay_fresh/agent-20260101-000000-1.log"
printf 'one\ntwo\nthree\n' > "$fake_macos/home/Library/Logs/stay_fresh/agent-20260102-000000-2.log"
out="$(HOME="$fake_macos/home" PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$M/launchd/stay_fresh_agent.sh" logs --tail 2 2>&1)"
assert_contains "agent logs command identifies the newest log" "$out" \
  "agent-20260102-000000-2.log"
assert_contains "agent logs command tails requested lines" "$out" $'two\nthree'

# Command-specific option validation prevents a familiar-looking --dry-run from
# being silently ignored by a destructive subcommand.
agent="$M/launchd/stay_fresh_agent.sh"
agent_calls="$fake_macos/launchctl.calls"
agent_bootstrap_n="$fake_macos/bootstrap.n"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$AGENT_CALLS"' \
  'case "${1:-}" in' \
  '  print) [ "${AGENT_LOADED:-0}" = 1 ] ;;' \
  '  bootout) exit "${AGENT_BOOTOUT_RC:-0}" ;;' \
  '  bootstrap)' \
  '    n=$(cat "$AGENT_BOOTSTRAP_N" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$AGENT_BOOTSTRAP_N"' \
  '    [ "${AGENT_BOOTSTRAP_FAIL_ONCE:-0}" = 1 ] && [ "$n" -eq 1 ] && exit 1' \
  '    exit "${AGENT_BOOTSTRAP_RC:-0}" ;;' \
  '  kickstart) exit 0 ;;' \
  'esac' \
  'exit 0' > "$fake_macos/bin/launchctl"
chmod +x "$fake_macos/bin/launchctl"

agent_plist="$fake_macos/home/Library/LaunchAgents/com.pretty-useful.stay-fresh.plist"
mkdir -p "$(dirname "$agent_plist")"
printf 'original plist\n' > "$agent_plist"
: > "$agent_calls"
AGENT_CALLS="$agent_calls" AGENT_LOADED=1 \
  HOME="$fake_macos/home" PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$agent" uninstall --dry-run >/dev/null 2>&1
assert_eq "agent uninstall --dry-run keeps the plist" "original plist" \
  "$(cat "$agent_plist")"
assert_eq "agent uninstall --dry-run does not call launchctl" "0" \
  "$(wc -l < "$agent_calls" | tr -d ' ')"

set +e
AGENT_CALLS="$agent_calls" HOME="$fake_macos/home" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$agent" run-now --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "run-now rejects an ambiguous --dry-run -> 3" "3" "$rc"

# A failed replacement bootstrap restores both the old plist and the old loaded
# job. The first bootstrap is the new job and fails; the second is rollback.
: > "$agent_calls"
rm -f "$agent_bootstrap_n"
set +e
AGENT_CALLS="$agent_calls" AGENT_BOOTSTRAP_N="$agent_bootstrap_n" \
  AGENT_BOOTSTRAP_FAIL_ONCE=1 AGENT_LOADED=1 \
  HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$agent" install --profile full --hour 4 >/dev/null 2>&1
rc=$?
set -e
assert_eq "a failed replacement install exits 1" "1" "$rc"
assert_eq "a failed replacement restores the old plist" "original plist" \
  "$(cat "$agent_plist")"
assert_eq "a failed replacement bootstraps the rollback" "2" \
  "$(grep -c '^bootstrap ' "$agent_calls")"

# status reads the verdict stay_fresh.sh writes for it, and says so when
# there is none yet.
rm -f "$fake_macos/home/Library/Logs/stay_fresh/last-run.json"
out="$(AGENT_CALLS="$agent_calls" AGENT_LOADED=1 HOME="$fake_macos/home" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$agent" status 2>&1)"
assert_contains "agent status says when no run is recorded" "$out" "no run recorded yet"
# "YYYY-MM-DD HH:MM:SS" some days back, in the format stay_fresh.sh writes;
# BSD date takes -r seconds, GNU date takes -d @seconds.
stamp_days_ago() {
  local e=$(( $(date +%s) - $1 * 86400 ))
  date -r "$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$e" '+%Y-%m-%d %H:%M:%S'
}
write_last_run() {
  mkdir -p "$fake_macos/home/Library/Logs/stay_fresh"
  cat > "$fake_macos/home/Library/Logs/stay_fresh/last-run.json" <<JSON
{
  "when": "$1",
  "result": "WARN",
  "headline": "stay_fresh WARN: freed 1.20G in 4m10s",
  "detail": "15 ok, 1 warned, 4 skipped; brew upgraded 3; \\"kept\\" 2 local snapshot(s)",
  "elapsed_s": 250,
  "log": "/Users/serhii/Library/Logs/stay_fresh/stay_fresh-20260909-030012.log"
}
JSON
}
agent_status() {
  AGENT_CALLS="$agent_calls" AGENT_LOADED=1 HOME="$fake_macos/home" \
    PATH="$fake_macos/bin:/usr/bin:/bin" "$agent" status 2>&1
}
sched_stamp="$fake_macos/home/Library/Logs/stay_fresh/last-scheduled"
fresh_when="$(stamp_days_ago 0)"
write_last_run "$fresh_when"
rm -f "$sched_stamp"
touch "$agent_plist"
set +e
out="$(agent_status)"
rc=$?
set -e
assert_eq "agent status with a fresh install and no scheduled run yet exits 0" "0" "$rc"
assert_contains "agent status shows the last run's headline" "$out" \
  "last run: $fresh_when — stay_fresh WARN: freed 1.20G in 4m10s"
assert_contains "agent status shows the detail line with its quotes unescaped" "$out" \
  '15 ok, 1 warned, 4 skipped; brew upgraded 3; "kept" 2 local snapshot(s)'
assert_contains "agent status says no scheduled run has happened yet" "$out" "no scheduled run recorded yet"
assert_not_contains "a fresh install is not called stale" "$out" "the job is not running"

# A job that stopped firing is the failure launchd hides best: still loaded,
# last verdict still OK. The yardstick is the plist's schedule - daily here,
# the fake plist has no Weekday - and twice that with no scheduled run is
# stale. The measure is the stamp run-scheduled writes, or the install when
# there is none; last-run.json is rewritten by manual runs too and stays
# fresh here throughout, which must not mask a job that never fires.
# An old plist with no stamp is genuinely ambiguous, and it used to be read
# the pessimistic way: "the job is not running", exit 1. But only
# run-scheduled writes last-scheduled and only since the version that added
# it, so an agent installed before that upgrade has no stamp however
# faithfully launchd has been firing it - and every one of them was told its
# job was dead, for up to a full interval, until the next firing wrote the
# stamp. A false death notice for a working job is the worse error of the
# two, so with no stamp the age is reported and the exit stays 0; the real
# signal arrives at the next firing.
touch -t 202001010000 "$agent_plist"
set +e
out="$(agent_status)"
rc=$?
set -e
assert_eq "an old install with no stamp is not declared dead" "0" "$rc"
assert_contains "the age since the install is still reported" "$out" \
  "no run-scheduled stamp yet and the plist was installed"
assert_contains "and it says where the real signal comes from" "$out" \
  "it will appear at the next firing"
assert_not_contains "an old install with no stamp is not called dead" "$out" \
  "the job is not running"
touch "$agent_plist"
printf '%s\t%s\n' "$(stamp_days_ago 3)" 0 > "$sched_stamp"
set +e
out="$(agent_status)"
rc=$?
set -e
assert_eq "agent status with a stale daily schedule exits 1" "1" "$rc"
assert_contains "the last scheduled run is shown with its exit code" "$out" "last scheduled run: $(stamp_days_ago 3 | cut -c1-10)"
assert_contains "a stale daily schedule is called out with its age" "$out" \
  "no scheduled run in 3 day(s) since the last scheduled run, and the schedule fires every 1 day(s) — the job is not running"
# The same three days against a weekly schedule are on time.
printf '%s\n' '<key>StartCalendarInterval</key><dict><key>Weekday</key><integer>1</integer></dict>' \
  > "$agent_plist"
set +e
out="$(agent_status)"
rc=$?
set -e
assert_eq "three days against a weekly schedule exits 0" "0" "$rc"
assert_not_contains "three days against a weekly schedule is not stale" "$out" "the job is not running"
printf '%s\t%s\n' "$(stamp_days_ago 20)" 1 > "$sched_stamp"
set +e
out="$(agent_status)"
rc=$?
set -e
assert_eq "twenty days against a weekly schedule exits 1" "1" "$rc"
assert_contains "a stale weekly schedule names the weekly yardstick" "$out" \
  "no scheduled run in 20 day(s) since the last scheduled run, and the schedule fires every 7 day(s)"
printf 'original plist\n' > "$agent_plist"
rm -f "$sched_stamp"

# The safe profile is what the plist runs by default. Its step list lives in
# run-scheduled, not in the plist, so it is checked from the transcript of a
# dry scheduled run: the two read-only reports are in, the deletions out.
rm -rf "$fake_macos/home/Library/Logs/stay_fresh"
set +e
HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" PATH="$fake_macos/bin:/usr/bin:/bin" \
  "$agent" run-scheduled --profile safe --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "a dry scheduled run under the safe profile succeeds" "0" "$rc"
sched_log="$(ls -1 "$fake_macos/home/Library/Logs/stay_fresh"/agent-*.log 2>/dev/null | head -n 1)"
if [[ -n "$sched_log" ]]; then
  sched_out="$(cat "$sched_log")"
  for want in "clear per-app caches" "clear AI tool caches" "prune workspace storage" \
              "report active versions" "pending OS / App Store updates" "local Time Machine snapshots" \
              "old downloads" "orphaned launch agents"; do
    assert_contains "safe profile runs: $want" "$(grep "$want" <<<"$sched_out")" "run"
  done
  assert_contains "the safe profile only reports downloads" \
    "$(grep "old downloads" <<<"$sched_out")" "read-only"
  assert_contains "the safe profile only reports launch agents" \
    "$(grep "orphaned launch agents" <<<"$sched_out")" "read-only"
  for keep in "clear user caches" "empty trash" "homebrew update" "dev-tool caches" \
              "old user logs" "docker" "disk report"; do
    assert_contains "safe profile skips: $keep" "$(grep -i "$keep" <<<"$sched_out")" "skip"
  done
  assert_contains "the safe profile lists snapshots read-only" \
    "$(grep "local Time Machine snapshots" <<<"$sched_out")" "read-only"
else
  err "a dry scheduled run wrote no transcript"
fi
if [[ ! -e "$sched_stamp" ]]; then
  ok "a dry scheduled run leaves no scheduled-run stamp"
else
  err "a dry scheduled run wrote the scheduled-run stamp"
fi
# A real scheduled run stamps when it fired and how it ended, for status.
set +e
HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" PATH="$fake_macos/bin:/usr/bin:/bin" \
  STAY_FRESH_NOTIFY=none "$agent" run-scheduled --profile safe >/dev/null 2>&1
set -e
# The stamp gained a third field saying whether the firing did the full job
# (empty when it did), so the shape is now three tab-separated fields with the
# last possibly empty. status reads it with a third variable; a reader that
# stops at the second is unaffected.
if [[ -s "$sched_stamp" ]] && grep -Eq $'^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\t[0-9]+\t[a-z:-]*$' "$sched_stamp"; then
  ok "a real scheduled run writes the scheduled-run stamp with its exit code"
else
  err "a real scheduled run left no usable scheduled-run stamp"; cat "$sched_stamp" >&2 2>/dev/null
fi
assert_eq "an undisturbed scheduled run records no deferral" "" \
  "$(cut -f3 "$sched_stamp" 2>/dev/null)"

# --- --trend turns the recorded runs into an answer ------------------------
# A single run says what it freed today. Only the history says whether the
# cleaning is keeping up, which steps do the work, and which are slowing down.
trend_home="$(mktemp -d)"
trend_state="$trend_home/Library/Logs/stay_fresh"
mkdir -p "$trend_state"
trend() {
  set +e
  HOME="$trend_home" TMPDIR="$trend_home" PATH="$fake_macos/bin:/usr/bin:/bin" \
    "$sf" --trend 2>&1
  set -e
}

out="$(trend)"
assert_eq "--trend with no history at all exits 0" "0" "$?"
assert_contains "--trend says where the history will appear" "$out" "no history yet"

# Rows written before the free-space column existed must not be read as zero
# free space: that would invent a trend out of missing data.
for i in 1 2 3; do
  printf '2026-08-0%d 03:00:00\tOK\t120\t1000000000\t900000000\t20\t0\t0\t3\t2\t1\t\n' "$i"
done > "$trend_state/history.tsv"
out="$(trend)"
assert_contains "--trend counts the legacy rows" "$out" "3 run(s) recorded"
assert_contains "--trend does not invent a free-space trend from old rows" "$out" "not recorded in any row yet"
assert_not_contains "and does not claim the disk is filling up" "$out" "filling up"

# Twelve runs freeing 2 GB each while free space falls 5 GB a run: the cleaning
# is working and losing anyway, which is the finding no single run can report.
: > "$trend_state/history.tsv"; : > "$trend_state/steps.tsv"
for i in $(seq 1 12); do
  printf '2026-08-%02d 03:00:00\tOK\t%d\t2000000000\t1800000000\t20\t0\t0\t3\t2\t1\t\t%d\n' \
    "$i" $(( 100 + i * 5 )) $(( 100000000000 - i * 5000000000 )) >> "$trend_state/history.tsv"
  printf '2026-08-%02d 03:00:00\tuser-caches\t30\t1500000000\tok\n' "$i" >> "$trend_state/steps.tsv"
  printf '2026-08-%02d 03:00:00\tdocker\t%d\t400000000\tok\n' "$i" \
    "$( (( i <= 6 )) && echo 4 || echo 60 )" >> "$trend_state/steps.tsv"
  printf '2026-08-%02d 03:00:00\ttrash\t2\t100000000\tok\n' "$i" >> "$trend_state/steps.tsv"
done
out="$(trend)"
assert_contains "--trend reads the free-space column when it is there" "$out" "free space 2026-08-01"
assert_contains "--trend names a disk that is filling up regardless" "$out" "filling up faster than these runs free it"
assert_contains "--trend names the step that does the most work" \
  "$(grep -A1 'Which steps do the work' <<<"$out" | tail -1)" "user-caches"
assert_contains "--trend flags a step whose runs are getting longer" "$out" "Slowing down"
assert_contains "and names which one, with the before and after" "$(grep -A2 'Slowing down' <<<"$out")" "docker"
assert_not_contains "--trend does not flag a step that is steady" "$(grep -A3 'Slowing down' <<<"$out")" "trash"

# Read-only: a report that rewrites the data it reports on is not a report.
before="$(find "$trend_home" -type f -exec ls -ld {} + 2>/dev/null | sort)"
trend >/dev/null
after="$(find "$trend_home" -type f -exec ls -ld {} + 2>/dev/null | sort)"
assert_eq "--trend writes nothing" "$before" "$after"
rm -rf "$trend_home"

# --- a scheduled run is not worth a battery or an interruption -------------
# Neither probe is faked above, so power_source answers "unknown" and the idle
# probe answers nothing: the runs before this took the ordinary path, which is
# what a desktop with no battery must also get.
sched_run() {
  rm -rf "$fake_macos/home/Library/Logs/stay_fresh"
  set +e
  HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" PATH="$fake_macos/bin:/usr/bin:/bin" \
    STAY_FRESH_NOTIFY=none "$agent" run-scheduled --profile safe "$@" 2>&1
  set -e
}
fake_power() {
  printf '%s\n' '#!/bin/sh' "echo \"Now drawing from '$1'\"" > "$fake_macos/bin/pmset"
  chmod +x "$fake_macos/bin/pmset"
}
fake_idle() {   # seconds since the last keyboard or mouse event
  printf '%s\n' '#!/bin/sh' "echo '  \"HIDIdleTime\" = ${1}000000000'" > "$fake_macos/bin/ioreg"
  chmod +x "$fake_macos/bin/ioreg"
}

fake_power 'Battery Power'; fake_idle 99999
out="$(sched_run)"
assert_contains "on battery the scheduled run defers" "$out" "on battery"
assert_contains "and says how to override it" "$out" "--ignore-power"
assert_eq "the deferral is recorded in the stamp" "deferred:battery" \
  "$(cut -f3 "$fake_macos/home/Library/Logs/stay_fresh/last-scheduled" 2>/dev/null)"
assert_eq "a deferred run does not run stay_fresh.sh at all" "" \
  "$(ls -1 "$fake_macos/home/Library/Logs/stay_fresh"/agent-*.log 2>/dev/null)"

out="$(sched_run --ignore-power)"
assert_not_contains "--ignore-power runs on battery anyway" "$out" "deferring this run"
assert_eq "and records no deferral" "" \
  "$(cut -f3 "$fake_macos/home/Library/Logs/stay_fresh/last-scheduled" 2>/dev/null)"

# On mains, but somebody is typing: the sweep would be minutes of du and rm
# under their hands. The read-only reports run instead — deferring outright
# would mean a machine in use at this hour every day never runs at all.
fake_power 'AC Power'; fake_idle 10
out="$(sched_run)"
assert_contains "an active user downgrades the run to the reports" "$out" "read-only reports only"
assert_eq "the downgrade is recorded in the stamp" "reports-only:active" \
  "$(cut -f3 "$fake_macos/home/Library/Logs/stay_fresh/last-scheduled" 2>/dev/null)"
sched_log="$(ls -1 "$fake_macos/home/Library/Logs/stay_fresh"/agent-*.log 2>/dev/null | head -n 1)"
if [[ -n "$sched_log" ]]; then
  sched_out="$(cat "$sched_log")"
  assert_contains "the downgraded run still reports pending OS updates" \
    "$(grep "pending OS / App Store updates" <<<"$sched_out")" "run"
  for keep in "clear per-app caches" "prune workspace storage" "empty trash"; do
    assert_contains "the downgraded run sweeps nothing: $keep" "$(grep -i "$keep" <<<"$sched_out")" "skip"
  done
else
  err "the downgraded scheduled run wrote no transcript"
fi

# Idle long enough: the ordinary run.
fake_idle 3600
out="$(sched_run)"
assert_not_contains "an idle machine on mains runs normally" "$out" "read-only reports only"
assert_eq "and records no deferral" "" \
  "$(cut -f3 "$fake_macos/home/Library/Logs/stay_fresh/last-scheduled" 2>/dev/null)"

# status surfaces the note rather than hiding a deferral behind an exit code.
printf '%s\t0\tdeferred:battery\n' "$(stamp_days_ago 0)" \
  > "$fake_macos/home/Library/Logs/stay_fresh/last-scheduled"
touch "$agent_plist"
set +e
out="$(agent_status)"
set -e
assert_contains "status says the last firing was deferred" "$out" "deferred:battery"

rm -f "$fake_macos/bin/pmset" "$fake_macos/bin/ioreg"
rm -rf "$fake_macos"

# --- LaunchAgent plist semantics ------------------------------------------
agent="$M/launchd/stay_fresh_agent.sh"
plist_tmp="$(mktemp)"
if "$agent" install --print-only --weekday daily --hour 3 --minute 5 --dry-run \
     > "$plist_tmp"; then
  if python3 - "$plist_tmp" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)

assert data["ProgramArguments"][0] == "/bin/bash"
assert data["ProgramArguments"][-3:] == ["run-scheduled", "--profile", "safe"]
assert data["StartCalendarInterval"] == {"Hour": 3, "Minute": 5}
assert "/opt/homebrew/bin" in data["EnvironmentVariables"]["PATH"].split(":")
assert data["StandardOutPath"] == "/dev/null"
assert data["StandardErrorPath"] == "/dev/null"
assert "StartCalendarIntervalRunMissed" not in data
PY
  then
    ok "LaunchAgent plist has safe unattended semantics"
  else
    err "LaunchAgent plist semantic assertions failed"
  fi
else
  err "LaunchAgent install --print-only failed"
fi
rm -f "$plist_tmp"

# --notify travels into the plist so the scheduled run can reach Telegram; an
# unknown mode is refused before anything is written.
plist_tmp="$(mktemp)"
if "$agent" install --print-only --notify telegram --dry-run > "$plist_tmp" \
   && python3 - "$plist_tmp" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
assert data["ProgramArguments"][-5:] == ["run-scheduled", "--profile", "safe", "--notify", "telegram"]
PY
then
  ok "LaunchAgent plist carries --notify"
else
  err "LaunchAgent plist does not carry --notify"
fi
rm -f "$plist_tmp"
set +e
"$agent" install --print-only --notify pager --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "agent rejects an unknown --notify mode" "3" "$rc"
set +e
"$agent" install --print-only --notify macos,pager --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "agent rejects an unknown channel inside a --notify list" "3" "$rc"
set +e
"$agent" install --print-only --notify= --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "agent rejects an empty --notify" "3" "$rc"
# --notify-when rides into the plist the same way, and is checked the same way.
plist_tmp="$(mktemp)"
if "$agent" install --print-only --notify slack --notify-when warn --dry-run > "$plist_tmp" \
   && python3 - "$plist_tmp" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
assert data["ProgramArguments"][-4:] == ["--notify", "slack", "--notify-when", "warn"], data["ProgramArguments"]
PY
then
  ok "LaunchAgent plist carries --notify-when"
else
  err "LaunchAgent plist does not carry --notify-when"
fi
rm -f "$plist_tmp"
set +e
out="$("$agent" install --print-only --notify-when sometimes --dry-run 2>&1 >/dev/null)"
rc=$?
set -e
assert_eq "agent rejects an unknown --notify-when" "3" "$rc"
assert_contains "the agent relays stay_fresh.sh's --notify-when reason" "$out" \
  "--notify-when must be always, warn or fail"
set +e
"$agent" status --notify-when warn >/dev/null 2>&1
rc=$?
set -e
assert_eq "agent status does not take --notify-when" "3" "$rc"
# The check is stay_fresh.sh's own, so the two cannot disagree: a value the
# scheduled run would refuse is refused at install, with the same message.
set +e
out="$("$agent" install --print-only --notify none,macos --dry-run 2>&1 >/dev/null)"
rc=$?
set -e
assert_eq "agent rejects none combined with a channel, as stay_fresh.sh does" "3" "$rc"
assert_contains "the agent relays stay_fresh.sh's reason" "$out" \
  "--notify none and auto cannot be combined with other channels"
# A channel list travels into the plist unchanged; stay_fresh.sh splits it.
plist_tmp="$(mktemp)"
if "$agent" install --print-only --notify macos,slack --dry-run > "$plist_tmp" \
   && python3 - "$plist_tmp" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
assert data["ProgramArguments"][-2:] == ["--notify", "macos,slack"], data["ProgramArguments"]
PY
then
  ok "LaunchAgent plist carries a --notify channel list"
else
  err "LaunchAgent plist does not carry a --notify channel list"
fi
rm -f "$plist_tmp"
set +e
"$agent" status --notify macos >/dev/null 2>&1
rc=$?
set -e
assert_eq "agent status does not take --notify" "3" "$rc"

if grep -q 'kickstart -k' "$agent"; then
  err "LaunchAgent run-now still kills an active maintenance run"
else
  ok "LaunchAgent run-now does not use kickstart -k"
fi

# --- hardening_audit: the group flags answer before preflight ---
# --list-groups and group validation are the two things this suite can check
# about the audit on Linux, and they are the two worth checking: both have to
# happen ahead of the macOS-only probes, exactly like --help does.
AUDIT="$M/hardening_audit.sh"
if [[ -x "$AUDIT" ]]; then
  set +e
  groups_out="$("$AUDIT" --list-groups 2>&1)"; rc=$?
  set -e
  assert_eq "hardening_audit --list-groups exits 0" "0" "$rc"
  for g in sharing firewall updates disk lock sip gatekeeper; do
    assert_contains "hardening_audit lists the $g group" "$groups_out" "$g"
  done

  set +e
  "$AUDIT" --only nosuchgroup >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "hardening_audit rejects an unknown group -> 3" "3" "$rc"

  set +e
  "$AUDIT" --fail-on sometimes >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "hardening_audit rejects a bad --fail-on -> 3" "3" "$rc"
else
  err "missing $AUDIT"
fi

# The new lock audit is testable without privileged probes and preserves the
# audit's threshold semantics.
audit_fake="$(mktemp -d)"
mkdir -p "$audit_fake/bin"
printf '%s\n' '#!/bin/sh' 'echo Darwin' > "$audit_fake/bin/uname"
printf '%s\n' '#!/bin/sh' 'echo "${LOCK_STATE:-screenLock delay is immediate}"' \
  > "$audit_fake/bin/sysadminctl"
chmod +x "$audit_fake/bin/"*
out="$(PATH="$audit_fake/bin:/usr/bin:/bin" "$AUDIT" --only lock 2>&1)"
assert_contains "hardening audit passes an immediate screen lock" "$out" \
  "password is required immediately"
set +e
LOCK_STATE='screenLock is off' PATH="$audit_fake/bin:/usr/bin:/bin" \
  "$AUDIT" --only lock >/dev/null 2>&1
rc=$?
set -e
assert_eq "hardening audit fails when screen lock is off" "1" "$rc"
rm -rf "$audit_fake"

# --- lib/: stay_fresh.sh hard-depends on the scanner at runtime ---
# The dependency is invoked by absolute path from a step that only runs on
# macOS, so nothing else in this suite would notice the file being renamed,
# moved or broken. Check it here.
scanner="$M/lib/workspace_scan.py"
if [[ -f "$scanner" ]]; then
  ok "lib/workspace_scan.py present"
  if command -v python3 >/dev/null 2>&1; then
    # Compile to an explicit cfile under /tmp. `python3 -m py_compile` writes a
    # __pycache__ next to the source, and the repo is mounted read-only here —
    # which fails with EROFS and looks exactly like a syntax error.
    if python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile="/tmp/ws_scan.pyc", doraise=True)' \
         "$scanner" 2>/dev/null; then
      ok "lib/workspace_scan.py compiles"
    else
      err "lib/workspace_scan.py does not compile"
      python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile="/tmp/ws_scan.pyc", doraise=True)' \
        "$scanner" 2>&1 | tail -3 >&2
    fi
    # stay_fresh.sh reads four NUL-delimited fields; a change to the record shape
    # silently breaks the shell side, which cannot be seen from bash -n.
    scan_tmp="$(mktemp -d)"
    mkdir -p "$scan_tmp/ws/entry" "$scan_tmp/ws/live" "$scan_tmp/ws/remote" \
      "$scan_tmp/project"
    printf '{"folder": "file://%s/gone"}' "$scan_tmp" >"$scan_tmp/ws/entry/workspace.json"
    printf '{"folder": "file://%s/project"}' "$scan_tmp" >"$scan_tmp/ws/live/workspace.json"
    printf '{"folder": "vscode-remote://ssh-remote+host/project"}' \
      >"$scan_tmp/ws/remote/workspace.json"
    if python3 "$scanner" "$scan_tmp/ws" --volumes-dir "$scan_tmp/vol" \
         | tr '\0' '\n' | grep -qx "stale"; then
      ok "lib/workspace_scan.py emits NUL-delimited fields"
    else
      err "lib/workspace_scan.py output shape changed"
    fi
    summary="$(python3 "$scanner" "$scan_tmp/ws" --volumes-dir "$scan_tmp/vol" --summary)"
    if python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["counts"] == {"live": 1, "stale": 1, "total": 3, "unresolved": 1}; assert d["bytes"]["total"] > 0; assert d["bytes"]["total"] == d["bytes"]["live"] + d["bytes"]["stale"] + d["bytes"]["unresolved"]' \
         <<<"$summary"; then
      ok "lib/workspace_scan.py emits count and byte summary"
    else
      err "lib/workspace_scan.py summary contract failed"
    fi
    rm -rf "$scan_tmp"
  else
    ok "python3 absent in this image — skipped scanner compile check"
  fi
else
  err "missing $scanner (stay_fresh.sh invokes it at runtime)"
fi

# The step must name the interpreter absolutely: a bare `python3` picks up
# whichever pyenv shim or activated virtualenv is first on a developer's PATH.
if grep -q 'local py=/usr/bin/python3' "$M/stay_fresh.sh"; then
  ok "stay_fresh.sh pins /usr/bin/python3"
else
  err "stay_fresh.sh no longer pins an absolute interpreter path"
fi

# --- zsh_aliases: must source cleanly in zsh (Linux) ---
if zsh -f -c "source '$M/zsh_aliases.zsh'"; then
  ok "zsh: source zsh_aliases.zsh"
else
  err "zsh: source zsh_aliases.zsh"
fi
aliases_out="$(zsh -f -c "source '$M/zsh_aliases.zsh'; alias workstation-doctor hardening-audit stay-fresh-logs; toolbox-help")"
assert_contains "zsh aliases expose workstation diagnosis" "$aliases_out" "workstation-doctor="
assert_contains "zsh aliases expose scheduled-run logs" "$aliases_out" "stay-fresh-logs="
assert_contains "toolbox-help makes guarded shortcuts discoverable" "$aliases_out" \
  "macOS toolbox commands available"

# Tab completion for stay_fresh.sh: registered once compinit has run, and
# fed by the script's own --help and --list-steps, so a new flag or step id
# is completable the moment it exists. Only the option lines feed it: the
# help's Notes quote `softwareupdate --list` and `--install`, and neither is
# a stay_fresh flag.
comp_out="$(zsh -f -c "autoload -Uz compinit; compinit -u -D; source '$M/zsh_aliases.zsh'
print -r -- registered=\${_comps[stay_fresh.sh]} alias=\${_comps[stay-fresh]}
_stay_fresh_flags
_stay_fresh_step_ids" 2>&1)"
assert_contains "zsh: completion is registered for the script" "$comp_out" "registered=_stay_fresh"
assert_contains "zsh: completion is registered for the alias" "$comp_out" "alias=_stay_fresh"
assert_contains "zsh: completion offers --step-timeout" "$comp_out" "--step-timeout"
assert_contains "zsh: completion offers --reports" "$comp_out" "--reports"
assert_contains "zsh: completion offers --notify-when" "$comp_out" "--notify-when"
assert_contains "zsh: completion offers --prune-downloads-days" "$comp_out" "--prune-downloads-days"
assert_contains "zsh: completion offers the short-flag options too" "$comp_out" "--verbose"
assert_contains "zsh: completion knows the step ids" "$comp_out" "workspace-storage"
assert_not_contains "zsh: completion does not offer flags quoted in the notes" "$comp_out" "--install"
assert_not_contains "zsh: completion does not offer softwareupdate's --list" "$comp_out" $'\n--list\n'

# A shadow is only allowed when the replacement accepts the same flags. fd and
# rg do not - `find . -name` errors under fd, `grep -rn pattern dir` changes
# meaning under rg - so a command copied from a runbook breaks exactly on the
# machine that aliased them. Checked as text because the aliases are guarded:
# in a container without fd installed they would never register, and a
# behavioural test here would pass whether or not the shadow existed.
if grep -qE "alias (find|grep)='(fd|rg)'" "$M/zsh_aliases.zsh"; then
  err "zsh_aliases.zsh shadows find or grep with a flag-incompatible tool"
else
  ok "zsh: find and grep are not shadowed by fd/rg"
fi

# sudo's trailing space makes the word after it eligible for alias expansion,
# which is what lets `sudo <alias>` work at all.
sudo_alias="$(zsh -f -c "source '$M/zsh_aliases.zsh'; alias sudo")"
if [ "$sudo_alias" = "sudo='sudo '" ]; then
  ok "zsh: sudo alias keeps its trailing space"
else
  err "zsh: sudo alias lost its trailing space: $sudo_alias"
fi

# retry is unguarded, so it must exist and keep its contract everywhere:
# 0 on success, the command's own exit code on exhaustion, 2 on bad usage.
retry_out="$(zsh -f -c "source '$M/zsh_aliases.zsh'
retry 1 true; echo rc_ok=\$?
retry 2 false 2>/dev/null; echo rc_fail=\$?
retry x true 2>/dev/null; echo rc_usage=\$?")"
assert_contains "retry returns 0 on success" "$retry_out" "rc_ok=0"
assert_contains "retry surfaces the command's exit code" "$retry_out" "rc_fail=1"
assert_contains "retry rejects bad usage with 3-adjacent code 2" "$retry_out" "rc_usage=2"

if (( failures )); then
  echo "=== $failures test(s) failed ===" >&2
  exit 1
fi
echo "=== all macos-initial-setup (docker) checks passed ==="
exit 0

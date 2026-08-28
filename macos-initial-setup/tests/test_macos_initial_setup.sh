#!/usr/bin/env bash
# Run from the Linux tester container; repo root is mounted at /repo.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
M="$REPO_ROOT/macos-initial-setup"

if [[ ! -d "$M" ]]; then
  echo "expected macos-initial-setup at $M" >&2
  exit 1
fi

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
for step_id in brew docker workspace-storage versions; do
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
printf '%s\n' '#!/bin/sh' \
  'for arg in "$@"; do [ "$arg" = Slack ] && exit 0; done; exit 1' \
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

mkdir -p "$fake_macos/tmp/stay_fresh-${UID}.lock"
printf '%s\n' "$$" > "$fake_macos/tmp/stay_fresh-${UID}.lock/pid"
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${skip_for_plan[@]}" 2>&1)"
rc=$?
set -e
assert_eq "overlapping stay_fresh run is rejected" "2" "$rc"
assert_contains "overlap refusal identifies the active run" "$out" \
  "another stay_fresh run is active"
rm -f "$fake_macos/tmp/stay_fresh-${UID}.lock/pid"
rmdir "$fake_macos/tmp/stay_fresh-${UID}.lock"

# A kill can land after mkdir(2) but before the pid file is written. That empty
# directory is stale and must not disable maintenance forever.
mkdir -p "$fake_macos/tmp/stay_fresh-${UID}.lock"
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${skip_for_plan[@]}" 2>&1)"
assert_contains "empty stale lock is recovered" "$out" \
  "removing stale stay_fresh lock without a live pid"
if [[ ! -d "$fake_macos/tmp/stay_fresh-${UID}.lock" ]]; then
  ok "recovered stale lock is released after the run"
else
  err "recovered stale lock remained after the run"
fi

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
# no-op that reads as success. There is no docker or brew on the fake PATH yet,
# which is exactly the machine this has to be right on.
set +e
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  --only docker 2>&1)"
rc=$?
set -e
assert_eq "a fully voided --only selection fails preflight -> 2" "2" "$rc"
assert_contains "voided --only names the step that cannot run" "$out" \
  "--only docker: the Docker CLI is not installed"

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
  "--only docker: the Docker CLI is not installed"
assert_contains "partially voided --only runs the surviving step" "$out" \
  "Active tool versions"

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
  --skip-xcode --skip-diagnostics --skip-devtools
)
out="$(HOME="$fake_macos/home" TMPDIR="$fake_macos/tmp" \
  PATH="$fake_macos/bin:/usr/bin:/bin" "$M/stay_fresh.sh" --yes --no-sudo \
  "${brew_absent_skip[@]}" 2>&1)"
assert_contains "an all-skipped run counts each step exactly once" "$out" \
  "skipped:     15"
assert_not_contains "the auto-skipped step is not booked a second time" "$out" \
  "brew (not installed)"
assert_contains "a skipped step reports why it was skipped" "$out" \
  "Homebrew update / upgrade / cleanup (Homebrew is not installed)"

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
# formulae exactly once and must never start a cask pass.
brew_calls="$fake_macos/brew.calls"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$BREW_CALLS"' \
  'case "${1:-}" in --version) echo "Homebrew test" ;; --prefix) echo /opt/homebrew ;; esac' \
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
assert data["ProgramArguments"][-2:] == ["run-scheduled", "--dry-run"]
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

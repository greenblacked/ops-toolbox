#!/usr/bin/env bash
# Contract and behaviour checks for dotfiles/dotfiles_doctor.sh.
#
# The doctor is read-only, so every section asserts two things: the verdict
# it prints for a fixture, and that the scratch home and tmp are byte-for-byte
# the same afterwards. Fixtures are a fake dotfiles folder and a scratch home
# whose configs are links into it, built here, so no tracked file is ever
# edited to make a finding appear. Token-shaped values are assembled at run
# time and never written out literally, so a secret scanner reading this file
# finds nothing to report.
set -uo pipefail

# -P: the doctor resolves --repo physically, and the link texts written below
# are compared against paths derived from this one.
HERE="$(cd -P "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
D="$REPO_ROOT/dotfiles"
DOCTOR="$D/dotfiles_doctor.sh"
INSTALLER="$D/install_dotfiles.sh"

failures=0
ok()   { printf '[ ok ] %s\n' "$*"; }
err()  { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
skip() { printf '[skip] %s\n' "$*"; }
head_() { printf '\n--- %s ---\n' "$*"; }

assert_rc() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok "$label"; else err "$label (expected exit $want, got $got)"; fi
}

# Same argument order as test_dotfiles.sh and linux/tests/test_linux_scripts.sh.
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
  else
    ok "$label"
  fi
}

assert_true() {
  local label="$1"; shift
  if "$@"; then ok "$label"; else err "$label"; fi
}

TIMEOUT_BIN="$(command -v timeout || true)"
if [[ -n "$TIMEOUT_BIN" ]]; then guard() { "$TIMEOUT_BIN" 20 "$@"; }; else guard() { "$@"; }; fi

# Physical, for the same reason as HERE: on macOS mktemp answers under /var,
# which is a link to /private/var.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd -P "$scratch" && pwd)"
H="$scratch/home"
T="$scratch/tmp"
R="$scratch/repo"
mkdir -p "$H" "$T"

# Every doctor run gets the scratch home and tmp, and none of the variables
# the doctor reads: with --home it ignores XDG_CONFIG_HOME by design, a test
# must never be able to reach the developer's real config directory whatever
# the shell exports, and an exported RIPGREP_CONFIG_PATH or GITLEAKS_CONFIG
# would turn the environment-hook verdicts into the developer's own.
NOENV=(-u XDG_CONFIG_HOME -u RIPGREP_CONFIG_PATH -u GITLEAKS_CONFIG)
run_doctor_in() {
  local home="$1"; shift
  guard env "${NOENV[@]}" HOME="$home" TMPDIR="$T" "$DOCTOR" --home "$home" "$@"
}
run_doctor() { run_doctor_in "$H" "$@"; }

# Names plus mtimes of both scratch directories, so a rewritten file is
# caught as well as a new one, and a log written to TMPDIR is caught too.
snapshot() { find "$1" "$2" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort; }
# macOS find has no -printf; fall back to one batched ls there.
if ! find "$scratch" -maxdepth 0 -printf '' >/dev/null 2>&1; then
  snapshot() { find "$1" "$2" -mindepth 1 -exec ls -ld {} + 2>/dev/null | sort; }
fi

# A fake dotfiles folder with one file in each tree, and a scratch home whose
# targets are links into it: the layout install_dotfiles.sh produces.
make_fixture() {
  rm -rf "$R" "$H"
  mkdir -p "$R/config/foo" "$R/home" "$H/.config/foo"
  printf '# foo settings\ncolour = auto\n' > "$R/config/foo/conf"
  printf '# npm settings\nsave-exact=true\n' > "$R/home/.npmrc"
  ln -s "$R/config/foo/conf" "$H/.config/foo/conf"
  ln -s "$R/home/.npmrc" "$H/.npmrc"
}

# A GitHub token shape, assembled here so the literal never sits in this file.
TOKEN="$(printf 'ghp_%s' "$(printf '%036d' 0)")"

# --------------------------------------------------------------------------
head_ "CLI contract"
out="$(guard "$DOCTOR" --help 2>&1)"; rc=$?
assert_rc "--help exits 0" 0 "$rc"
assert_contains "--help documents the exit codes" "$out" "Exit codes:"
# The static suite runs every script whose help names a dry-run flag with that
# flag alone. This one writes nothing and has none, so its help must not.
assert_not_contains "--help advertises no dry-run flag" "$out" "--dry-run"

guard "$DOCTOR" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_rc "unknown flag exits 3" 3 "$rc"
run_doctor --fail-on bogus >/dev/null 2>&1; rc=$?
assert_rc "--fail-on bogus exits 3" 3 "$rc"
guard "$DOCTOR" --repo >/dev/null 2>&1; rc=$?
assert_rc "--repo without a value exits 3" 3 "$rc"
guard env "${NOENV[@]}" HOME="$H" TMPDIR="$T" "$DOCTOR" --home "$scratch/does-not-exist" >/dev/null 2>&1; rc=$?
assert_rc "a missing home directory exits 2" 2 "$rc"
make_fixture
out="$(run_doctor --repo="$R" 2>&1)"; rc=$?
assert_rc "--repo=VALUE is accepted" 0 "$rc"
run_doctor --repo "$scratch" >/dev/null 2>&1; rc=$?
assert_rc "--repo without config/ and home/ exits 2" 2 "$rc"

# --------------------------------------------------------------------------
head_ "linked configs"
make_fixture
before="$(snapshot "$H" "$T")"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "clean linked configs exit 0" 0 "$rc"
assert_contains "clean linked configs pass" "$out" "[pass] 2 linked configs hold no credential"
if [[ "$before" == "$after" ]]; then ok "the doctor left the home and tmp untouched"; else err "the doctor wrote into the home or tmp"; fi

printf 'token = %s\n' "$TOKEN" >> "$R/config/foo/conf"
before="$(snapshot "$H" "$T")"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "a token in a linked config exits 1" 1 "$rc"
assert_contains "the finding names the target" "$out" "[FAIL] $H/.config/foo/conf: GitHub token at line 3"
assert_contains "the fix names the tracked file" "$out" "diff -- config/foo/conf"
assert_not_contains "the token itself is never printed" "$out" "$TOKEN"
assert_not_contains "no part of the token is printed" "$out" "ghp_"
if [[ "$before" == "$after" ]]; then ok "a run with a finding wrote nothing"; else err "a run with a finding wrote into the home or tmp"; fi

make_fixture
# The documented way to keep an npm token out of the file: an environment
# reference, which npm expands at run time.
# shellcheck disable=SC2016  # the literal ${...} is the fixture
printf '//r/:_authToken=${NPM_TOKEN}\n' >> "$R/home/.npmrc"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "an npm token read from the environment passes" 0 "$rc"
assert_not_contains "an environment reference is not a finding" "$out" "[FAIL]"

make_fixture
printf '# //r/:_authToken=abc\n; _password=abc\n' >> "$R/home/.npmrc"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "a keyed value in a comment line passes" 0 "$rc"
assert_not_contains "comment lines are not findings" "$out" "[FAIL]"

make_fixture
printf '//r/:_authToken=abc\n' >> "$R/home/.npmrc"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "a literal npm token exits 1" 1 "$rc"
assert_contains "a literal npm token is reported with its line" "$out" "$H/.npmrc: npm auth value at line 3"

make_fixture
printf 'index-url = https://user:secret@pypi.example.invalid/simple\n' >> "$R/config/foo/conf"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "a password in a URL exits 1" 1 "$rc"
assert_contains "a password in a URL is reported" "$out" "password in a URL at line 3"
assert_not_contains "the URL password is never printed" "$out" "secret@"

# A copy is not a link into the repository, so whatever its tool wrote there
# never reaches a tracked file.
make_fixture
rm "$H/.npmrc"
printf '//r/:_authToken=%s\n' "$TOKEN" > "$H/.npmrc"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "a token in a regular-file target is not a finding" 0 "$rc"
assert_not_contains "a copy is not scanned" "$out" "[FAIL]"

make_fixture
rm "$H/.config/foo/conf"
ln -s "$R/config/foo/renamed" "$H/.config/foo/conf"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "a dangling link into the repository is a warning, exit 0" 0 "$rc"
assert_contains "the dangling link is named" "$out" "[warn] $H/.config/foo/conf links into $R"
run_doctor --repo "$R" --fail-on warn >/dev/null 2>&1; rc=$?
assert_rc "--fail-on warn turns the warning into exit 1" 1 "$rc"
run_doctor --repo "$R" --fail-on=warn >/dev/null 2>&1; rc=$?
assert_rc "--fail-on=warn is accepted" 1 "$rc"

# Copied alone into a bin directory, as CONTRIBUTING's one rule asks.
make_fixture
mkdir -p "$scratch/bin"
cp "$DOCTOR" "$scratch/bin/dotfiles_doctor.sh"
out="$(guard env "${NOENV[@]}" HOME="$H" TMPDIR="$T" "$scratch/bin/dotfiles_doctor.sh" --home "$H" 2>&1)"; rc=$?
assert_rc "a copy alone in a bin directory exits 0" 0 "$rc"
assert_contains "the link check is skipped with no repository beside it" "$out" "[skip] linked configs: no config/ and home/ beside this script"

# --------------------------------------------------------------------------
head_ "credential files"
# Modes are read back with the same stat fallback the suite uses elsewhere, so
# a fixture is known to carry the mode it claims on GNU and BSD stat alike.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
# Every fixture holds this line, and no output may: the doctor only stats.
SENTINEL="doctor-sentinel-$$"
cred() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$SENTINEL" > "$1"
  chmod "$2" "$1"
  [[ "$(mode_of "$1")" == "$2" ]] || err "fixture $1 is mode $(mode_of "$1"), wanted $2"
}
all_out=""
rm -rf "$H"; mkdir -p "$H"

out="$(run_doctor 2>&1)"; rc=$?; all_out="$all_out$out"
assert_rc "no credential files exits 0" 0 "$rc"
assert_contains "absent credential files are counted, not listed" "$out" "[skip] 11 of 11 credential files not present"

cred "$H/.aws/credentials" 600
before="$(snapshot "$H" "$T")"
out="$(run_doctor 2>&1)"; rc=$?; all_out="$all_out$out"
after="$(snapshot "$H" "$T")"
assert_rc "a private credential file exits 0" 0 "$rc"
assert_contains "a mode 600 credential file passes" "$out" "[pass] $H/.aws/credentials mode 600"
assert_contains "the present file leaves 10 absent" "$out" "[skip] 10 of 11 credential files not present"
if [[ "$before" == "$after" ]]; then ok "the credential check wrote nothing"; else err "the credential check wrote into the home or tmp"; fi

cred "$H/.kube/config" 644
out="$(run_doctor 2>&1)"; rc=$?; all_out="$all_out$out"
assert_rc "a group-readable credential file is a warning, exit 0" 0 "$rc"
assert_contains "a mode 644 credential file is reported" "$out" "[warn] $H/.kube/config mode 644 is readable by group or other"
assert_contains "the fix is printed, not run" "$out" "chmod 600 $H/.kube/config"
assert_true "the doctor did not chmod it" test "$(mode_of "$H/.kube/config")" = 644
out="$(run_doctor --fail-on warn 2>&1)"; rc=$?; all_out="$all_out$out"
assert_rc "--fail-on warn exits 1 on a readable credential file" 1 "$rc"
rm "$H/.kube/config"

cred "$H/.netrc" 666
out="$(run_doctor 2>&1)"; rc=$?; all_out="$all_out$out"
assert_rc "a world-writable credential file exits 1" 1 "$rc"
assert_contains "a mode 666 credential file fails" "$out" "[FAIL] $H/.netrc mode 666 is writable by group or other"
rm "$H/.netrc"

# A link is followed: the mode that matters is the file the tool reads.
cred "$scratch/vault/hosts.yml" 600
mkdir -p "$H/.config/gh"
ln -s "$scratch/vault/hosts.yml" "$H/.config/gh/hosts.yml"
out="$(run_doctor 2>&1)"; rc=$?; all_out="$all_out$out"
assert_rc "a link to a private file exits 0" 0 "$rc"
assert_contains "a link is judged by the file it leads to" "$out" "[pass] $H/.config/gh/hosts.yml mode 600"

assert_not_contains "no credential file content reached the output" "$all_out" "$SENTINEL"

# --------------------------------------------------------------------------
head_ "environment hooks"
# Stub commands decide which tools are "installed", so the verdicts do not
# depend on what the host has. A stub only has to exist; nothing runs it.
STUBS="$scratch/stubs"
mkdir -p "$STUBS"
stub() { printf '#!/bin/sh\nexit 0\n' > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
stub rg
stub gitleaks
rm -rf "$H"; mkdir -p "$H/.config/ripgrep" "$H/.config/gitleaks"
: > "$H/.config/ripgrep/config"
: > "$H/.config/gitleaks/gitleaks.toml"

# hooks [VAR=value ...] -- [doctor flags ...]: the variables for this one run
# on top of a clean environment, with the stubs ahead of the host PATH.
hooks() {
  local vars=()
  while (( $# > 0 )) && [[ "$1" != "--" ]]; do vars+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  guard env "${NOENV[@]}" HOME="$H" TMPDIR="$T" PATH="$STUBS:$PATH" ${vars[@]+"${vars[@]}"} "$DOCTOR" --home "$H" "$@"
}

before="$(snapshot "$H" "$T")"
out="$(hooks -- --platform linux 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "unexported hooks are warnings, exit 0" 0 "$rc"
assert_contains "an unexported RIPGREP_CONFIG_PATH is reported" "$out" "[warn] RIPGREP_CONFIG_PATH is not exported: rg will not read $H/.config/ripgrep/config"
assert_contains "the export line is printed" "$out" "export RIPGREP_CONFIG_PATH=\"$H/.config/ripgrep/config\""
assert_contains "an unexported GITLEAKS_CONFIG is reported" "$out" "[warn] GITLEAKS_CONFIG is not exported"
if [[ "$before" == "$after" ]]; then ok "the hook check wrote nothing"; else err "the hook check wrote into the home or tmp"; fi
hooks -- --platform linux --fail-on warn >/dev/null 2>&1; rc=$?
assert_rc "--fail-on warn exits 1 on an unexported hook" 1 "$rc"

out="$(hooks RIPGREP_CONFIG_PATH="$H/.config/ripgrep/config" GITLEAKS_CONFIG="$H/.config/gitleaks/gitleaks.toml" -- --platform linux 2>&1)"; rc=$?
assert_rc "exported hooks that lead to a file exit 0" 0 "$rc"
assert_contains "RIPGREP_CONFIG_PATH passes" "$out" "[pass] RIPGREP_CONFIG_PATH points at $H/.config/ripgrep/config"
assert_contains "GITLEAKS_CONFIG passes" "$out" "[pass] GITLEAKS_CONFIG points at $H/.config/gitleaks/gitleaks.toml"

out="$(hooks RIPGREP_CONFIG_PATH="$H/nowhere/config" -- --platform linux 2>&1)"; rc=$?
assert_rc "RIPGREP_CONFIG_PATH at a missing file exits 1" 1 "$rc"
assert_contains "the missing ripgrep config is named" "$out" "[FAIL] RIPGREP_CONFIG_PATH points at $H/nowhere/config, which does not exist"
out="$(hooks GITLEAKS_CONFIG="$H/nowhere/gitleaks.toml" -- --platform linux 2>&1)"; rc=$?
assert_rc "GITLEAKS_CONFIG at a missing file exits 1" 1 "$rc"
assert_contains "the missing gitleaks config is named" "$out" "[FAIL] GITLEAKS_CONFIG points at $H/nowhere/gitleaks.toml, which does not exist"

stub k9s
out="$(hooks -- --platform macos 2>&1)"; rc=$?
assert_rc "an unexported XDG_CONFIG_HOME on macOS is a warning, exit 0" 0 "$rc"
assert_contains "the macOS fallback path is named" "$out" "Application Support"
out="$(hooks XDG_CONFIG_HOME="$H/.config" -- --platform=macos 2>&1)"; rc=$?
assert_rc "--platform=macos is accepted" 0 "$rc"
assert_contains "XDG_CONFIG_HOME naming the config directory passes" "$out" "[pass] XDG_CONFIG_HOME is $H/.config"
out="$(hooks XDG_CONFIG_HOME="$scratch/elsewhere" -- --platform macos 2>&1)"
assert_contains "XDG_CONFIG_HOME naming another directory is reported" "$out" "XDG_CONFIG_HOME is $scratch/elsewhere, but the configs were installed under $H/.config"
out="$(hooks -- --platform linux 2>&1)"
assert_contains "XDG_CONFIG_HOME is a macOS-only hook" "$out" "[skip] XDG_CONFIG_HOME: only needed on macOS"
hooks -- --platform bogus >/dev/null 2>&1; rc=$?
assert_rc "--platform bogus exits 3" 3 "$rc"

# No stub and no host tool: a PATH of only the utilities the doctor calls,
# linked one by one, and the doctor started through $BASH so env needs no
# PATH lookup of its own.
MINBIN="$scratch/minbin"
mkdir -p "$MINBIN"
for u in awk basename cat cut dirname find grep id readlink sed sort stat uname; do
  p="$(command -v "$u" || true)"
  [[ -n "$p" && "$p" == /* ]] && ln -s "$p" "$MINBIN/$u"
done
out="$(guard env "${NOENV[@]}" HOME="$H" TMPDIR="$T" PATH="$MINBIN" "$BASH" "$DOCTOR" --home "$H" --platform linux 2>&1)"; rc=$?
assert_rc "no tools on PATH exits 0" 0 "$rc"
assert_contains "a missing rg is skipped" "$out" "[skip] RIPGREP_CONFIG_PATH: rg not installed"
assert_contains "a missing gitleaks is skipped" "$out" "[skip] GITLEAKS_CONFIG: gitleaks not installed"

# --------------------------------------------------------------------------
head_ "the shipped tree is clean"
# The false-positive guard: the configs this repository ships, installed the
# way the installer installs them, must give no finding at all. It mirrors the
# credential grep in test_dotfiles.sh from the other side.
H2="$scratch/shipped"
mkdir -p "$H2"
guard env -u XDG_CONFIG_HOME HOME="$H2" TMPDIR="$T" "$INSTALLER" --home "$H2" --quiet >/dev/null 2>&1; rc=$?
assert_rc "install_dotfiles.sh installs into a scratch home" 0 "$rc"
before="$(snapshot "$H2" "$T")"
out="$(run_doctor_in "$H2" --repo "$D" 2>&1)"; rc=$?
after="$(snapshot "$H2" "$T")"
assert_rc "the shipped configs give no failure" 0 "$rc"
assert_contains "the shipped configs are scanned through their links" "$out" "linked configs hold no credential"
assert_not_contains "the shipped configs give no finding" "$out" "[FAIL]"
if [[ "$before" == "$after" ]]; then ok "the doctor left the installed home untouched"; else err "the doctor wrote into the installed home"; fi

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%s doctor check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all doctor checks passed\n'

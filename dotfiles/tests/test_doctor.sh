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

# Every doctor run gets the scratch home and tmp, and no XDG_CONFIG_HOME: with
# --home the doctor ignores it by design, and a test must never be able to
# reach the developer's real config directory whatever the shell exports.
run_doctor_in() {
  local home="$1"; shift
  guard env -u XDG_CONFIG_HOME HOME="$home" TMPDIR="$T" "$DOCTOR" --home "$home" "$@"
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
guard env -u XDG_CONFIG_HOME HOME="$H" TMPDIR="$T" "$DOCTOR" --home "$scratch/does-not-exist" >/dev/null 2>&1; rc=$?
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
out="$(guard env -u XDG_CONFIG_HOME HOME="$H" TMPDIR="$T" "$scratch/bin/dotfiles_doctor.sh" --home "$H" 2>&1)"; rc=$?
assert_rc "a copy alone in a bin directory exits 0" 0 "$rc"
assert_contains "the link check is skipped with no repository beside it" "$out" "[skip] linked configs: no config/ and home/ beside this script"

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

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
# the shell exports, an exported RIPGREP_CONFIG_PATH or GITLEAKS_CONFIG would
# turn the environment-hook verdicts into the developer's own, and a
# GIT_CONFIG_GLOBAL would aim the git checks at the developer's config.
NOENV=(-u XDG_CONFIG_HOME -u RIPGREP_CONFIG_PATH -u GITLEAKS_CONFIG -u GIT_CONFIG_GLOBAL)
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

# A link whose text starts with the repository path but climbs out of it with
# `..` must not make the doctor read the file it names, and neither must an
# alias inside the repository that is itself a link to a file outside.
make_fixture
printf 'token = %s\n' "$TOKEN" > "$scratch/outside-secret"
rm "$H/.config/foo/conf"
ln -s "$R/config/foo/../../../outside-secret" "$H/.config/foo/conf"
before="$(snapshot "$H" "$T")"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "a link that climbs out of the repository is not read" 0 "$rc"
assert_not_contains "the outside file is not scanned" "$out" "[FAIL]"
assert_not_contains "the outside file is not counted as a linked config" "$out" "GitHub token"
assert_contains "only the genuine link is counted" "$out" "[pass] 1 linked configs hold no credential"
if [[ "$before" == "$after" ]]; then ok "the traversing link left the home and tmp untouched"; else err "the traversing link run wrote into the home or tmp"; fi

make_fixture
rm "$H/.config/foo/conf"
ln -s "$scratch/outside-secret" "$R/config/foo/alias"
ln -s "$R/config/foo/alias" "$H/.config/foo/conf"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "an in-repository alias to an outside file is not read" 0 "$rc"
assert_not_contains "the alias target is not scanned" "$out" "[FAIL]"
rm -f "$scratch/outside-secret"

# Links for a config that was renamed or deleted in the repository are not
# driven by any current source, so they are looked for in the install
# locations. Links elsewhere, or to other places, are never reported.
make_fixture
mkdir -p "$H/.config/gone" "$H/.olddir"
ln -s "$R/config/gone/conf" "$H/.config/gone/conf"
ln -s "$R/home/.gonerc" "$H/.gonerc"
ln -s "$R/home/.olddir/settings" "$H/.olddir/settings"
ln -s "$R/config/gone/conf" "$H/.config/gone/conf.backup-20260101-000000"
ln -s "$scratch/not-the-repo/x" "$H/.config/gone/foreign"
before="$(snapshot "$H" "$T")"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "orphan links are warnings, exit 0" 0 "$rc"
assert_contains "an orphan under the config home is named" "$out" "[warn] $H/.config/gone/conf links into $R, but $R/config/gone/conf does not exist"
assert_contains "an orphan at the top of the home is named" "$out" "[warn] $H/.gonerc links into $R"
assert_contains "an orphan in a deleted source directory is named" "$out" "[warn] $H/.olddir/settings links into $R"
assert_not_contains "a --force backup is not reported" "$out" "conf.backup-"
assert_not_contains "a dangling link elsewhere is not reported" "$out" "$H/.config/gone/foreign"
assert_contains "the tracked links still pass" "$out" "[pass] 2 linked configs hold no credential"
run_doctor --repo "$R" --fail-on warn >/dev/null 2>&1; rc=$?
assert_rc "--fail-on warn turns an orphan into exit 1" 1 "$rc"
if [[ "$before" == "$after" ]]; then ok "the orphan scan wrote nothing"; else err "the orphan scan wrote into the home or tmp"; fi

# A renamed install target whose old link still points at an existing,
# tracked file is read by its tool, so the credential scan covers it too.
make_fixture
printf '//r/:_authToken=abc\n' >> "$R/home/.npmrc"
rm "$H/.npmrc"
ln -s "$R/home/.npmrc" "$H/.npmrc-old"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "a live orphan link to a credential exits 1" 1 "$rc"
assert_contains "the live orphan is scanned and named" "$out" "$H/.npmrc-old: npm auth value at line 3"
assert_not_contains "a live orphan is not reported as dangling" "$out" "[warn] $H/.npmrc-old"

make_fixture
ln -s "$R/home/.npmrc" "$H/.npmrc-old"
out="$(run_doctor --repo "$R" 2>&1)"; rc=$?
assert_rc "a clean live orphan link exits 0" 0 "$rc"
assert_not_contains "a clean live orphan is not a finding" "$out" "[FAIL]"

# A tracked target that dangles is reported once, by the tracked-file loop.
make_fixture
rm "$H/.config/foo/conf"
ln -s "$R/config/foo/renamed" "$H/.config/foo/conf"
out="$(run_doctor --repo "$R" 2>&1)"
n="$(grep -c "conf links into" <<<"$out")"
if [[ "$n" == 1 ]]; then ok "a dangling tracked target is reported once"; else err "a dangling tracked target was reported $n times"; fi

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

out="$(hooks RIPGREP_CONFIG_PATH="$H/.config/ripgrep" -- --platform linux 2>&1)"; rc=$?
assert_rc "RIPGREP_CONFIG_PATH at a directory exits 1" 1 "$rc"
assert_contains "the directory is not accepted as a config file" "$out" "[FAIL] RIPGREP_CONFIG_PATH points at $H/.config/ripgrep, which is not a readable file"

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
head_ "ssh and git overlays"
# The doctor must never run ssh: `ssh -G` evaluates Match exec lines and so
# runs commands. A stub ssh first on PATH leaves a marker if anything calls it,
# and the config holds Match exec lines, directly and through an Include.
SSHSTUB="$scratch/sshstub"; marker="$T/ssh-ran-marker"
mkdir -p "$SSHSTUB"
printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$marker" > "$SSHSTUB/ssh"
chmod +x "$SSHSTUB/ssh"
rm -rf "$H"; mkdir -p "$H/.ssh/config.d"; chmod 700 "$H/.ssh"
printf 'Match exec "touch %s"\nHost *\n  HashKnownHosts yes\nInclude config.d/*\n' "$marker" > "$H/.ssh/config"
printf 'Match host a Exec "touch %s"\n' "$marker" > "$H/.ssh/config.d/x.conf"
printf 'plain.example.invalid ssh-ed25519 AAAA\n' > "$H/.ssh/known_hosts"
before="$(snapshot "$H" "$T")"
out="$(guard env "${NOENV[@]}" HOME="$H" TMPDIR="$T" PATH="$SSHSTUB:$PATH" "$DOCTOR" --home "$H" --platform linux 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "an ssh config with Match exec exits 0" 0 "$rc"
if [[ -e "$marker" ]]; then err "the doctor ran ssh"; else ok "the doctor never ran ssh"; fi
assert_contains "the ssh config is read as text" "$out" "[pass] ssh config $H/.ssh/config read as text (ssh is never run)"
assert_contains "HashKnownHosts under Host * is found without ssh" "$out" "[warn] 1 plaintext host entries in known_hosts although HashKnownHosts is on"
if [[ "$before" == "$after" ]]; then ok "the ssh check wrote nothing"; else err "the ssh check wrote into the home or tmp"; fi
# A HashKnownHosts inside a Host block other than Host * is not global.
printf 'Host a\n  HashKnownHosts yes\n' > "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"
assert_contains "HashKnownHosts in another Host block is not global" "$out" "[skip] known_hosts: HashKnownHosts is not on in $H/.ssh/config"
rm -rf "$H/.ssh/config.d" "$SSHSTUB"; rm -f "$marker"
# The shipped config turns HashKnownHosts on under Host *, but its Include
# line comes first and may set the option, so hashing is not judged.
cp "$D/home/.ssh/config" "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"; rc=$?
assert_rc "the shipped ssh config exits 0" 0 "$rc"
assert_contains "the shipped config is read as text" "$out" "[pass] ssh config $H/.ssh/config read as text (ssh is never run)"
assert_contains "the shipped config's Include means hashing is not judged" "$out" "[info] known_hosts: HashKnownHosts not judged: an Include before it may set it ($H/.ssh/config)"
printf 'plain.example.invalid ssh-ed25519 AAAA\n' > "$H/.ssh/known_hosts"
out="$(run_doctor --platform linux 2>&1)"
assert_not_contains "an Include before Host * gives no plaintext warning" "$out" "plaintext host entries"
# Without an Include, Host * HashKnownHosts no is judged and does not warn.
printf 'Host *\n  HashKnownHosts no\n' > "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"
assert_not_contains "HashKnownHosts no gives no plaintext warning" "$out" "plaintext host entries"
assert_contains "HashKnownHosts no is skipped" "$out" "[skip] known_hosts: HashKnownHosts is not on in $H/.ssh/config"
# Without an Include, Host * HashKnownHosts yes is judged and warns.
printf 'Host *\n  HashKnownHosts yes\n' > "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"
assert_contains "no Include: Host * HashKnownHosts yes warns" "$out" "[warn] 1 plaintext host entries in known_hosts although HashKnownHosts is on"
# Match all is global, like Host *.
printf 'Match all\n  HashKnownHosts yes\n' > "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"
assert_contains "Match all is treated as global" "$out" "[warn] 1 plaintext host entries in known_hosts although HashKnownHosts is on"
# A quoted value and a trailing comment are accepted.
printf 'Host * # everything\n  HashKnownHosts "yes" # on\n' > "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"
assert_contains "a quoted yes and comments are accepted" "$out" "[warn] 1 plaintext host entries in known_hosts although HashKnownHosts is on"
# An Include after the found line does not matter; one at the end with no
# HashKnownHosts line still means not judged.
printf 'Host *\n  HashKnownHosts yes\nInclude config.d/*\n' > "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"
assert_contains "an Include after the line is ignored" "$out" "[warn] 1 plaintext host entries"
printf 'Include config.d/*\n' > "$H/.ssh/config"
out="$(run_doctor --platform linux 2>&1)"
assert_contains "an Include and no HashKnownHosts is not judged" "$out" "[info] known_hosts: HashKnownHosts not judged"
# The remaining known_hosts checks need hashing judged on.
printf 'Host *\n  HashKnownHosts yes\n' > "$H/.ssh/config"

printf '# a comment\n|1|abc=|def= ssh-ed25519 AAAA\nplain-one.example.invalid ssh-ed25519 AAAA\n@cert-authority plain-two.example.invalid ssh-ed25519 AAAA\n' > "$H/.ssh/known_hosts"
before="$(snapshot "$H" "$T")"
out="$(run_doctor --platform linux 2>&1)"; rc=$?
after="$(snapshot "$H" "$T")"
assert_rc "plaintext known_hosts entries are a warning, exit 0" 0 "$rc"
assert_contains "plaintext entries are counted" "$out" "[warn] 2 plaintext host entries in known_hosts although HashKnownHosts is on"
assert_contains "the fix keeps a .old copy" "$out" "ssh-keygen -H -f $H/.ssh/known_hosts"
assert_not_contains "no host name is printed" "$out" "plain-one"
assert_not_contains "no marked host name is printed" "$out" "plain-two"
if [[ "$before" == "$after" ]]; then ok "the known_hosts check wrote nothing"; else err "the known_hosts check wrote into the home or tmp"; fi
run_doctor --platform linux --fail-on warn >/dev/null 2>&1; rc=$?
assert_rc "--fail-on warn exits 1 on plaintext entries" 1 "$rc"
printf '|1|abc=|def= ssh-ed25519 AAAA\n' > "$H/.ssh/known_hosts"
out="$(run_doctor --platform linux 2>&1)"
assert_contains "an all-hashed known_hosts passes" "$out" "[pass] known_hosts holds no plaintext host"

# A ControlMaster socket three days old. python3 makes the socket and ages
# it; without it, or when the scratch path is too long for a socket name,
# this part is skipped rather than failed.
PY="$(command -v python3 || true)"
sock="$H/.ssh/cm-x"
if [[ -n "$PY" ]] && "$PY" -I -c 'import os, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()
t = time.time() - 3 * 86400
os.utime(sys.argv[1], (t, t))' "$sock" 2>/dev/null; then
  out="$(run_doctor --platform linux 2>&1)"; rc=$?
  assert_rc "a stale socket is a warning, exit 0" 0 "$rc"
  assert_contains "the stale socket is counted" "$out" "[warn] 1 ControlMaster socket(s) older than a day"
  assert_true "the doctor left the socket in place" test -S "$sock"
  rm -f "$sock"
else
  skip "no python3 to make a socket, or the scratch path is too long for one"
fi

if command -v git >/dev/null 2>&1; then
  rm -rf "$H"; mkdir -p "$H"
  out="$(run_doctor --platform linux 2>&1)"; rc=$?
  assert_rc "a missing identity is a warning, exit 0" 0 "$rc"
  assert_contains "a missing identity is reported" "$out" "[warn] no commit identity"
  assert_contains "the fix writes to config.local" "$out" "git config --file $H/.config/git/config.local user.name"

  # The tracked config includes config.local by a relative path; the identity
  # is found only if the doctor asks git with --includes.
  mkdir -p "$H/.config/git"
  cp "$D/config/git/config" "$H/.config/git/config"
  printf '[user]\n\tname = A\n\temail = a@example.invalid\n' > "$H/.config/git/config.local"
  before="$(snapshot "$H" "$T")"
  out="$(run_doctor --platform linux 2>&1)"; rc=$?
  after="$(snapshot "$H" "$T")"
  assert_contains "an identity in config.local is found" "$out" "[pass] a commit identity is set"
  assert_not_contains "no identity warning once config.local has one" "$out" "no commit identity"
  assert_not_contains "the address is never printed" "$out" "a@example.invalid"
  assert_contains "no ~/.gitconfig passes" "$out" "[pass] no $H/.gitconfig overrides"
  if [[ "$before" == "$after" ]]; then ok "the git check wrote nothing"; else err "the git check wrote into the home or tmp"; fi

  : > "$H/.gitconfig"
  out="$(run_doctor --platform linux 2>&1)"; rc=$?
  assert_rc "a ~/.gitconfig is a warning, exit 0" 0 "$rc"
  assert_contains "a ~/.gitconfig is reported" "$out" "[warn] $H/.gitconfig exists: git reads it after"
else
  skip "no git: the identity and ~/.gitconfig checks need it"
fi

# --------------------------------------------------------------------------
head_ "ssh config layouts without running ssh"
# Table-driven: every layout below is read as text, so none of the stubbed
# network tools may run (each leaves the marker), and the run must end with
# exit 0 or 1 (1 is the documented warn-or-fail status; 2 and 3 are usage or
# environment errors) and print a report.
STUBS="$scratch/layoutstubs"; marker="$T/layout-marker"
mkdir -p "$STUBS"
for u in ssh ssh-keygen scp sftp nc; do
  printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$marker" > "$STUBS/$u"
  chmod +x "$STUBS/$u"
done

# Writes the layout named $1 under the scratch home's ~/.ssh.
write_layout() {
  local name="$1" s="$H/.ssh" m="$marker"
  chmod -R u+rwx "$H" 2>/dev/null; rm -rf "$H"
  mkdir -p "$s/config.d"; chmod 700 "$s"
  printf 'plain.example.invalid ssh-ed25519 AAAA\n' > "$s/known_hosts"
  case "$name" in
    match-exec-main)    printf 'Match exec "touch %s"\nHost *\n  HashKnownHosts yes\n' "$m" > "$s/config" ;;
    match-exec-include) printf 'Host *\n  HashKnownHosts yes\nInclude config.d/*\n' > "$s/config"
                        printf 'Match exec "touch %s"\n' "$m" > "$s/config.d/x.conf" ;;
    include-quoted-space) mkdir -p "$s/my conf"
                        printf 'Include "my conf/*"\nHost *\n  HashKnownHosts yes\n' > "$s/config"
                        printf 'Match exec "touch %s"\n' "$m" > "$s/my conf/x.conf" ;;
    include-glob)       printf 'Include config.d/*.conf\nHost *\n  HashKnownHosts yes\n' > "$s/config"
                        printf 'Match exec "touch %s"\n' "$m" > "$s/config.d/a.conf"
                        printf 'Match exec "touch %s"\n' "$m" > "$s/config.d/b.conf" ;;
    match-not-exec)     printf 'Match !exec "touch %s"\nHost *\n  HashKnownHosts yes\n' "$m" > "$s/config" ;;
    match-exec-quoted)  printf 'Match host a exec "touch %s" user u\nHost *\n  HashKnownHosts yes\n' "$m" > "$s/config" ;;
    proxycommand)       printf 'Host *\n  HashKnownHosts yes\n  ProxyCommand touch %s\n' "$m" > "$s/config" ;;
    localcommand)       printf 'Host *\n  HashKnownHosts yes\n  PermitLocalCommand yes\n  LocalCommand touch %s\n' "$m" > "$s/config" ;;
    knownhostscommand)  printf 'Host *\n  HashKnownHosts yes\n  KnownHostsCommand touch %s\n' "$m" > "$s/config" ;;
    include-loop)       printf 'Include a.conf\nHost *\n  HashKnownHosts yes\n' > "$s/config"
                        printf 'Include b.conf\nMatch exec "touch %s"\n' "$m" > "$s/a.conf"
                        printf 'Include a.conf\nMatch exec "touch %s"\n' "$m" > "$s/b.conf" ;;
    include-unreadable) printf 'Host *\n  HashKnownHosts yes\nInclude config.d/*\n' > "$s/config"
                        printf 'Match exec "touch %s"\n' "$m" > "$s/config.d/x.conf"
                        chmod 000 "$s/config.d/x.conf" "$s/config.d" ;;
    empty-config)       : > "$s/config" ;;
    no-config)          : ;;
    no-ssh-dir)         rm -rf "$s" ;;
    *) err "unknown layout $name" ;;
  esac
}

layouts=(match-exec-main match-exec-include include-quoted-space include-glob
  match-not-exec match-exec-quoted proxycommand localcommand knownhostscommand
  include-loop include-unreadable empty-config no-config no-ssh-dir)
for name in "${layouts[@]}"; do
  write_layout "$name"
  rm -f "$marker"
  out="$(guard env "${NOENV[@]}" HOME="$H" TMPDIR="$T" PATH="$STUBS:$PATH" "$DOCTOR" --home "$H" --platform linux 2>&1)"; rc=$?
  if [[ -e "$marker" ]]; then err "layout $name: a network tool ran"; else ok "layout $name: no network tool ran"; fi
  if [[ "$rc" == 0 || "$rc" == 1 ]]; then ok "layout $name: exit status $rc is 0 or the warn status"; else err "layout $name: exit status $rc"; fi
  if [[ -n "$out" ]]; then ok "layout $name: the doctor printed a report"; else err "layout $name: no output"; fi
done

# HashKnownHosts verdict per layout: the awk answers yes, no, include or
# none (no global line); the doctor prints one line for each.
tt_name=(); tt_cfg=(); tt_want=()
tt() { tt_name+=("$1"); tt_cfg+=("$2"); tt_want+=("$3"); }
tt bare-yes        'HashKnownHosts yes\n'                                              yes
tt host-star-yes   'Host *\n  HashKnownHosts yes\n'                                    yes
tt host-star-no    'Host *\n  HashKnownHosts no\n'                                     no
tt host-other-yes  'Host a\n  HashKnownHosts yes\n'                                    none
tt match-all-yes   'Match all\n  HashKnownHosts yes\n'                                yes
tt include-first   'Include config.d/*\nHost *\n  HashKnownHosts yes\n'               include
tt include-after   'Host *\n  HashKnownHosts yes\nInclude config.d/*\n'               yes
tt include-only    'Include config.d/*\n'                                              include
tt empty           ''                                                                  none
tt commented       '# HashKnownHosts yes\n'                                            none
tt equals-sign     'HashKnownHosts=yes\n'                                              yes
tt quoted-upper    'hashknownhosts "yes"\n'                                            yes
tt host-star-extra 'Host * extra\n  HashKnownHosts yes\n'                              none
tt first-wins      'Host *\n  HashKnownHosts yes\n  HashKnownHosts no\n'               yes
tt later-block     'Host a\n  HashKnownHosts no\nHost *\n  HashKnownHosts yes\n'       yes
tt match-exec-blk  'Match exec "true"\n  HashKnownHosts yes\n'                         none
W_WARN="[warn] 1 plaintext host entries in known_hosts although HashKnownHosts is on"
W_INFO="[info] known_hosts: HashKnownHosts not judged"
W_SKIP="[skip] known_hosts: HashKnownHosts is not on in $H/.ssh/config"
for i in "${!tt_name[@]}"; do
  rm -rf "$H"; mkdir -p "$H/.ssh"; chmod 700 "$H/.ssh"
  printf 'plain.example.invalid ssh-ed25519 AAAA\n' > "$H/.ssh/known_hosts"
  printf "${tt_cfg[$i]}" > "$H/.ssh/config"
  out="$(run_doctor --platform linux 2>&1)"
  case "${tt_want[$i]}" in
    yes)     want="$W_WARN" ;;
    include) want="$W_INFO" ;;
    *)       want="$W_SKIP" ;;
  esac
  assert_contains "HashKnownHosts ${tt_name[$i]} -> ${tt_want[$i]}" "$out" "$want"
  n=0
  for w in "$W_WARN" "$W_INFO" "$W_SKIP"; do [[ "$out" == *"$w"* ]] && n=$((n + 1)); done
  assert_rc "HashKnownHosts ${tt_name[$i]} prints one verdict line" 1 "$n"
done
chmod -R u+rwx "$H" 2>/dev/null; rm -rf "$H" "$STUBS"; rm -f "$marker"

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

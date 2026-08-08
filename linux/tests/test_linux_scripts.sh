#!/usr/bin/env bash
# Run from a Linux tester container; repo root is mounted read-only at /repo.
#
# Unlike the macOS suite, which can only parse the scripts it tests, these run
# for real: the container *is* the target OS. That is the whole reason this
# suite is worth having.
#
# The mount is read-only, so anything that writes must be pointed at /tmp. A
# test that quietly wrote into /repo would pass here and fail in CI.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
L="$REPO_ROOT/linux"
EXPECT_PKG_MGR="${EXPECT_PKG_MGR:-apt}"

if [[ ! -d "$L" ]]; then
  echo "expected linux/ at $L" >&2
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

# Discovered rather than listed. A hardcoded array only covers a new script if
# someone remembers to add it, which is how the macOS suite silently stopped
# covering two of its own scripts. bash_aliases.sh is excluded deliberately: it
# is sourced, not run, so the --help and unknown-flag contracts do not apply to
# it. Built without mapfile to stay Bash 3.2-clean (see CONTRIBUTING.md).
#
# Depth 2 so subdirectories such as systemd/ are covered too; tests/ is the one
# subdirectory left out, because this file lives in it. A script that needs a
# running systemd fails its own preflight in these containers, which is exactly
# why --help and the unknown-flag contract have to hold *before* preflight.
scripts=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "${f##*/}" in bash_aliases.sh) continue ;; esac
  scripts+=("$f")
done < <(find "$L" -maxdepth 2 -name '*.sh' -type f ! -path "$L/tests/*" | sort)

if (( ${#scripts[@]} == 0 )); then
  echo "discovered no scripts under $L — discovery is broken" >&2
  exit 1
fi
ok "discovered ${#scripts[@]} scripts under linux/"

echo "=== distro: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '\"') (expecting $EXPECT_PKG_MGR) ==="

# --- syntax ---
for f in "${scripts[@]}" "$L/bash_aliases.sh"; do
  if bash -n "$f"; then ok "bash -n ${f#"$REPO_ROOT/"}"; else err "bash -n ${f#"$REPO_ROOT/"}"; fi
done

# --- help contract, before any preflight ---
for f in "${scripts[@]}"; do
  if "$f" --help >/dev/null 2>&1; then ok "${f##*/} --help"; else err "${f##*/} --help"; fi
done

# --- unknown flag -> 3 ---
for f in "${scripts[@]}"; do
  set +e
  "$f" --definitely-not-a-valid-flag-12345 >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "${f##*/} unknown flag -> 3" "3" "$rc"
done

# --- distro detection picks the right package manager ---
out="$("$L/stay_fresh.sh" --dry-run 2>&1)"
assert_contains "stay_fresh detects $EXPECT_PKG_MGR" "$out" "package manager: $EXPECT_PKG_MGR"

# --- an unsupported distro exits 2 ---
# The whole reason detect_pkg_mgr reads $OS_RELEASE instead of /etc/os-release
# directly: without the seam this path is untestable, since a container cannot
# pretend to be Gentoo.
fake="/tmp/fake-os-release"
printf 'ID=gentoo\nID_LIKE=gentoo\n' > "$fake"
set +e
OS_RELEASE="$fake" "$L/stay_fresh.sh" --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "unsupported distro -> 2" "2" "$rc"

# --- dry run changes nothing ---
# Counting installed packages before and after is the assertion that actually
# matters: the dry-run promise is the core of this repository.
count_packages() {
  case "$EXPECT_PKG_MGR" in
    apt)    dpkg-query -f '.\n' -W 2>/dev/null | wc -l ;;
    dnf)    rpm -qa 2>/dev/null | wc -l ;;
    pacman) pacman -Qq 2>/dev/null | wc -l ;;
  esac
}
before="$(count_packages)"
"$L/stay_fresh.sh" --dry-run >/dev/null 2>&1
"$L/install_devtools.sh" --dry-run >/dev/null 2>&1
after="$(count_packages)"
assert_eq "dry runs installed nothing" "$before" "$after"

# --- dry run says so, and says nothing was written ---
out="$("$L/install_devtools.sh" --dry-run 2>&1)"
assert_contains "install_devtools dry-run reports no changes" "$out" "dry-run complete; no changes written"

# --- installing without --yes refuses rather than proceeding ---
set +e
"$L/install_devtools.sh" >/dev/null 2>&1
rc=$?
set -e
assert_eq "install_devtools without --yes -> 3" "3" "$rc"

# --- packages.sh round-trips through a real package database ---
dump="/tmp/packages.$EXPECT_PKG_MGR.txt"
rm -f "$dump"
if "$L/packages.sh" dump --file "$dump" >/dev/null 2>&1; then
  ok "packages.sh dump"
else
  err "packages.sh dump"
fi

if [[ -s "$dump" ]] && grep -qvE '^\s*(#|$)' "$dump"; then
  ok "dump wrote at least one package"
else
  err "dump produced no packages"
fi

# dump twice; the file must be identical or diffs are noise
cp "$dump" /tmp/first.txt
"$L/packages.sh" dump --file "$dump" --force >/dev/null 2>&1
if diff -q <(grep -vE '^\s*#' /tmp/first.txt) <(grep -vE '^\s*#' "$dump") >/dev/null; then
  ok "dump is stable across runs"
else
  err "dump is not stable across runs"
fi

# everything just dumped is by definition installed
set +e
"$L/packages.sh" check --file "$dump" >/dev/null 2>&1
rc=$?
set -e
assert_eq "check passes against a fresh dump" "0" "$rc"

# a package that cannot exist must make check fail with 1, not crash
printf 'definitely-not-a-real-package-12345\n' >> "$dump"
set +e
"$L/packages.sh" check --file "$dump" >/dev/null 2>&1
rc=$?
set -e
assert_eq "check reports a missing package as 1" "1" "$rc"

set +e
out="$("$L/packages.sh" install --file "$dump" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "install --dry-run exits 0" "0" "$rc"
assert_contains "install --dry-run names the missing package" "$out" "definitely-not-a-real-package-12345"

# --- aliases are sourceable, and guarded ---
if bash -c ". $L/bash_aliases.sh" >/dev/null 2>&1; then
  ok "bash_aliases.sh sources cleanly"
else
  err "bash_aliases.sh failed to source"
fi

# An alias to a binary that is not installed is worse than no alias, so the
# guards must actually guard.
out="$(bash -c ". $L/bash_aliases.sh; alias" 2>/dev/null)"
if command -v eza >/dev/null 2>&1; then
  ok "eza present; skipping the guard assertion"
else
  if grep -q "alias ls='eza" <<<"$out"; then
    err "eza is absent but the eza alias was still defined"
  else
    ok "eza absent, so no eza alias was defined"
  fi
fi

# Running it instead of sourcing it should say so rather than doing nothing.
set +e
bash "$L/bash_aliases.sh" >/dev/null 2>&1
rc=$?
set -e
assert_eq "bash_aliases.sh executed directly -> 3" "3" "$rc"

# --- stay_fresh degrades rather than failing when a tool is absent ---
# journald is not present in these containers. That must be a note, not a
# failure: the warn vs failure split is the documented contract.
set +e
out="$("$L/stay_fresh.sh" --yes --no-sudo --skip-packages --skip-containers 2>&1)"
rc=$?
set -e
assert_eq "stay_fresh survives missing optional tools" "0" "$rc"
assert_contains "stay_fresh reports the run finished" "$out" "done"

# --- the systemd timer builds its units without a running systemd ---
# --print-only is the seam that makes this testable at all: a container has no
# user manager, so install can never get past preflight here. Where
# systemd-analyze exists (fedora, arch) the script verifies the units before
# printing them, so a zero exit below is a real validation, not just a render.
TIMER="$L/systemd/stay_fresh_timer.sh"
set +e
out="$("$TIMER" install --print-only 2>&1)"; rc=$?
set -e
assert_eq "timer --print-only exits 0" "0" "$rc"
assert_contains "timer defaults to Monday 10:30" "$out" "OnCalendar=Mon *-*-* 10:30:00"
assert_contains "timer runs stay_fresh.sh" "$out" "$L/stay_fresh.sh\" --yes --no-sudo"
assert_contains "timer installs a [Timer] section" "$out" "[Timer]"

out="$("$TIMER" install --print-only --weekday daily --hour 3 --minute 5 --dry-run 2>&1)"
assert_contains "timer honours daily and the clock" "$out" "OnCalendar=*-*-* 03:05:00"
assert_contains "timer passes --dry-run through" "$out" "--yes --no-sudo --dry-run"

# --print-only must write nothing, the same promise --dry-run makes elsewhere.
scratch_home="$(mktemp -d)"
HOME="$scratch_home" XDG_CONFIG_HOME="$scratch_home/.config" \
  "$TIMER" install --print-only >/dev/null 2>&1
if [[ -e "$scratch_home/.config/systemd" ]]; then
  err "timer --print-only wrote into HOME"
else
  ok "timer --print-only wrote nothing"
fi
rm -rf "$scratch_home"

for bad in "--weekday 9" "--hour 24" "--minute 60"; do
  set +e
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$TIMER" install $bad >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "timer rejects $bad -> 3" "3" "$rc"
done

# No user manager in a container, so a real install must report the wrong
# environment rather than half-writing units.
set +e
"$TIMER" install >/dev/null 2>&1
rc=$?
set -e
assert_eq "timer install without systemd -> 2" "2" "$rc"

# --- hardening_audit is read-only and grades correctly ---
# The whole value of this script is that it never changes the machine, so that
# is asserted directly rather than assumed: snapshot the files it inspects and
# require them to be untouched.
before="$( { stat -c '%a %Y' /etc/shadow /etc/passwd 2>/dev/null; ls /etc/ssh 2>/dev/null; } || true )"
set +e
out="$("$L/hardening_audit.sh" 2>&1)"
rc=$?
set -e
after="$( { stat -c '%a %Y' /etc/shadow /etc/passwd 2>/dev/null; ls /etc/ssh 2>/dev/null; } || true )"
assert_eq "hardening_audit changed nothing it inspected" "$before" "$after"
assert_contains "hardening_audit prints a summary" "$out" "== summary =="

# A container has no firewall and no sshd, so a clean exit here proves absent
# tooling is reported rather than treated as a crash.
if [[ "$rc" == "0" || "$rc" == "1" ]]; then
  ok "hardening_audit exits 0 or 1, not an error ($rc)"
else
  err "hardening_audit exited $rc; expected 0 or 1"
fi

# --fail-on warn must be stricter than the default, never looser.
set +e
"$L/hardening_audit.sh" >/dev/null 2>&1; rc_default=$?
"$L/hardening_audit.sh" --fail-on warn >/dev/null 2>&1; rc_strict=$?
set -e
if (( rc_strict >= rc_default )); then
  ok "--fail-on warn is at least as strict as the default ($rc_default -> $rc_strict)"
else
  err "--fail-on warn ($rc_strict) was looser than the default ($rc_default)"
fi

set +e
"$L/hardening_audit.sh" --only nosuchgroup >/dev/null 2>&1; rc=$?
set -e
assert_eq "hardening_audit rejects an unknown group -> 3" "3" "$rc"

# --- system_doctor reports rather than grades ------------------------------
# A container has no systemd, no sshd, no firewall and no container engine, so
# this is the environment where a health report is most likely to trip over
# something absent. Exiting 0 here is the assertion: every probe has to degrade
# to a note.
scratch_home="$(mktemp -d)"
set +e
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$L/system_doctor.sh" 2>&1)"; rc=$?
set -e
assert_eq "system_doctor exits 0 with almost nothing installed" "0" "$rc"
assert_contains "system_doctor prints a summary" "$out" "== summary =="
assert_contains "system_doctor names the package manager" "$out" "package manager: $EXPECT_PKG_MGR"

# Read-only means it writes nothing at all, not even a log — the sibling
# maintenance scripts do write one, so this is worth asserting rather than
# assuming.
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "system_doctor wrote nothing"
else
  err "system_doctor wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home"

# --quiet must drop the healthy lines and keep the rest; a --quiet that still
# printed everything would be discovered by nobody.
out="$("$L/system_doctor.sh" --quiet 2>&1)"
if grep -q '\[ ok \]' <<<"$out"; then
  err "system_doctor --quiet still printed [ ok ] lines"
else
  ok "system_doctor --quiet drops the healthy lines"
fi
assert_contains "system_doctor --quiet still summarises" "$out" "== summary =="

for bad in "--min-free 101" "--min-free notanumber"; do
  set +e
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$L/system_doctor.sh" $bad >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "system_doctor rejects $bad -> 3" "3" "$rc"
done

echo
if (( failures > 0 )); then
  echo "$failures linux script check(s) failed" >&2
  exit 1
fi
echo "=== all linux script checks passed ($EXPECT_PKG_MGR) ==="
exit 0

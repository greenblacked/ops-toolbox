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

scripts=("$L/install_devtools.sh" "$L/stay_fresh.sh" "$L/packages.sh")

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

echo
if (( failures > 0 )); then
  echo "$failures linux script check(s) failed" >&2
  exit 1
fi
echo "=== all linux script checks passed ($EXPECT_PKG_MGR) ==="
exit 0

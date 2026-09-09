#!/usr/bin/env bash
# changelog.d/changelog.sh, run against a scratch CHANGELOG.md and a scratch
# set of fragments, so the real one is never touched.
#
# What is asserted: the CLI contract, that check accepts a well-formed
# fragment and rejects each shape that would not paste, that preview puts the
# fragments ahead of what [Unreleased] already holds in Keep a Changelog
# order, that a dry-run release writes nothing, and that a real release moves
# everything under a dated heading, empties [Unreleased], deletes the
# fragments and leaves the history below untouched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
SCRIPT="$REPO_ROOT/changelog.d/changelog.sh"

failures=0
ok()  { printf '[ ok ] %s\n' "$*"; }
err() { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }

# expect MESSAGE COMMAND... — pass when COMMAND succeeds.
expect() {
  local msg="$1"; shift
  if "$@"; then ok "$msg"; else err "$msg"; fi
}
# Small predicates so the assertions below read as one line each.
has()     { [[ "$1" == *"$2"* ]]; }
lacks()   { [[ "$1" != *"$2"* ]]; }
starts()  { [[ "$1" == "$2"* ]]; }
same()    { [[ "$1" == "$2" ]]; }
rc_is()   { [[ "$rc" -eq "$1" ]]; }

if [[ ! -x "$SCRIPT" ]]; then
  err "$SCRIPT is missing or not executable"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fresh scratch root: a small CHANGELOG.md with two sections already under
# [Unreleased] and one dated section below, plus three fragments.
fresh_root() {
  local r="$WORK/root-$RANDOM$RANDOM"
  mkdir -p "$r/changelog.d/added" "$r/changelog.d/fixed" "$r/changelog.d/changed"
  cat > "$r/CHANGELOG.md" <<'EOF'
# Changelog

Intro paragraph that must survive.

## [Unreleased]

### Added

- Existing added item.

### Fixed

- Existing fixed item
  with a continuation line.

## 2026-01-01

### Added

- Old item that belongs to history.
EOF
  printf -- '- Fragment A, added.\n' > "$r/changelog.d/added/aaa.md"
  printf -- '- Fragment Z, fixed.\n' > "$r/changelog.d/fixed/zzz.md"
  printf -- '- Fragment C one.\n- Fragment C two,\n  continued.\n' > "$r/changelog.d/changed/ccc.md"
  printf '%s\n' "$r"
}

out=""
rc=0
run() {
  # run ROOT args... ; sets out and rc
  local root="$1"; shift
  out="$(CHANGELOG_ROOT="$root" "$SCRIPT" "$@" 2>&1)"
  rc=$?
}

snapshot() { find "$1" -mindepth 1 -printf '%p %T@\n' | sort; }

# --- CLI contract ----------------------------------------------------------
root="$(fresh_root)"
run "$root" --help
expect "--help exits 0 and describes release" rc_is 0
expect "--help names the release command" has "$out" "release VERSION"
run "$root" --bogus;                     expect "unknown flag exits 3 (got $rc)" rc_is 3
run "$root";                             expect "no command exits 3 (got $rc)" rc_is 3
run "$root" frobnicate;                  expect "unknown command exits 3 (got $rc)" rc_is 3
run "$root" release;                     expect "release without VERSION exits 3 (got $rc)" rc_is 3
run "$root" release 1.0 extra;           expect "extra positional exits 3 (got $rc)" rc_is 3
run "$root" preview --dry-run;           expect "--dry-run outside release exits 3 (got $rc)" rc_is 3
run "$root" check --date 2026-01-01;     expect "--date outside release exits 3 (got $rc)" rc_is 3
run "$root" release --date;              expect "--date without a value exits 3 (got $rc)" rc_is 3
run "$root" release 1.0 --date 2026-1-1; expect "malformed --date exits 3 (got $rc)" rc_is 3

# --- check -----------------------------------------------------------------
run "$root" check
expect "check accepts three well-formed fragments (exit $rc)" rc_is 0
expect "check counts the three fragments" has "$out" "3 fragment(s) would paste cleanly"

bad_case() {
  # bad_case NAME SETUP-COMMAND ; check must exit 1
  local name="$1" r
  r="$(fresh_root)"
  ( cd "$r" && eval "$2" )
  run "$r" check
  expect "check rejects $name (exit $rc)" rc_is 1
}
bad_case "a fragment starting with a heading"    "printf '### Added\n- x\n' > changelog.d/added/bad.md"
bad_case "a fragment with prose before its item" "printf 'Some prose.\n- x\n' > changelog.d/added/bad.md"
bad_case "a continuation not indented two spaces" "printf -- '- x\ncontinued badly\n' > changelog.d/added/bad.md"
bad_case "a tab character"                       "printf -- '- x\n\tcontinued\n' > changelog.d/added/bad.md"
bad_case "trailing whitespace"                   "printf -- '- x \n' > changelog.d/added/bad.md"
bad_case "no final newline"                      "printf -- '- x' > changelog.d/added/bad.md"
bad_case "an empty fragment"                     ": > changelog.d/added/bad.md"
bad_case "a non-.md file"                        "printf -- '- x\n' > changelog.d/added/bad.txt"
bad_case "a fragment outside a type directory"   "printf -- '- x\n' > changelog.d/stray.md"
bad_case "a directory that is not a type"        "mkdir changelog.d/misc && printf -- '- x\n' > changelog.d/misc/x.md"

# --- preview ---------------------------------------------------------------
root="$(fresh_root)"
run "$root" preview
expect "preview exits 0 (got $rc)" rc_is 0
expect "preview starts with the section heading" starts "$out" "## [Unreleased]"
order="$(printf '%s\n' "$out" | grep '^### ' | tr '\n' ' ')"
expect "preview orders sections Added, Changed, Fixed (got: $order)" same "$order" "### Added ### Changed ### Fixed "
a="$(printf '%s\n' "$out" | grep -n 'Fragment A' | cut -d: -f1)"
e="$(printf '%s\n' "$out" | grep -n 'Existing added item' | cut -d: -f1)"
expect "preview puts the fragment (line ${a:-none}) ahead of the existing item (line ${e:-none})" \
  test "${a:-0}" -gt 0 -a "${e:-0}" -gt "${a:-0}"
expect "preview keeps a continuation line" has "$out" "  with a continuation line."
expect "preview keeps a fragment's continuation line" has "$out" "  continued."
expect "preview leaves history out" lacks "$out" "Old item"
n="$(printf '%s\n' "$out" | grep -c '^- ')"
expect "preview lists all six items (got $n)" same "$n" 6

# --- release, dry run ------------------------------------------------------
root="$(fresh_root)"
before="$(snapshot "$root")"
run "$root" release 1.2.3 --dry-run --date 2026-02-03
after="$(snapshot "$root")"
expect "release --dry-run exits 0 (got $rc)" rc_is 0
expect "release --dry-run writes nothing" same "$before" "$after"
expect "dry run names the heading and the counts" \
  has "$out" 'dry-run: would write CHANGELOG.md: "## [1.2.3] - 2026-02-03" with 6 entries (4 from fragments)'
expect "dry run names a fragment it would remove" has "$out" "dry-run: would remove changelog.d/added/aaa.md"
expect "dry run ends with the closing line" has "$out" "dry-run complete; no changes written"

# --- release, for real -----------------------------------------------------
run "$root" release 1.2.3 --date=2026-02-03
expect "release exits 0 (got $rc): $out" rc_is 0
f="$root/CHANGELOG.md"
expect "release writes the dated version heading (--date= form)" grep -q '^## \[1.2.3\] - 2026-02-03$' "$f"
expect "release keeps the header" grep -q 'Intro paragraph that must survive' "$f"
# [Unreleased] is empty: its heading, a blank line, then the version heading.
expect "release leaves [Unreleased] empty" \
  same "$(awk '/^## \[Unreleased\]/{getline a; getline b; print a "|" b}' "$f")" "|## [1.2.3] - 2026-02-03"
n="$(awk '/^## \[1.2.3\]/{s=1;next} s&&/^## /{exit} s&&/^- /{c++} END{print c+0}' "$f")"
expect "release moves all six items under the version (got $n)" same "$n" 6
expect "release keeps the history heading" grep -q '^## 2026-01-01$' "$f"
expect "release keeps the history item" grep -q 'Old item that belongs to history' "$f"
expect "a blank line precedes the first history heading" \
  same "$(grep -n -B1 '^## 2026-01-01$' "$f" | head -n 1 | cut -d- -f2-)" ""
left="$(find "$root/changelog.d" -mindepth 2 -type f | wc -l | tr -d ' ')"
expect "release removes the fragment files (left: $left)" same "$left" 0
expect "CHANGELOG.md still ends with a newline" same "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" '\n'

# --- release refusals ------------------------------------------------------
before="$(snapshot "$root")"
run "$root" release 1.2.3
after="$(snapshot "$root")"
expect "a version already in the file is refused (exit $rc)" rc_is 1
expect "a refused re-release touches nothing" same "$before" "$after"
run "$root" release 1.2.4 --dry-run
expect "nothing to release exits 4 (got $rc)" rc_is 4
run "$root" preview
expect "preview of an empty section exits 0 (got $rc)" rc_is 0
expect "preview of an empty section is just its heading" same "$out" "## [Unreleased]"

root="$(fresh_root)"
printf -- '- x' > "$root/changelog.d/added/bad.md"
before="$(snapshot "$root")"
run "$root" release 2.0.0
after="$(snapshot "$root")"
expect "release refuses to run over a bad fragment (exit $rc)" rc_is 1
expect "a refused release touches nothing" same "$before" "$after"

root="$(fresh_root)"
sed -i 's/^## \[Unreleased\]$/## Unreleased/' "$root/CHANGELOG.md"
run "$root" preview
expect "a CHANGELOG.md without the [Unreleased] heading is refused (exit $rc)" rc_is 1

root="$(fresh_root)"
sed -i 's/^### Fixed$/### Surprises/' "$root/CHANGELOG.md"
run "$root" preview
expect "an unknown section under [Unreleased] is refused (exit $rc)" rc_is 1

printf '\n'
if (( failures > 0 )); then
  printf '=== %s changelog check(s) failed ===\n' "$failures" >&2
  exit 1
fi
printf '=== all changelog checks passed ===\n'

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
# BSD sed's -i takes a mandatory backup suffix, GNU sed's must not be a
# separate argument. '' works for neither, so branch once on which this is.
if sed --version >/dev/null 2>&1; then
  sed_i() { sed -i "$@"; }
else
  sed_i() { local e="$1"; shift; sed -i '' "$e" "$@"; }
fi

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

# macOS find has no -printf, and this suite is the one that runs natively
# there. Without a fallback snapshot() printed nothing for both the before and
# the after call, so every "writes nothing" assertion compared "" to "" and
# passed even when a dry run had written files. dotfiles/tests/test_dotfiles.sh
# guards the same call the same way.
snapshot() { find "$1" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort; }
if ! find "$WORK" -maxdepth 0 -printf '' >/dev/null 2>&1; then
  snapshot() { find "$1" -mindepth 1 -exec ls -ld {} + 2>/dev/null | sort; }
fi

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

# --- a large [Unreleased] must not break preview ---------------------------
# unreleased_preamble() piped part_unreleased into an awk that exited at the
# first "### ". Once the section outgrew one pipe buffer (64K on Linux; the
# real CHANGELOG.md passed that long ago) the writer died of SIGPIPE, pipefail
# promoted it, and set -e aborted preview with no message after two lines of
# output. The fixture has to be bigger than a pipe buffer for this to bite.
big_root="$(fresh_root)"
{
  printf '# Changelog\n\nIntro paragraph that must survive.\n\n## [Unreleased]\n\n### Added\n\n'
  i=0
  while [ "$i" -lt 4000 ]; do
    printf -- '- Item %d, long enough to push this section past a pipe buffer.\n' "$i"
    i=$((i + 1))
  done
  printf '\n## 2026-01-01\n\n### Added\n\n- Old item that belongs to history.\n'
} > "$big_root/CHANGELOG.md"
expect "the fixture section really is bigger than a pipe buffer" \
  test "$(wc -c < "$big_root/CHANGELOG.md")" -gt 65536
run "$big_root" preview
expect "preview of a large [Unreleased] exits 0 (got $rc)" rc_is 0
expect "preview keeps the first item" has "$out" "- Item 0,"
expect "preview keeps the last item"  has "$out" "- Item 3999,"
expect "preview keeps the fragments too" has "$out" "Fragment A, added."
run "$big_root" release 9.9.9 --dry-run
expect "a dry-run release of a large section exits 0 (got $rc)" rc_is 0

# --- what counts as a fragment ---------------------------------------------
# check used to enumerate dot-files while the paste globbed only *.md, so the
# two disagreed in both directions: a .md dot-file was counted and then
# silently dropped by release, and the OS/editor junk that actually turns up
# in a working tree failed the whole static suite.
dot_root="$(fresh_root)"
printf -- '- Hidden, and never pasted.\n' > "$dot_root/changelog.d/added/.hidden.md"
: > "$dot_root/changelog.d/.DS_Store"
: > "$dot_root/changelog.d/added/.aaa.md.swp"
run "$dot_root" check
expect "a .DS_Store and a vim swapfile do not fail check (exit $rc)" rc_is 0
expect "check counts only the three real fragments" has "$out" "3 fragment(s) would paste cleanly"
run "$dot_root" release 1.2.3 --date 2026-02-02
expect "release over dot-files exits 0 (got $rc)" rc_is 0
expect "the dot-file's text was never pasted" \
  lacks "$(cat "$dot_root/CHANGELOG.md")" "Hidden, and never pasted."
expect "the .DS_Store is left alone" test -e "$dot_root/changelog.d/.DS_Store"

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

# --- claims against the tree -----------------------------------------------
# Everything above asks whether a fragment would paste. Two pull requests
# shipped fragments that would have pasted beautifully and described work that
# was never committed: #36's claimed a `--legacy-run` opt-in on
# `v1_stay_fresh.sh`, #37's claimed `install_apps.sh` had "grown
# `--list-casks` and `--list-formulae`". Both branches held nothing but the
# fragments, and both passed this suite as it stood.
#
# So each assertion below comes in a pair: the lie is rejected and the true
# version of the same sentence is accepted. The second half is the one that
# decides whether this check is shippable — a check that flags correct writing
# gets switched off, and then the lie ships anyway.
claim_root() {
  # A scratch root with a small tree in it. Claims resolve against the root
  # the fragments ship in, so the fixture needs scripts as well as fragments.
  local r
  r="$(fresh_root)"
  rm -f "$r/changelog.d/added/aaa.md" "$r/changelog.d/fixed/zzz.md" \
    "$r/changelog.d/changed/ccc.md"
  mkdir -p "$r/tools" "$r/other"
  cat > "$r/tools/real_tool.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  --real-flag) shift ;;
esac
EOS
  # A second script, holding a flag the first does not: a fragment that names
  # real_tool.sh and claims --other-flag is exactly the shape of #37, where the
  # flag existed in the repository's vocabulary but not in the named script.
  cat > "$r/other/other_tool.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  --other-flag|--list-casks) shift ;;
esac
EOS
  printf '%s\n' "$r"
}
claim_out=""
claim_run() {
  # claim_run FRAGMENT-TEXT ; sets out and rc for one fragment in a fresh root
  local r
  r="$(claim_root)"
  printf '%s' "$1" > "$r/changelog.d/added/claim.md"
  run "$r" check
  claim_out="$out"
}
claim_rejects() {
  # claim_rejects NAME TEXT [MESSAGE] — check must exit 1, and say why
  local name="$1" text="$2" msg="${3:-}"
  claim_run "$text"
  expect "check rejects $name (exit $rc)" rc_is 1
  [[ -z "$msg" ]] || expect "  and names it: $msg" has "$claim_out" "$msg"
}
claim_accepts() {
  local name="$1" text="$2"
  claim_run "$text"
  expect "check accepts $name (exit $rc): $(printf '%s' "$claim_out" | grep '^\[err' | head -n 1)" rc_is 0
}

# 1. A file named in backticks is a claim about the tree.
claim_rejects "a fragment naming a script that is not in the tree" \
  '- `missing_tool.sh` learned to do the thing.
' \
  'claim.md:1 names `missing_tool.sh`, which is not a file in this tree'
claim_accepts "the same sentence about a script that is there" \
  '- `real_tool.sh` learned to do the thing.
'
claim_accepts "a script named by the path it sits at" \
  '- `tools/real_tool.sh` learned to do the thing.
'
claim_rejects "a path under a directory that does not exist" \
  '- `nowhere/real_tool.sh` learned to do the thing.
' \
  'names `nowhere/real_tool.sh`'

# 2. A long flag standing alone in its span is a claim too, resolved against
#    the scripts its own item names.
claim_rejects "a flag the script it names does not accept" \
  '- `real_tool.sh` grew `--other-flag`, which is the shape of the thing.
' \
  'says `--other-flag`, which tools/real_tool.sh does not accept'
claim_accepts "a flag the script it names does accept" \
  '- `real_tool.sh` grew `--real-flag`, which is the shape of the thing.
'
claim_rejects "a flag no script in the tree accepts" \
  '- The runner grew `--nowhere-flag`, and nothing else changed.
' \
  'says `--nowhere-flag`, which no script in this tree accepts'
claim_accepts "a flag some script accepts, in an item that names no script" \
  '- The runner grew `--other-flag`, and nothing else changed.
'
# The prefix case: a claim on `--list` is not satisfied by a `--list-casks`
# somewhere in the tree, because the fragment did not say `--list-casks`.
claim_rejects "a flag that is only ever a prefix of another" \
  '- The runner grew `--list`, and nothing else changed.
' \
  'says `--list`, which no script in this tree accepts'

# 3. The scoping that keeps this from crying wolf. Every one of these is a
#    form the fragments in changelog.d/ use today.
claim_accepts "another tool's flag, written in the span with its tool" \
  '- The cleanup empties `brew --cache` and calls `apt-get --yes` with it,
  which no script here has to accept.
'
claim_accepts "a quoted command line that wraps onto a continuation line" \
  '- The bare run went straight to `winget upgrade --all
  --include-unknown --accept-package-agreements --disable-interactivity`.
'
claim_accepts "an invocation form, which is prose about how to run a script" \
  '- Every usage line in the repository is written `./x.sh`, and the check now
  runs both ways.
'
claim_accepts "runtime state named in backticks" \
  '- The run records what it freed in `last-run.json` and `history.tsv`.
'
claim_accepts "a single-dash flag, which is where the other tools live" \
  '- The snapshot stopped using `find -printf` and `sed -i`.
'

# 4. Removal wording, which a fragment about a deletion needs — scoped to the
#    sentence it sits in. #36's entry opened "`v1_stay_fresh.sh` no longer runs
#    its fixed cleanup" and made its false claim two sentences later; exempting
#    the whole entry would have exempted the lie with it.
claim_accepts "a file the fragment says was removed" \
  '- `missing_tool.sh` was removed; the work it did now happens in
  `real_tool.sh`.
'
claim_accepts "a file the fragment says no longer ships" \
  '- `missing_tool.sh` no longer ships with the package.
'
claim_rejects "a false claim in a later sentence of a removal entry" \
  '- `real_tool.sh` no longer runs its fixed cleanup on a bare invocation.
  `--nowhere-flag` is the opt-in that keeps the old sequence.
' \
  'says `--nowhere-flag`, which no script in this tree accepts'

# 5. The counts are reported, so a reader can see the check had subjects.
claim_run '- `real_tool.sh` grew `--real-flag`, the same shape as
  `other/other_tool.sh --other-flag`.
'
expect "check reports what it resolved" has "$claim_out" "file and 1 flag claim(s) hold against this tree"

# 6. The floor. The usual "it inspected zero subjects" guard cannot be used
#    here — changelog.d/ is empty right after a release and a fragment may have
#    no backticks at all — so the guard is a canary through the same extractor.
#    Break the extractor and the canary must say so, whatever the fragments
#    hold. This is the assertion that fails when somebody's edit quietly turns
#    the claim check into a no-op.
broken="$WORK/broken-changelog.sh"
cp "$SCRIPT" "$broken"
sed_i 's/^  add("FILE", first, sid)$/  return/' "$broken"
expect "the fixture really did break the extractor" \
  test "$(grep -c 'add("FILE", first, sid)' "$broken")" -eq 0
root="$(claim_root)"
printf -- '- `real_tool.sh` grew `--real-flag`.\n' > "$root/changelog.d/added/claim.md"
out="$(CHANGELOG_ROOT="$root" "$broken" check 2>&1)"
rc=$?
expect "a claim check that stopped extracting fails (exit $rc)" rc_is 1
expect "and says it has stopped checking" has "$out" "this check has stopped checking"

# 7. A release must not paste a fragment whose claims do not hold, and must
#    leave the tree alone when it refuses.
root="$(claim_root)"
printf -- '- `missing_tool.sh` learned to do the thing.\n' > "$root/changelog.d/added/claim.md"
before="$(snapshot "$root")"
run "$root" release 3.0.0
after="$(snapshot "$root")"
expect "release refuses a fragment whose claim does not hold (exit $rc)" rc_is 1
expect "a release refused over a claim touches nothing" same "$before" "$after"

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
# BSD sed's -i requires a backup-suffix argument, so a bare `sed -i` consumes
# the script as the suffix and fails; these were the only two in the repo.
sed_i 's/^## \[Unreleased\]$/## Unreleased/' "$root/CHANGELOG.md"
run "$root" preview
expect "a CHANGELOG.md without the [Unreleased] heading is refused (exit $rc)" rc_is 1

root="$(fresh_root)"
sed_i 's/^### Fixed$/### Surprises/' "$root/CHANGELOG.md"
run "$root" preview
expect "an unknown section under [Unreleased] is refused (exit $rc)" rc_is 1

printf '\n'
if (( failures > 0 )); then
  printf '=== %s changelog check(s) failed ===\n' "$failures" >&2
  exit 1
fi
printf '=== all changelog checks passed ===\n'

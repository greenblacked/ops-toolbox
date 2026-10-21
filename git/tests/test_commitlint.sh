#!/usr/bin/env bash
# Verify git_commitlint.sh reports every problem of every commit in a range,
# skips merges, and validates its range and options.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
COMMITLINT="$REPO_ROOT/git/git_commitlint.sh"
scratch="$(mktemp -d /tmp/commitlint-tests.XXXXXX)"
if [[ -z "$scratch" || ! -d "$scratch" ]]; then
  printf 'cannot create test scratch directory\n' >&2
  exit 1
fi
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
checks=0
failures=0
section_checks=0
section_name=""
ok() { checks=$((checks + 1)); section_checks=$((section_checks + 1)); printf '[ ok ] %s\n' "$*"; }
err() { checks=$((checks + 1)); section_checks=$((section_checks + 1)); failures=$((failures + 1)); printf '[fail] %s\n' "$*" >&2; }
# A section that asserted nothing is a failure: its fixture never reached an
# assertion, which reads as a pass without this.
section() {
  end_section
  section_name="$1"
  section_checks=0
}
end_section() {
  [[ -n "$section_name" ]] || return 0
  if (( section_checks == 0 )); then
    err "section '$section_name' made no assertion"
  fi
  section_name=""
}
assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else err "$3: expected '$2', got '$1'"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else err "$3: missing '$2' in: $1"; fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then ok "$3"; else err "$3: unexpected '$2' in: $1"; fi
}
run_in() {
  local dir="$1"
  shift
  (cd "$dir" && "$COMMITLINT" "$@")
}

# --- fixture ---------------------------------------------------------------
repo="$scratch/repo"
long_subject="feat: $(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
  21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 \
  51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80)"
git init -q -b main "$repo" &&
  git -C "$repo" config user.name Test &&
  git -C "$repo" config user.email test@example.com &&
  git -C "$repo" commit -q --allow-empty -m base &&
  git -C "$repo" switch -q -c feature &&
  git -C "$repo" commit -q --allow-empty -m 'feat(git): fine one' &&
  git -C "$repo" commit -q --allow-empty -m 'fix: fine two' || { err 'create fixture'; exit 1; }
base_sha="$(git -C "$repo" rev-parse main)"
two_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" commit -q --allow-empty -m 'bad subject without type' &&
  git -C "$repo" commit -q --allow-empty -m "$long_subject" &&
  printf 'docs: ok\n\nbody\n' | git -C "$repo" commit -q --allow-empty -F - &&
  printf 'docs: ok\nbody\n' | git -C "$repo" commit -q --allow-empty -F - &&
  git -C "$repo" commit -q --allow-empty -m 'fixup! feat(git): fine one' &&
  printf 'feat: signed\n\nSigned-off-by: A <a@example.com>\n' | git -C "$repo" commit -q --allow-empty -F - &&
  git -C "$repo" switch -q -c side &&
  git -C "$repo" commit -q --allow-empty -m 'test: on a side branch' &&
  git -C "$repo" switch -q feature &&
  git -C "$repo" merge -q --no-ff -m 'Merge branch side' side || { err 'create commit fixture'; exit 1; }

section "every problem on the right commit"
out="$(run_in "$repo" --base main --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 1 'problems in the range -> 1'
assert_contains "$out" $'\tnot-conventional\tbad subject without type' 'a subject with no type is not conventional'
assert_contains "$out" $'\ttoo-long\t'"$long_subject" 'an 86-character subject is too long'
assert_contains "$out" $'\tno-blank-line\tdocs: ok body' 'a body on line 2 is flagged'
assert_contains "$out" $'\tfixup\tfixup! feat(git): fine one' 'an unsquashed fixup is flagged'
assert_not_contains "$out" $'\tnot-conventional\tfixup!' 'a fixup is not also called unconventional'
assert_not_contains "$out" $'\tfeat(git): fine one' 'a fine commit is not listed'
assert_not_contains "$out" $'\tfix: fine two' 'the other fine commit is not listed'
assert_not_contains "$out" 'Merge branch side' 'the merge commit is never linted'
assert_not_contains "$out" 'test: on a side branch' 'a fine commit merged from a side branch is not listed'
out="$(run_in "$repo" --base main 2>&1)"
assert_contains "$out" '4 of 9 commit(s) have problems' 'the human summary counts commits, not problems'
assert_contains "$out" 'not-conventional  bad subject without type' 'the human line names problem and subject'
assert_contains "$out" 'too-long  feat: xxx' 'the human line truncates a long subject'
assert_contains "$out" '...' 'a truncated subject is marked'

section "ranges"
by_base="$(run_in "$repo" --base main --porcelain 2>&1)"
by_range="$(run_in "$repo" --range main..HEAD --porcelain 2>&1)"
assert_eq "$by_range" "$by_base" '--base main and --range main..HEAD agree'
by_default="$(run_in "$repo" --porcelain 2>&1)"
assert_eq "$by_default" "$by_base" 'with no range the base is inferred as main'
out="$(run_in "$repo" --range="$base_sha..$two_sha" 2>&1)"; rc=$?
assert_eq "$rc" 0 'a range of fine commits -> 0'
assert_contains "$out" '2 commit(s) checked, all fine' '--range= equals form lints exactly that range'
run_in "$repo" --range HEAD..HEAD >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'an empty range -> 4'
run_in "$repo" --range nope..HEAD >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'a range git cannot resolve -> 3'
run_in "$repo" --base nope >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'a base git cannot resolve -> 3'
run_in "$repo" --range main..HEAD --base main >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--range together with --base -> 3'

section "rule options"
out="$(run_in "$repo" --range "$base_sha..$two_sha" --max-subject 10 --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 1 '--max-subject 10 finds problems in fine commits'
assert_contains "$out" $'\ttoo-long\tfix: fine two' '--max-subject 10 flags a 13-character subject'
out="$(run_in "$repo" --range "$base_sha..$two_sha" --max-subject 08 --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 1 '--max-subject 08 reads as decimal 8, not octal'
assert_contains "$out" $'\ttoo-long\tfix: fine two' '--max-subject 08 still flags a 13-character subject'
out="$(run_in "$repo" --range "$base_sha..$two_sha" --types feat --porcelain 2>&1)"
assert_contains "$out" $'\tnot-conventional\tfix: fine two' '--types feat makes a fix: commit unconventional'
assert_not_contains "$out" 'feat(git): fine one' '--types feat keeps feat commits fine'
out="$(run_in "$repo" --base main --allow-fixup --porcelain 2>&1)"
assert_not_contains "$out" 'fixup! feat(git): fine one' '--allow-fixup removes the fixup finding'
out="$(run_in "$repo" --base main --forbid 'Signed-off-by' --porcelain 2>&1)"
assert_contains "$out" $'\tforbidden\tfeat: signed' '--forbid flags the commit carrying the pattern'
assert_eq "$(grep -c $'\tforbidden\t' <<<"$out")" 1 '--forbid flags only that commit'
out="$(run_in "$repo" --base main --forbid='signed-OFF-by' --forbid 'bad subject' --porcelain 2>&1)"
assert_eq "$(grep -c $'\tforbidden\t' <<<"$out")" 2 '--forbid= is repeatable and ignores case'
out="$(run_in "$repo" --base main --forbid 'Signed-off-by' 2>&1)"
assert_contains "$out" 'forbidden /Signed-off-by/' 'the human line names the pattern that matched'

section "merge and revert subjects"
# A plain commit (not a merge) whose subject git wrote for a merge, as a
# squash merge leaves it; commit-tree keeps HEAD where the other sections
# expect it.
merge_subject_sha="$(git -C "$repo" commit-tree -p "$two_sha" -m 'Merge branch side into feature' "$two_sha^{tree}")" ||
  err 'create merge-subject fixture'
revert_subject_sha="$(git -C "$repo" commit-tree -p "$merge_subject_sha" -m 'Revert "fix: fine two"' "$two_sha^{tree}")" ||
  err 'create revert-subject fixture'
out="$(run_in "$repo" --range "$two_sha..$revert_subject_sha" --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 'Merge and Revert subjects on plain commits pass, as in the hook'
assert_not_contains "$out" 'not-conventional' 'a Merge subject is not called unconventional'

section "usage and environment"
run_in "$repo" --max-subject abc >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--max-subject abc -> 3'
run_in "$repo" --types 'Feat!' >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--types with a bad word -> 3'
run_in "$repo" --forbid '(' >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--forbid with an invalid regex -> 3'
run_in "$repo" --range >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--range without a value -> 3'
run_in "$repo" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'unknown flag -> 3'
out="$(run_in "$repo" --help 2>&1)"
assert_not_contains "$out" '--dry-run' 'a read-only lint does not advertise a dry run'
git init -q -b trunk "$scratch/trunk" &&
  git -C "$scratch/trunk" config user.name Test &&
  git -C "$scratch/trunk" config user.email test@example.com &&
  git -C "$scratch/trunk" commit -q --allow-empty -m 'chore: root' || err 'create trunk fixture'
run_in "$scratch/trunk" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'no main, master or origin/HEAD to infer -> 4'
mkdir -p "$scratch/plain" || err 'create plain directory'
(cd "$scratch/plain" && GIT_CEILING_DIRECTORIES="$scratch" "$COMMITLINT") >/dev/null 2>&1; rc=$?
assert_eq "$rc" 2 'outside a repository -> 2'

end_section
if (( checks == 0 || failures > 0 )); then
  printf '=== %s of %s commitlint checks failed ===\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s commitlint checks passed ===\n' "$checks"

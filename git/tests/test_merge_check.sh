#!/usr/bin/env bash
# Verify git_merge_check.sh forecasts clean, conflicting, merged, fast-forward
# and unmergeable branches without touching HEAD, the index or any ref.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MERGE_CHECK="$REPO_ROOT/git/git_merge_check.sh"
scratch="$(mktemp -d /tmp/merge-check-tests.XXXXXX)"
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
finish() {
  end_section
  if (( checks == 0 || failures > 0 )); then
    printf '=== %s of %s merge check checks failed ===\n' "$failures" "$checks" >&2
    exit 1
  fi
  printf '=== all %s merge check checks passed ===\n' "$checks"
  exit 0
}
run_in() {
  local dir="$1"
  shift
  (cd "$dir" && "$MERGE_CHECK" "$@")
}
new_repo() {
  git init -q -b "$2" "$1" &&
    git -C "$1" config user.name Test &&
    git -C "$1" config user.email test@example.com
}

# --- fixture ---------------------------------------------------------------
repo="$scratch/repo"
new_repo "$repo" main &&
  printf 'a\nb\nc\n' >"$repo/file.txt" &&
  printf 'x\ny\nz\n' >"$repo/two.txt" &&
  printf 'p\nq\nr\n' >"$repo/three.txt" &&
  git -C "$repo" add . &&
  git -C "$repo" commit -q -m base || { err 'create base fixture'; finish; }

# merge-tree --write-tree arrived in Git 2.38. The tester image ships a newer
# one; on an older git the script exits 2, and that is all that can be checked.
if ! git -C "$repo" merge-tree --write-tree --name-only HEAD HEAD >/dev/null 2>&1; then
  section "git too old for merge-tree --write-tree"
  run_in "$repo" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 2 'an old git fails closed with exit 2'
  ok 'skipped: git too old for the rest of this suite'
  finish
fi

git -C "$repo" switch -q -c clean-add &&
  printf 'new\n' >"$repo/new.txt" &&
  git -C "$repo" add new.txt &&
  git -C "$repo" commit -q -m 'add a file' &&
  git -C "$repo" switch -q -c conflicting main &&
  printf 'a\nB-branch\nc\n' >"$repo/file.txt" &&
  git -C "$repo" commit -q -am 'change b on the branch' &&
  git -C "$repo" switch -q -c other-conflict main &&
  printf 'x\nY-branch\nz\n' >"$repo/two.txt" &&
  printf 'p\nQ-branch\nr\n' >"$repo/three.txt" &&
  git -C "$repo" commit -q -am 'change two files on the branch' &&
  git -C "$repo" switch -q -c already main &&
  printf 'merged\n' >"$repo/already.txt" &&
  git -C "$repo" add already.txt &&
  git -C "$repo" commit -q -m 'merged early' &&
  git -C "$repo" switch -q main &&
  git -C "$repo" merge -q --ff-only already &&
  printf 'a\nB-main\nc\n' >"$repo/file.txt" &&
  printf 'x\nY-main\nz\n' >"$repo/two.txt" &&
  printf 'p\nQ-main\nr\n' >"$repo/three.txt" &&
  git -C "$repo" commit -q -am 'change b, y and q on main' &&
  git -C "$repo" switch -q -c ahead main &&
  git -C "$repo" commit -q --allow-empty -m 'one above main' &&
  git -C "$repo" switch -q --orphan unrelated &&
  printf 'other\n' >"$repo/other.txt" &&
  git -C "$repo" add other.txt &&
  git -C "$repo" commit -q -m 'unrelated root' &&
  git -C "$repo" switch -q main || { err 'create branch fixture'; finish; }

section "statuses"
out="$(run_in "$repo" --into main clean-add conflicting other-conflict already ahead 2>&1)"; rc=$?
assert_eq "$rc" 1 'a conflicting branch -> 1'
assert_contains "$out" 'clean     clean-add' 'a branch adding a file merges clean'
assert_contains "$out" 'conflict  conflicting  1 file(s): file.txt' 'the conflicting branch names its file'
assert_contains "$out" 'conflict  other-conflict  2 file(s):' 'a two-file conflict counts both files'
assert_contains "$out" 'three.txt' 'the first conflicting file is named'
assert_contains "$out" 'two.txt' 'the second conflicting file is named'
assert_contains "$out" 'merged    already  already in main' 'a branch already in main is merged'
assert_contains "$out" 'ff        ahead  fast-forward' 'a branch above main is a fast-forward'
assert_contains "$out" '5 branch(es) into main: 1 clean, 2 conflicting, 1 merged, 1 fast-forward, 0 error(s)' 'the summary counts every status'
out="$(run_in "$repo" --into=main clean-add already ahead 2>&1)"; rc=$?
assert_eq "$rc" 0 'only clean, merged and fast-forward branches -> 0'
assert_contains "$out" 'into main' '--into=main equals form is accepted'

section "porcelain"
out="$(run_in "$repo" --porcelain clean-add conflicting other-conflict 2>&1)"
assert_contains "$out" $'clean\tclean-add\tmain\t' 'porcelain clean row'
assert_contains "$out" $'conflict\tconflicting\tmain\tfile.txt' 'porcelain conflict row names the path'
assert_contains "$out" $'conflict\tother-conflict\tmain\ttwo.txt' 'porcelain prints one row per conflicting path'
assert_contains "$out" $'conflict\tother-conflict\tmain\tthree.txt' 'porcelain prints the other conflicting path too'
assert_not_contains "$out" 'branch(es) into' 'porcelain prints no summary'

section "unrelated histories"
out="$(run_in "$repo" --into main unrelated 2>&1)"; rc=$?
assert_eq "$rc" 1 'an unrelated branch -> 1'
assert_contains "$out" 'error     unrelated' 'an unrelated branch is an error, not a conflict'

section "branch selection"
out="$(run_in "$repo" --all-local 2>&1)"
for b in clean-add conflicting other-conflict already ahead unrelated; do
  assert_contains "$out" "$b" "--all-local checks $b"
done
assert_contains "$out" '6 branch(es) into main' '--all-local leaves the base itself out'
git -C "$repo" switch -q ahead || err 'switch to ahead'
out="$(run_in "$repo" 2>&1)"; rc=$?
assert_eq "$rc" 0 'no branch checks HEAD'
assert_contains "$out" 'ff        HEAD  fast-forward' 'no branch checks HEAD against the default base'
git -C "$repo" switch -q main || err 'switch back to main'

section "default base"
mrepo="$scratch/master-only"
new_repo "$mrepo" master &&
  git -C "$mrepo" commit -q --allow-empty -m root &&
  git -C "$mrepo" switch -q -c topic &&
  git -C "$mrepo" commit -q --allow-empty -m topic || err 'create master fixture'
out="$(run_in "$mrepo" topic 2>&1)"; rc=$?
assert_eq "$rc" 0 'a repository whose only base is master works'
assert_contains "$out" 'into master' 'the base is inferred as master'

section "not found and usage"
run_in "$repo" --into nope clean-add >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 '--into naming no branch -> 4'
run_in "$repo" --into main no-such-branch >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'an unknown branch -> 4'
run_in "$repo" --into >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--into without a value -> 3'
run_in "$repo" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'unknown flag -> 3'
git init -q -b main "$scratch/unborn" || err 'create unborn repository'
run_in "$scratch/unborn" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'a repository with no commits -> 4'
out="$(run_in "$scratch/unborn" 2>&1)"
assert_contains "$out" 'HEAD has no commits yet' 'an empty repository says HEAD has no commits'
# A bare repository whose HEAD names an unborn branch (HEAD points at
# refs/heads/unborn-head, refs only under main): explicit names must not
# need HEAD.
git clone -q --bare "$repo" "$scratch/bare.git" || err 'create bare repository'
git -C "$scratch/bare.git" symbolic-ref HEAD refs/heads/unborn-head || err 'unborn bare HEAD'
run_in "$scratch/bare.git" --into main clean-add >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 'a bare repository with an unborn HEAD checks explicit names'
run_in "$scratch/bare.git" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'a bare repository with an unborn HEAD and no names -> 4'

section "nothing is touched"
printf 'a\nlocal edit\nc\n' >"$repo/file.txt" || err 'dirty the worktree'
head_before="$(git -C "$repo" rev-parse HEAD)"
status_before="$(git -C "$repo" status --porcelain)"
refs_before="$(git -C "$repo" for-each-ref)"
out="$(run_in "$repo" --into main conflicting other-conflict clean-add 2>&1)"; rc=$?
assert_eq "$rc" 1 'a dirty worktree does not stop the forecast'
assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" 'HEAD is unchanged'
assert_eq "$(git -C "$repo" status --porcelain)" "$status_before" 'the index and the dirty worktree are unchanged'
assert_eq "$(git -C "$repo" for-each-ref)" "$refs_before" 'no ref is created or moved'

finish

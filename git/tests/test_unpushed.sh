#!/usr/bin/env bash
# Verify git_unpushed.sh finds every kind of local-only work, filters by
# remote, and changes nothing, in disposable repositories.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
UNPUSHED="$REPO_ROOT/git/git_unpushed.sh"
scratch="$(mktemp -d /tmp/unpushed-tests.XXXXXX)"
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
  (cd "$dir" && "$UNPUSHED" "$@")
}

# --- fixture ---------------------------------------------------------------
repo="$scratch/repo"
git init -q --bare -b main "$scratch/origin.git" &&
  git init -q -b main "$repo" &&
  git -C "$repo" config user.name Test &&
  git -C "$repo" config user.email test@example.com &&
  printf 'one\n' >"$repo/file.txt" &&
  git -C "$repo" add file.txt &&
  git -C "$repo" commit -q -m one &&
  git -C "$repo" remote add origin "$scratch/origin.git" &&
  git -C "$repo" push -q -u origin main || { err 'create fixture'; exit 1; }

section "everything pushed"
out="$(run_in "$repo" 2>&1)"; rc=$?
assert_eq "$rc" 0 'a fully pushed repository exits 0'
assert_contains "$out" 'nothing exists only on this machine' 'a fully pushed repository says so'
run_in "$repo" --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 '--strict exits 0 when nothing is at risk'
out="$(run_in "$repo" --porcelain 2>&1)"
assert_eq "$out" "" '--porcelain prints nothing when nothing is at risk'

section "usage"
run_in "$repo" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'unknown flag -> 3'
run_in "$repo" --limit x >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--limit x -> 3'
run_in "$repo" --limit >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--limit without a value -> 3'
run_in "$repo" --remote nope >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 '--remote naming no remote -> 4'
run_in "$repo" --remote=origin >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 '--remote=origin equals form is accepted'
out="$(run_in "$repo" --help 2>&1)"
assert_not_contains "$out" '--dry-run' 'a read-only report does not advertise a dry run'

section "unpushed commits"
git -C "$repo" switch -q -c feature/x &&
  git -C "$repo" commit -q --allow-empty -m 'first local change' || err 'commit on feature/x'
out="$(run_in "$repo" 2>&1)"
assert_contains "$out" 'feature/x' 'the unpushed branch is named'
assert_contains "$out" '1 unpushed commit' 'the summary counts the unpushed commit'
assert_contains "$out" 'first local change' 'the unpushed subject is listed'
git -C "$repo" commit -q --allow-empty -m 'second local change' || err 'second commit on feature/x'
out="$(run_in "$repo" --limit 1 2>&1)"
assert_contains "$out" 'second local change' '--limit 1 lists the newest subject'
assert_not_contains "$out" 'first local change' '--limit 1 leaves the older subject out'
assert_contains "$out" '... and 1 more' '--limit 1 says how many it left out'
out="$(run_in "$repo" --limit 01 2>&1)"
assert_contains "$out" '... and 1 more' '--limit 01 reads as decimal 1'

section "branches with no upstream"
git -C "$repo" branch no-up main || err 'create no-up branch'
out="$(run_in "$repo" --porcelain 2>&1)"
assert_contains "$out" $'no-upstream\tno-up\t0\t' 'a pushed branch with no upstream is flagged'
assert_not_contains "$out" $'commits\tno-up\t' 'a pushed branch with no upstream has no unpushed commits'
assert_contains "$out" $'commits\tfeature/x\t2\tsecond local change' 'the porcelain commits row carries count and newest subject'
assert_contains "$out" $'no-upstream\tfeature/x\t2\t' 'a new branch is also flagged as having no upstream'

section "stash and uncommitted work"
printf 'stash me\n' >>"$repo/file.txt" &&
  printf 'stash me too\n' >"$repo/stashed.txt" &&
  git -C "$repo" stash push -q -u -m 'parked work' || err 'create stash'
printf 'edit\n' >>"$repo/file.txt" &&
  printf 'new\n' >"$repo/new.txt" &&
  mkdir -p "$repo/.git/info" &&
  printf 'ignored.log\n' >>"$repo/.git/info/exclude" &&
  printf 'log\n' >"$repo/ignored.log" || err 'create uncommitted work'
out="$(run_in "$repo" 2>&1)"
assert_contains "$out" '1 stash(es), newest: On feature/x: parked work' 'the stash is counted with its subject'
assert_contains "$out" '1 tracked change(s), 1 untracked path(s)' 'uncommitted work is split into tracked and untracked; ignored files are not counted'
out="$(run_in "$repo" --porcelain 2>&1)"
assert_contains "$out" $'stash\tstash\t1\tOn feature/x: parked work' 'the porcelain stash row'
assert_contains "$out" $'uncommitted\ttracked\t1\t' 'the porcelain tracked row'
assert_contains "$out" $'uncommitted\tuntracked\t1\t' 'the porcelain untracked row'
run_in "$repo" --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 '--strict exits 1 when something exists only here'
run_in "$repo" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 'without --strict the report exits 0'

section "read-only"
refs_before="$(git -C "$repo" for-each-ref)"
status_before="$(git -C "$repo" status --porcelain)"
run_in "$repo" --strict >/dev/null 2>&1
run_in "$repo" --porcelain >/dev/null 2>&1
assert_eq "$(git -C "$repo" for-each-ref)" "$refs_before" 'no ref was changed'
assert_eq "$(git -C "$repo" status --porcelain)" "$status_before" 'the index and worktree were not changed'

section "--remote counts only that remote as pushed"
git init -q --bare -b main "$scratch/mirror.git" &&
  git -C "$repo" remote add mirror "$scratch/mirror.git" &&
  git -C "$repo" push -q mirror main &&
  git -C "$repo" push -q origin feature/x || err 'create mirror fixture'
out="$(run_in "$repo" --porcelain 2>&1)"
assert_not_contains "$out" $'commits\tfeature/x\t' 'a branch on origin is pushed for the default question'
out="$(run_in "$repo" --porcelain --remote mirror 2>&1)"
assert_contains "$out" $'commits\tfeature/x\t2\t' 'with --remote mirror the branch only origin has is unpushed'
run_in "$repo" --tags >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--tags with two remotes and no --remote -> 3'

section "--tags"
git -C "$repo" tag v1.0 main &&
  git -C "$repo" tag -a v1.1 -m 'annotated' main &&
  git -C "$repo" push -q origin v1.0 || err 'create tag fixture'
out="$(run_in "$repo" --tags --remote origin --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 '--tags exits 0 when the remote answers'
assert_contains "$out" $'tag\tv1.1\t1\torigin' 'the unpushed annotated tag is listed'
assert_not_contains "$out" $'tag\tv1.0\t' 'the pushed tag is not listed'
out="$(run_in "$repo" --tags --remote origin 2>&1)"
assert_contains "$out" '1 unpushed tag(s)' 'the summary counts unpushed tags'
# A tag with the same name but a different object is not pushed: the remote
# holds the old target, and the local one exists only here.
moved="$(git -C "$repo" commit-tree -m moved -p main 'main^{tree}')" &&
  git -C "$repo" tag -f v1.0 "$moved" >/dev/null || err 'move a pushed lightweight tag'
out="$(run_in "$repo" --tags --remote origin --porcelain 2>&1)"
assert_contains "$out" $'tag\tv1.0\t1\torigin' 'a lightweight tag moved after the push is listed'
git -C "$repo" tag -f v1.0 main >/dev/null || err 'restore the lightweight tag'
git -C "$repo" push -q origin v1.1 &&
  git -C "$repo" tag -f -a v1.1 -m 'rewritten' main >/dev/null || err 'rewrite a pushed annotated tag'
out="$(run_in "$repo" --tags --remote origin --porcelain 2>&1)"
assert_contains "$out" $'tag\tv1.1\t1\torigin' 'an annotated tag re-created after the push is listed'
assert_not_contains "$out" $'tag\tv1.0\t' 'the restored lightweight tag is pushed again'
git -C "$repo" tag -d v1.1 >/dev/null &&
  git -C "$repo" fetch -q origin 'refs/tags/v1.1:refs/tags/v1.1' || err 'restore the annotated tag from the remote'
out="$(run_in "$repo" --tags --remote origin --porcelain 2>&1)"
assert_not_contains "$out" $'tag\tv1.1\t' 'an annotated tag equal to the remote one is pushed'
# A tag of an annotated tag peels to the commit through two objects; the
# remote lists that commit as NAME^{}, so an identical copy is pushed.
git -C "$repo" -c advice.nestedTag=false tag -a vnest -m 'nested' v1.1 &&
  git -C "$repo" push -q origin vnest || err 'push a nested annotated tag'
out="$(run_in "$repo" --tags --remote origin --porcelain 2>&1)"
assert_not_contains "$out" $'tag\tvnest\t' 'a nested annotated tag equal to the remote one is pushed'
# A remote listing without NAME^{} lines (a server or proxy that hides the
# peeled entries) is compared on the plain object id alone. A git shim drops
# the peeled lines from ls-remote output; every other call passes through.
real_git="$(command -v git)"
mkdir -p "$scratch/shim" &&
  cat >"$scratch/shim/git" <<SHIM &&
#!/usr/bin/env bash
if [[ "\${1:-}" == ls-remote ]]; then
  "$real_git" "\$@" | grep -v '\^{}\$'
  exit "\${PIPESTATUS[0]}"
fi
exec "$real_git" "\$@"
SHIM
  chmod +x "$scratch/shim/git" || err 'create the ls-remote shim'
out="$(PATH="$scratch/shim:$PATH" run_in "$repo" --tags --remote origin --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 'a listing without peeled lines still answers'
assert_not_contains "$out" $'tag\tv1.1\t' 'an annotated tag equal to a remote without a peeled line is pushed'
assert_not_contains "$out" $'tag\tvnest\t' 'a nested tag equal to a remote without a peeled line is pushed'
git -C "$repo" -c advice.nestedTag=false tag -a vlocal -m 'local only' main || err 'create a local-only annotated tag'
out="$(PATH="$scratch/shim:$PATH" run_in "$repo" --tags --remote origin --porcelain 2>&1)"
assert_contains "$out" $'tag\tvlocal\t1\torigin' 'a local-only annotated tag is still listed without peeled lines'
git -C "$repo" tag -d vlocal >/dev/null || err 'drop the local-only tag'
git -C "$repo" remote add broken "$scratch/does-not-exist.git" || err 'add unreachable remote'
out="$(run_in "$repo" --tags --remote broken 2>&1)"; rc=$?
assert_eq "$rc" 1 'an unreachable remote -> 1'
assert_contains "$out" 'cannot reach broken' 'an unreachable remote is named'

section "detached HEAD"
git -C "$repo" stash push -q -u -m 'park again' &&
  git -C "$repo" switch -q --detach main &&
  git -C "$repo" commit -q --allow-empty -m 'detached work' || err 'commit on a detached HEAD'
out="$(run_in "$repo" --porcelain 2>&1)"
assert_contains "$out" $'commits\tHEAD\t1\tdetached work' 'commits on a detached HEAD are counted'

section "no remote, no commits, no repository"
norem="$scratch/norem"
git init -q -b main "$norem" &&
  git -C "$norem" config user.name Test &&
  git -C "$norem" config user.email test@example.com &&
  git -C "$norem" commit -q --allow-empty -m 'only here' || err 'create norem fixture'
out="$(run_in "$norem" 2>&1)"; rc=$?
assert_eq "$rc" 0 'a repository with no remote still reports'
assert_contains "$out" 'no remotes configured' 'a repository with no remote says so once'
assert_contains "$out" '1 unpushed commit(s) on 1 branch(es)' 'with no remote every commit is unpushed'
git init -q -b main "$scratch/empty" || err 'create empty repository'
run_in "$scratch/empty" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'a repository with no commits -> 4'
mkdir -p "$scratch/plain" || err 'create plain directory'
(cd "$scratch/plain" && GIT_CEILING_DIRECTORIES="$scratch" "$UNPUSHED") >/dev/null 2>&1; rc=$?
assert_eq "$rc" 2 'outside a repository -> 2'

section "unreadable index fails closed"
git clone -q "$scratch/origin.git" "$scratch/corrupt" || err 'clone corrupt fixture'
printf 'not an index\n' >"$scratch/corrupt/.git/index" || err 'corrupt the index'
out="$(run_in "$scratch/corrupt" 2>&1)"; rc=$?
assert_eq "$rc" 0 'a plain run exits 0 with an unreadable index'
assert_contains "$out" 'git status failed' 'a failing git status is reported'
run_in "$scratch/corrupt" --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 '--strict exits 1 when git status cannot be read'
out="$(run_in "$scratch/corrupt" --porcelain 2>&1)"
assert_contains "$out" 'git status failed' '--porcelain also reports the failure'
out="$(run_in "$scratch/corrupt" 2>/dev/null)"
assert_contains "$out" 'incomplete: could not check uncommitted changes' 'a failed status prints an incomplete result on stdout'
assert_not_contains "$out" 'nothing exists only on this machine' 'a failed status never claims nothing is at risk'
out="$(run_in "$scratch/corrupt" --strict 2>/dev/null)"
assert_not_contains "$out" 'nothing exists only on this machine' '--strict with a failed status never claims nothing is at risk'

section "unreachable tag remote fails closed"
git clone -q "$scratch/origin.git" "$scratch/notags" || err 'clone notags fixture'
git -C "$scratch/notags" remote add broken "$scratch/does-not-exist.git" || err 'add unreachable remote'
out="$(run_in "$scratch/notags" --tags --remote broken 2>/dev/null)"; rc=$?
assert_eq "$rc" 1 'an unreachable tag remote -> 1'
assert_contains "$out" 'incomplete: could not check tags on broken' 'an unreachable tag remote prints an incomplete result on stdout'
assert_not_contains "$out" 'nothing exists only on this machine' 'an unreachable tag remote never claims nothing is at risk'

end_section
if (( checks == 0 || failures > 0 )); then
  printf '=== %s of %s unpushed checks failed ===\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s unpushed checks passed ===\n' "$checks"

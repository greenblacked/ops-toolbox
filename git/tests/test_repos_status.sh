#!/usr/bin/env bash
# Verify git_repos_status.sh discovery, counts, filters and exit codes against
# a directory of disposable checkouts.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
REPOS_STATUS="$REPO_ROOT/git/git_repos_status.sh"
scratch="$(mktemp -d /tmp/repos-status-tests.XXXXXX)"
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

clone_into() {
  git clone -q "$origin" "$1" &&
    git -C "$1" config user.name Test &&
    git -C "$1" config user.email test@example.com
}

# --- fixture ---------------------------------------------------------------
origin="$scratch/origin.git"
seed="$scratch/seed"
parent="$scratch/parent"
git init -q --bare -b main "$origin" &&
  git init -q -b main "$seed" &&
  git -C "$seed" config user.name Test &&
  git -C "$seed" config user.email test@example.com &&
  printf 'one\n' >"$seed/file.txt" &&
  git -C "$seed" add file.txt &&
  git -C "$seed" commit -q -m one &&
  git -C "$seed" remote add origin "$origin" &&
  git -C "$seed" push -q -u origin main || { err 'create origin fixture'; exit 1; }

mkdir -p "$parent/notrepo" "$parent/deep" || { err 'create parent fixture'; exit 1; }
for name in clean dirty ahead stashed "with space"; do
  clone_into "$parent/$name" || { err "clone $name fixture"; exit 1; }
done
clone_into "$parent/deep/nested" || { err 'clone nested fixture'; exit 1; }
printf 'changed\n' >>"$parent/dirty/file.txt" &&
  printf 'new\n' >"$parent/dirty/untracked.txt" || err 'make dirty fixture'
printf 'local\n' >>"$parent/ahead/file.txt" &&
  git -C "$parent/ahead" commit -q -am 'local only' || err 'make ahead fixture'
printf 'stash me\n' >>"$parent/stashed/file.txt" &&
  printf 'stash me too\n' >"$parent/stashed/extra.txt" &&
  git -C "$parent/stashed" stash push -q -u || err 'make stash fixture'
git init -q -b main "$parent/norem" &&
  git -C "$parent/norem" config user.name Test &&
  git -C "$parent/norem" config user.email test@example.com &&
  git -C "$parent/norem" commit -q --allow-empty -m 'no remote' || err 'make norem fixture'

section "usage"
out="$("$REPOS_STATUS" --definitely-not-a-flag 2>&1)"; rc=$?
assert_eq "$rc" 3 'unknown flag -> 3'
out="$("$REPOS_STATUS" --dir 2>&1)"; rc=$?
assert_eq "$rc" 3 '--dir without a value -> 3'
assert_contains "$out" '--dir requires a value' '--dir without a value explains itself'
out="$("$REPOS_STATUS" --dir "$parent" --depth abc 2>&1)"; rc=$?
assert_eq "$rc" 3 '--depth abc -> 3'
out="$("$REPOS_STATUS" --dir "$parent" --only bogus 2>&1)"; rc=$?
assert_eq "$rc" 3 '--only bogus -> 3'
out="$("$REPOS_STATUS" --help 2>&1)"; rc=$?
assert_eq "$rc" 0 '--help -> 0'
assert_contains "$out" 'Exit codes:' '--help documents exit codes'

section "discovery"
out="$("$REPOS_STATUS" --dir="$parent" 2>&1)"; rc=$?
assert_eq "$rc" 0 'a plain run exits 0 even with work at risk'
for name in clean dirty ahead stashed "with space" norem deep/nested; do
  assert_contains "$out" "$name" "the report names $name"
done
assert_not_contains "$out" 'notrepo' 'a plain directory is not reported'
assert_contains "$out" '7 repositories: 4 with work at risk' 'the summary counts repositories and work at risk'
out="$("$REPOS_STATUS" --dir "$parent" --depth 1 2>&1)"
assert_not_contains "$out" 'deep/nested' '--depth 1 does not reach a repository two levels down'
assert_contains "$out" 'clean' '--depth 1 still reports the first level'
out="$("$REPOS_STATUS" --dir "$parent/clean" 2>&1)"; rc=$?
assert_eq "$rc" 0 'a --dir that is itself a repository is reported'
assert_contains "$out" '1 repository: 0 with work at risk' 'a --dir that is a repository is reported alone'
assert_not_contains "$out" 'dirty' 'a --dir that is a repository does not reach its siblings'

section "porcelain rows"
out="$("$REPOS_STATUS" --dir "$parent" --porcelain 2>&1)"
assert_contains "$out" "$parent/clean"$'\tmain\torigin/main\t0\t0\t0\t0\t0\t' 'clean row is in sync'
assert_contains "$out" "$parent/dirty"$'\tmain\torigin/main\t0\t0\t2\t0\t0\tdirty' 'dirty row counts a tracked and an untracked change'
assert_contains "$out" "$parent/ahead"$'\tmain\torigin/main\t1\t0\t0\t0\t1\tahead' 'ahead row counts the unpushed commit twice over'
assert_contains "$out" "$parent/stashed"$'\tmain\torigin/main\t0\t0\t0\t1\t0\tstash' 'stashed row counts the stash'
assert_contains "$out" "$parent/norem"$'\tmain\t\t0\t0\t0\t0\t1\tno-upstream,no-remote' 'norem row has no upstream and notes no-remote'
assert_contains "$out" "$parent/with space"$'\tmain\t' 'a path with a space survives'
assert_not_contains "$out" 'REPO' '--porcelain prints no header'

section "--only"
out="$("$REPOS_STATUS" --dir "$parent" --only dirty 2>&1)"
assert_contains "$out" 'dirty' '--only dirty shows the dirty checkout'
assert_not_contains "$out" 'clean' '--only dirty omits the clean checkout'
assert_contains "$out" '1 repository: 1 with work at risk' '--only describes the filtered set'
out="$("$REPOS_STATUS" --dir "$parent" --only=stash --porcelain 2>&1)"
assert_contains "$out" "$parent/stashed" '--only=stash shows the stashed checkout'
assert_not_contains "$out" "$parent/ahead" '--only=stash omits the rest'

section "--strict"
"$REPOS_STATUS" --dir "$parent" --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 '--strict exits 1 when work is at risk'
"$REPOS_STATUS" --dir "$parent/clean" --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 '--strict exits 0 for a clean checkout'

section "unreadable index fails closed"
clone_into "$parent/corrupt" || err 'clone corrupt fixture'
printf 'not an index\n' >"$parent/corrupt/.git/index" || err 'corrupt the index'
out="$("$REPOS_STATUS" --dir "$parent/corrupt" --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 'a plain run still exits 0 with an unreadable index'
assert_contains "$out" 'status-failed' 'a failing git status is reported as status-failed'
"$REPOS_STATUS" --dir "$parent/corrupt" --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 '--strict exits 1 when git status cannot be read'
out="$("$REPOS_STATUS" --dir "$parent/corrupt" --only dirty --porcelain 2>&1)"
assert_contains "$out" 'status-failed' '--only dirty keeps a checkout whose status failed'
rm -rf "$parent/corrupt"

section "environment and empty results"
mkdir -p "$scratch/empty" || err 'create empty directory'
out="$("$REPOS_STATUS" --dir "$scratch/empty" 2>&1)"; rc=$?
assert_eq "$rc" 4 'a directory with no repository -> 4'
out="$("$REPOS_STATUS" --dir "$scratch/does-not-exist" 2>&1)"; rc=$?
assert_eq "$rc" 2 'a --dir that does not exist -> 2'

section "--dry-run fetches nothing"
updater="$scratch/updater"
clone_into "$updater" &&
  printf 'two\n' >>"$updater/file.txt" &&
  git -C "$updater" commit -q -am two &&
  git -C "$updater" push -q origin main || err 'advance origin from a second clone'
tracking_before="$(git -C "$parent/clean" rev-parse refs/remotes/origin/main)"
tree_before="$(find "$parent" | sort)"
refs_before="$(git --git-dir="$origin" for-each-ref)"
out="$("$REPOS_STATUS" --dir "$parent" --dry-run 2>&1)"; rc=$?
assert_eq "$rc" 0 '--dry-run exits 0'
assert_contains "$out" "dry-run: would run: git -C $parent/clean fetch --prune --quiet" '--dry-run names the fetch it would run'
assert_contains "$out" 'dry-run complete; no changes written' '--dry-run closes with the summary line'
assert_eq "$(find "$parent" | sort)" "$tree_before" '--dry-run creates and removes no file'
out="$("$REPOS_STATUS" --dir "$parent" --dry-run --porcelain 2>/dev/null)"
assert_not_contains "$out" 'dry-run' '--dry-run --porcelain keeps dry-run lines off stdout'
err="$("$REPOS_STATUS" --dir "$parent" --dry-run --porcelain 2>&1 >/dev/null)"
assert_contains "$err" 'dry-run complete; no changes written' '--dry-run --porcelain sends the dry-run lines to stderr'
assert_eq "$(git --git-dir="$origin" for-each-ref)" "$refs_before" '--dry-run leaves the origin refs alone'
assert_eq "$(git -C "$parent/clean" rev-parse refs/remotes/origin/main)" "$tracking_before" \
  '--dry-run leaves the remote-tracking ref where it was'

section "--fetch"
out="$("$REPOS_STATUS" --dir "$parent/clean" --fetch --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 '--fetch exits 0'
assert_contains "$out" "$parent/clean"$'\tmain\torigin/main\t0\t1\t0\t0\t0\tbehind' '--fetch sees the new upstream commit'
out="$("$REPOS_STATUS" --dir "$parent/clean" 2>&1)"
assert_contains "$out" '-1' 'the human table shows the checkout one behind'
assert_contains "$out" '0 with work at risk, 1 behind' 'behind is not work at risk'

section "--fetch --prune: a branch deleted on the remote"
clone_into "$parent/pruned" &&
  git -C "$parent/pruned" switch -q -c topic &&
  printf 'topic\n' >"$parent/pruned/topic.txt" &&
  git -C "$parent/pruned" add topic.txt &&
  git -C "$parent/pruned" commit -q -m topic &&
  git -C "$parent/pruned" push -q -u origin topic || err 'push topic from the pruned fixture'
git -C "$updater" fetch -q origin &&
  git -C "$updater" push -q origin --delete topic || err 'delete topic on the remote from a second clone'
out="$("$REPOS_STATUS" --dir "$parent/pruned" --porcelain 2>&1)"
assert_contains "$out" $'\ttopic\torigin/topic\t0\t0\t0\t0\t0\t' 'without --fetch the stale ref still hides the commit'
out="$("$REPOS_STATUS" --dir "$parent/pruned" --fetch --porcelain 2>&1)"
assert_contains "$out" $'\ttopic\t\t0\t0\t0\t0\t1\t' '--fetch prunes the deleted branch so its commit is unpushed'
"$REPOS_STATUS" --dir "$parent/pruned" --fetch --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 '--strict --fetch exits 1 for a commit whose remote branch was deleted'
rm -rf "$parent/pruned"

section "a failed history walk fails closed"
clone_into "$parent/damaged" &&
  git -C "$parent/damaged" switch -q -c lost-work &&
  printf 'lost\n' >"$parent/damaged/lost.txt" &&
  git -C "$parent/damaged" add lost.txt &&
  git -C "$parent/damaged" commit -q -m lost &&
  git -C "$parent/damaged" switch -q main || err 'build the damaged fixture'
lost_sha="$(git -C "$parent/damaged" rev-parse lost-work)"
lost_obj="$parent/damaged/.git/objects/${lost_sha:0:2}/${lost_sha:2}"
if [[ -f "$lost_obj" ]]; then
  rm -f "$lost_obj" || err 'remove the loose commit object'
  out="$("$REPOS_STATUS" --dir "$parent/damaged" --porcelain 2>&1)"; rc=$?
  assert_eq "$rc" 0 'a plain run still exits 0 when the history walk fails'
  assert_contains "$out" 'walk-failed' 'a failing rev-list is reported as walk-failed'
  "$REPOS_STATUS" --dir "$parent/damaged" --strict >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 1 '--strict exits 1 when the history walk fails'
  out="$("$REPOS_STATUS" --dir "$parent/damaged" --only unpushed --porcelain 2>&1)"
  assert_contains "$out" 'walk-failed' '--only unpushed keeps a checkout whose walk failed'
else
  err 'the loose commit object was not where expected'
fi
rm -rf "$parent/damaged"

section "--fetch failure is work at risk"
clone_into "$parent/unreach" || err 'clone unreachable fixture'
git -C "$parent/unreach" remote set-url origin "$scratch/does-not-exist.git" || err 'break the remote url'
out="$("$REPOS_STATUS" --dir "$parent/unreach" --fetch --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 'a failed fetch still exits 0 without --strict'
assert_contains "$out" 'fetch-failed' 'a failed fetch is noted'
"$REPOS_STATUS" --dir "$parent/unreach" --fetch --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 '--strict --fetch exits 1 when the fetch failed'
"$REPOS_STATUS" --dir "$parent/unreach" --strict >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 '--strict without --fetch ignores the unreachable remote'
rm -rf "$parent/unreach"

end_section
if (( checks == 0 || failures > 0 )); then
  printf '=== %s of %s repos status checks failed ===\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s repos status checks passed ===\n' "$checks"

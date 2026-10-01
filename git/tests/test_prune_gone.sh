#!/usr/bin/env bash
# Verify prune selection, consent, and durable recovery in disposable repos.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PRUNE="$REPO_ROOT/git/git_prune_gone.sh"
scratch="$(mktemp -d /tmp/prune-gone-tests.XXXXXX)"
if [[ -z "$scratch" || ! -d "$scratch" ]]; then
  printf 'cannot create test scratch directory\n' >&2
  exit 1
fi
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
checks=0
failures=0
ok() { checks=$((checks + 1)); printf '[ ok ] %s\n' "$*"; }
err() { checks=$((checks + 1)); failures=$((failures + 1)); printf '[fail] %s\n' "$*" >&2; }
assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else err "$3: expected '$2', got '$1'"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else err "$3: missing '$2' in: $1"; fi
}

repo="$scratch/repo"
git init -q -b main "$repo" &&
  git -C "$repo" config user.name Test &&
  git -C "$repo" config user.email test@example.com &&
  git -C "$repo" commit -q --allow-empty -m initial || { err 'create fixture'; exit 1; }
for remote in origin other; do
  git init -q --bare -b main "$scratch/$remote.git" &&
    git -C "$repo" remote add "$remote" "$scratch/$remote.git" &&
    git -C "$repo" push -q "$remote" main || { err "create $remote fixture"; exit 1; }
done
base="$(git -C "$repo" rev-parse HEAD)"
tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
# commit-tree makes a tip never checked out, so no HEAD reflog can rescue it.
another_tip="$(printf 'another unmerged tip\n' | git -C "$repo" commit-tree "$tree" -p "$base")"
tip="$(printf 'unmerged work\n' | git -C "$repo" commit-tree "$tree" -p "$base")"
if [[ -z "$tip" ]]; then err 'create unmerged tip'; exit 1; fi
make_gone() {
  local branch="$1" remote="$2" sha="$3"
  git -C "$repo" branch "$branch" "$sha" &&
    git -C "$repo" push -q -u "$remote" "$branch" &&
    git --git-dir="$scratch/$remote.git" update-ref -d "refs/heads/$branch" &&
    git -C "$repo" fetch -q --prune "$remote"
}
for branch in selected keep develop worktree live unmerged another-unmerged; do
  sha="$base"
  [[ "$branch" == *unmerged ]] && sha="$tip"
  [[ "$branch" == another-unmerged ]] && sha="$another_tip"
  make_gone "$branch" origin "$sha" || { err "create gone $branch fixture"; exit 1; }
done
make_gone other-gone other "$base" || { err 'create other remote fixture'; exit 1; }
git -C "$repo" update-ref refs/remotes/origin/live "$base" || { err 'create live upstream'; exit 1; }
git -C "$repo" worktree add -q "$scratch/worktree" worktree || { err 'add worktree'; exit 1; }

git -C "$repo" symbolic-ref refs/heads/alias refs/heads/main &&
  git -C "$repo" config branch.alias.remote origin &&
  git -C "$repo" config branch.alias.merge refs/heads/alias || err 'create symbolic branch alias'

# Snapshot the whole Git directory, including objects, logs, config, and lock
# files: a no-fetch preview must write nothing, including recovery metadata.
cat > "$scratch/snapshot.py" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob('*')):
    print(path.relative_to(root), hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'directory')
PY
before="$(python3 "$scratch/snapshot.py" "$repo/.git")"
out="$(cd "$repo" && "$PRUNE" --remote origin --no-fetch --dry-run --allow-unmerged 2>&1)"; rc=$?
assert_eq "$rc" 0 'dry-run succeeds'
assert_contains "$out" 'dry-run complete; no changes written' 'dry-run reports zero writes'
after="$(python3 "$scratch/snapshot.py" "$repo/.git")"
assert_eq "$after" "$before" 'dry-run leaves all Git files unchanged'

out="$(cd "$repo" && "$PRUNE" --remote origin --no-fetch --include selected 2>&1)"; rc=$?
assert_eq "$rc" 0 'selected merged branch deletion succeeds'
git -C "$repo" show-ref --verify --quiet refs/heads/selected; rc=$?
assert_eq "$rc" 1 'selected branch is deleted'
git -C "$repo" show-ref --verify --quiet refs/heads/other-gone; rc=$?
assert_eq "$rc" 0 'other remote gone branch survives --remote origin --no-fetch'

out="$(cd "$repo" && "$PRUNE" --remote origin --no-fetch --force --include unmerged 2>&1)"; rc=$?
assert_eq "$rc" 0 'force-only prune succeeds without unmerged deletion'
assert_contains "$out" 'skip branch not reachable from HEAD' 'force does not imply unmerged consent'
git -C "$repo" show-ref --verify --quiet refs/heads/unmerged; rc=$?
assert_eq "$rc" 0 'unreachable tip survives without consent'

out="$(cd "$repo" && "$PRUNE" --remote origin --no-fetch --allow-unmerged --exclude keep --exclude another-unmerged 2>&1)"; rc=$?
assert_eq "$rc" 0 'consented unmerged deletion succeeds'
assert_contains "$out" "$tip" 'restore output contains full unmerged SHA'
assert_contains "$out" "git branch -- unmerged $tip" 'restore command uses full SHA'
assert_contains "$out" 'skip worktree branch: worktree' 'worktree branch is guarded'
assert_contains "$out" 'skip protected branch: develop' 'protected branch is guarded'
assert_contains "$out" 'skip symbolic branch: alias' 'symbolic branch alias is guarded'
assert_eq "$(git -C "$repo" symbolic-ref refs/heads/alias)" refs/heads/main 'symbolic alias preserves current branch target'
for branch in keep develop worktree live another-unmerged other-gone; do
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; rc=$?
  assert_eq "$rc" 0 "$branch survives filtering/protection/live upstream"
done
recovery_ref="$(git -C "$repo" for-each-ref --format='%(refname) %(objectname)' refs/ops-toolbox/prune-gone/ | awk -v sha="$tip" '$2 == sha {print $1}')"
assert_eq "$(git -C "$repo" rev-parse "$recovery_ref")" "$tip" 'durable recovery ref points at exact unmerged tip'
assert_eq "$(git -C "$repo" for-each-ref --contains="$tip" --format='%(refname)')" "$recovery_ref" 'recovery ref is the sole ref reaching never-checked-out tip'
git -C "$repo" reflog expire --expire=now --expire-unreachable=now --all &&
  git -C "$repo" gc --prune=now -q || err 'expire reflogs and prune garbage'
git -C "$repo" cat-file -e "$tip^{commit}"; rc=$?
assert_eq "$rc" 0 'never-checked-out unmerged commit survives reflog expiry and GC'
git -C "$repo" branch -- restored "$tip"; rc=$?
assert_eq "$rc" 0 'printed full SHA restores branch after GC'
assert_eq "$(git -C "$repo" rev-parse restored)" "$tip" 'restored tip matches original'

# Repeat a deletion for the same branch/tip: reuse its exact recovery mapping.
git -C "$repo" branch unmerged "$tip" || err 'recreate unmerged branch'
count_before="$(git -C "$repo" for-each-ref --format='%(refname)' refs/ops-toolbox/prune-gone/ | wc -l | tr -d ' ')"
out="$(cd "$repo" && "$PRUNE" --no-fetch --allow-unmerged --include unmerged 2>&1)"; rc=$?
assert_eq "$rc" 0 'same branch/tip prune is idempotent'
assert_eq "$(git -C "$repo" for-each-ref --format='%(refname)' refs/ops-toolbox/prune-gone/ | wc -l | tr -d ' ')" "$count_before" 'repeated branch/tip does not accumulate recovery refs'
out="$(cd "$repo" && "$PRUNE" --no-fetch --allow-unmerged --include unmerged 2>&1)"; rc=$?
assert_eq "$rc" 0 'prune with already deleted branch is a no-op'

# Failing a single create must abort the entire recovery transaction before
# deleting ANY candidate, including one whose backup could have been created.
make_gone fail-a origin "$base" && make_gone fail-b origin "$tip" || { err 'create failure fixtures'; exit 1; }
fail_key="$(printf '%s' fail-b | git -C "$repo" hash-object --stdin)"
mkdir -p "$repo/.git/refs/ops-toolbox/prune-gone/$fail_key" || err 'create failure ref directory'
touch "$repo/.git/refs/ops-toolbox/prune-gone/$fail_key/$tip.lock" || err 'lock recovery ref'
out="$(cd "$repo" && "$PRUNE" --no-fetch --allow-unmerged --include 'fail-*' 2>&1)"; rc=$?
assert_eq "$rc" 1 'recovery creation failure reports failure'
assert_contains "$out" 'no branches deleted' 'recovery creation failure says deletion aborted'
for branch in fail-a fail-b; do
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; rc=$?
  assert_eq "$rc" 0 "$branch survives failed recovery transaction"
done
assert_eq "$(git -C "$repo" for-each-ref --format='%(refname)' refs/ops-toolbox/prune-gone/ | wc -l | tr -d ' ')" "$count_before" 'failed recovery transaction leaves no partial refs'
rm "$repo/.git/refs/ops-toolbox/prune-gone/$fail_key/$tip.lock" || err 'remove simulated recovery ref lock'

fail_a_key="$(printf '%s' fail-a | git -C "$repo" hash-object --stdin)"
git -C "$repo" symbolic-ref "refs/ops-toolbox/prune-gone/$fail_a_key/$base" refs/heads/main || err 'create symbolic recovery ref'
out="$(cd "$repo" && "$PRUNE" --no-fetch --include fail-a 2>&1)"; rc=$?
assert_eq "$rc" 1 'symbolic recovery mapping fails closed'
assert_contains "$out" 'recovery ref is symbolic' 'symbolic recovery mapping explains refusal'
git -C "$repo" show-ref --verify --quiet refs/heads/fail-a; rc=$?
assert_eq "$rc" 0 'symbolic recovery mapping preserves branch'
git -C "$repo" update-ref --no-deref -d "refs/ops-toolbox/prune-gone/$fail_a_key/$base" || err 'remove symbolic recovery ref'

# Detached rebase/bisect HEADs still reserve branch names. Pause pruning across
# all worktrees, including the extra branches reserved by rebase --update-refs.
make_gone busy-rebase origin "$tip" || { err 'create busy rebase fixture'; exit 1; }
cat > "$scratch/edit-todo" <<'EDITOR'
#!/usr/bin/env bash
sed 's/^pick /edit /' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
EDITOR
chmod +x "$scratch/edit-todo" || err 'make rebase editor executable'
git -C "$repo" switch -q busy-rebase &&
  GIT_SEQUENCE_EDITOR="$scratch/edit-todo" git -C "$repo" rebase -i --keep-empty HEAD~1 >/dev/null 2>&1 || err 'pause current worktree rebase'
git -C "$repo" symbolic-ref -q HEAD >/dev/null; rc=$?
assert_eq "$rc" 1 'current rebase fixture has detached HEAD'
out="$(cd "$repo" && "$PRUNE" --no-fetch --force --allow-unmerged --include busy-rebase 2>&1)"; rc=$?
assert_eq "$rc" 0 'current detached rebase pauses prune'
assert_contains "$out" 'rebase or bisect is active' 'current rebase explains guard'
git -C "$repo" show-ref --verify --quiet refs/heads/busy-rebase; rc=$?
assert_eq "$rc" 0 'current detached rebase branch survives'
git -C "$repo" rebase --abort && git -C "$repo" switch -q main || err 'abort current rebase'
git -C "$repo" worktree add -q "$scratch/rebase-worktree" busy-rebase &&
  GIT_SEQUENCE_EDITOR="$scratch/edit-todo" git -C "$scratch/rebase-worktree" rebase -i --keep-empty HEAD~1 >/dev/null 2>&1 || err 'pause linked worktree rebase'
out="$(cd "$repo" && "$PRUNE" --no-fetch --force --allow-unmerged --include busy-rebase 2>&1)"; rc=$?
assert_eq "$rc" 0 'linked detached rebase pauses main worktree prune'
assert_contains "$out" 'rebase or bisect is active' 'linked rebase explains guard'
git -C "$repo" show-ref --verify --quiet refs/heads/busy-rebase; rc=$?
assert_eq "$rc" 0 'linked detached rebase branch survives'
git -C "$scratch/rebase-worktree" rebase --abort || err 'abort linked rebase'
# The next older commit used for bisect is distinct, so bisect really detaches.
bisect_tip="$(printf 'bisect tip\n' | git -C "$repo" commit-tree "$tree" -p "$tip")"
git -C "$scratch/rebase-worktree" reset -q --hard "$bisect_tip" &&
  git -C "$scratch/rebase-worktree" bisect start busy-rebase "$base" >/dev/null 2>&1 || err 'start linked bisect'
git -C "$scratch/rebase-worktree" symbolic-ref -q HEAD >/dev/null; rc=$?
assert_eq "$rc" 1 'linked bisect fixture has detached HEAD'
out="$(cd "$repo" && "$PRUNE" --no-fetch --force --allow-unmerged --include busy-rebase 2>&1)"; rc=$?
assert_eq "$rc" 0 'linked detached bisect pauses prune'
assert_contains "$out" 'rebase or bisect is active' 'linked bisect explains guard'
git -C "$repo" show-ref --verify --quiet refs/heads/busy-rebase; rc=$?
assert_eq "$rc" 0 'linked detached bisect branch survives'
git -C "$scratch/rebase-worktree" bisect reset >/dev/null 2>&1 &&
  git -C "$repo" worktree remove "$scratch/rebase-worktree" || err 'reset and remove busy linked worktree'

# Cap is fail closed, with exact mappings reusable at capacity. Packed refs
# keep the fixture inexpensive while using Git's real transaction machinery.
{
  for (( i=0; i<1000-count_before; i++ )); do
    printf 'create refs/ops-toolbox/prune-gone/fixture/%s %s\n' "$i" "$base"
  done
} | git -C "$repo" update-ref --stdin >/dev/null || err 'fill recovery store'
out="$(cd "$repo" && "$PRUNE" --no-fetch --include fail-a 2>&1)"; rc=$?
assert_eq "$rc" 1 'full recovery store fails closed'
assert_contains "$out" 'recovery ref limit (1000)' 'full recovery store explains limit'
git -C "$repo" show-ref --verify --quiet refs/heads/fail-a; rc=$?
assert_eq "$rc" 0 'capacity failure preserves branch'
git -C "$repo" branch unmerged "$tip" || err 'recreate previously saved branch at capacity'
out="$(cd "$repo" && "$PRUNE" --no-fetch --allow-unmerged --include unmerged 2>&1)"; rc=$?
assert_eq "$rc" 0 'existing exact recovery mapping remains usable at capacity'

mkdir "$repo/.git/ops-toolbox-prune-gone.lock" || err 'simulate active/stale prune lock'
out="$(cd "$repo" && "$PRUNE" --no-fetch --include fail-a 2>&1)"; rc=$?
assert_eq "$rc" 1 'concurrent/stale prune lock fails closed'
assert_contains "$out" 'cannot acquire prune lock' 'busy prune lock explains refusal'
git -C "$repo" show-ref --verify --quiet refs/heads/fail-a; rc=$?
assert_eq "$rc" 0 'busy prune lock preserves branch'
rmdir "$repo/.git/ops-toolbox-prune-gone.lock" || err 'remove simulated prune lock'

if (( checks == 0 || failures > 0 )); then
  printf '=== %s of %s prune recovery checks failed ===\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s prune recovery checks passed ===\n' "$checks"

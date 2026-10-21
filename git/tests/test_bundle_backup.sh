#!/usr/bin/env bash
# Verify git_bundle_backup.sh writes a verified, restorable bundle, prunes only
# its own older bundles and only with --yes, and previews without writing.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BUNDLE_BACKUP="$REPO_ROOT/git/git_bundle_backup.sh"
scratch="$(mktemp -d /tmp/bundle-backup-tests.XXXXXX)"
if [[ -z "$scratch" || ! -d "$scratch" ]]; then
  printf 'cannot create test scratch directory\n' >&2
  exit 1
fi
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# The default --out is under HOME; point it at scratch so no run here can
# write to the real one.
mkdir -p "$scratch/home"
export HOME="$scratch/home"
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
  (cd "$dir" && "$BUNDLE_BACKUP" "$@")
}
# Prints the bundles named PREFIX-<stamp>.bundle in DIR, one per line.
bundles_in() {
  local f
  for f in "$1/$2"-????????T??????Z.bundle; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}
count_lines() {
  if [[ -z "$1" ]]; then printf '0'; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# --- fixture ---------------------------------------------------------------
repo="$scratch/repo"
git init -q -b main "$repo" &&
  git -C "$repo" config user.name Test &&
  git -C "$repo" config user.email test@example.com &&
  printf 'one\n' >"$repo/file.txt" &&
  git -C "$repo" add file.txt &&
  git -C "$repo" commit -q -m one &&
  git -C "$repo" branch feature/a &&
  git -C "$repo" switch -q -c feature/b &&
  git -C "$repo" commit -q --allow-empty -m 'b work' &&
  git -C "$repo" switch -q main &&
  git -C "$repo" tag -a v1.0 -m 'v1.0' &&
  printf 'parked\n' >>"$repo/file.txt" &&
  git -C "$repo" stash push -q -m 'parked work' || { err 'create fixture'; exit 1; }

section "a real run"
out1="$scratch/out1"
refs_before="$(git -C "$repo" for-each-ref)"
out="$(run_in "$repo" --out "$out1" --name proj 2>&1)"; rc=$?
assert_eq "$rc" 0 'a backup run exits 0'
found="$(bundles_in "$out1" proj)"
assert_eq "$(count_lines "$found")" 1 'exactly one bundle with the stamped name is written'
partials=0
for f in "$out1"/.*.partial; do
  [[ -e "$f" ]] && partials=$((partials + 1))
done
assert_eq "$partials" 0 'no .partial file is left behind'
bundle1="$found"
git -C "$repo" bundle verify "$bundle1" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 'the bundle verifies'
assert_contains "$(git bundle list-heads "$bundle1" 2>/dev/null)" 'refs/stash' '--all carries the stash'
assert_contains "$out" "git clone $bundle1 proj-restored" 'the output prints the restore command'
assert_eq "$(git -C "$repo" for-each-ref)" "$refs_before" 'the repository refs are unchanged'
git clone -q "$bundle1" "$scratch/restored" 2>/dev/null ||
  err "cloning the bundle exited $? — every comparison below would read an empty clone"
assert_eq "$(git -C "$scratch/restored" rev-parse refs/remotes/origin/feature/a 2>/dev/null)" \
  "$(git -C "$repo" rev-parse feature/a)" 'the restored clone has feature/a'
assert_eq "$(git -C "$scratch/restored" rev-parse refs/remotes/origin/feature/b 2>/dev/null)" \
  "$(git -C "$repo" rev-parse feature/b)" 'the restored clone has feature/b'
assert_eq "$(git -C "$scratch/restored" rev-parse v1.0 2>/dev/null)" \
  "$(git -C "$repo" rev-parse v1.0)" 'the restored clone has the annotated tag'

section "--name and --ref"
out2="$scratch/out2"
run_in "$repo" --out "$out2" --name=custom >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 '--name= equals form exits 0'
assert_eq "$(count_lines "$(bundles_in "$out2" custom)")" 1 '--name=custom changes the prefix'
out3="$scratch/out3"
run_in "$repo" --out "$out3" --name proj --ref main >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 '--ref main exits 0'
git clone -q "$(bundles_in "$out3" proj)" "$scratch/main-only" 2>/dev/null
assert_eq "$(git -C "$scratch/main-only" rev-parse refs/remotes/origin/main 2>/dev/null)" \
  "$(git -C "$repo" rev-parse main)" 'a --ref main bundle restores main'
git -C "$scratch/main-only" rev-parse --verify --quiet refs/remotes/origin/feature/a >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 'a --ref main bundle does not carry feature/a'
run_in "$repo" --out "$scratch/out4" --ref nope >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'a --ref that does not exist -> 4'
if [[ -e "$scratch/out4" ]]; then
  err 'a missing --ref still created the output directory'
else
  ok 'a missing --ref creates nothing'
fi

seed_dir() {
  mkdir -p "$1" &&
    cp "$bundle1" "$1/proj-20200101T000000Z.bundle" &&
    cp "$bundle1" "$1/proj-20200102T000000Z.bundle" &&
    cp "$bundle1" "$1/proj-20200103T000000Z.bundle" &&
    cp "$bundle1" "$1/other-20200101T000000Z.bundle" &&
    cp "$bundle1" "$1/notes.bundle"
}

section "retention lists before it deletes"
out5="$scratch/out5"
seed_dir "$out5" || err 'seed the retention directory'
out="$(run_in "$repo" --out "$out5" --name proj --keep 2 2>&1)"; rc=$?
assert_eq "$rc" 0 '--keep without --yes exits 0'
assert_contains "$out" "would prune (pass --yes to delete): $out5/proj-20200101T000000Z.bundle" 'the oldest bundle is listed'
assert_contains "$out" "would prune (pass --yes to delete): $out5/proj-20200102T000000Z.bundle" 'the second oldest bundle is listed'
assert_not_contains "$out" 'proj-20200103T000000Z.bundle' 'the newest old bundle is kept'
assert_not_contains "$out" 'other-' 'another prefix is never listed'
assert_not_contains "$out" 'notes.bundle' 'an unrelated file is never listed'
for f in proj-20200101T000000Z.bundle proj-20200102T000000Z.bundle proj-20200103T000000Z.bundle \
  other-20200101T000000Z.bundle notes.bundle; do
  if [[ -f "$out5/$f" ]]; then ok "without --yes $f is still there"; else err "without --yes $f was deleted"; fi
done

section "retention with --yes"
out6="$scratch/out6"
seed_dir "$out6" || err 'seed the second retention directory'
out="$(run_in "$repo" --out "$out6" --name proj --keep 2 --yes 2>&1)"; rc=$?
assert_eq "$rc" 0 '--keep --yes exits 0'
assert_contains "$out" "pruned: $out6/proj-20200101T000000Z.bundle" 'the deletion is reported'
for f in proj-20200101T000000Z.bundle proj-20200102T000000Z.bundle; do
  if [[ -e "$out6/$f" ]]; then err "--yes left $f"; else ok "--yes deleted $f"; fi
done
for f in proj-20200103T000000Z.bundle other-20200101T000000Z.bundle notes.bundle; do
  if [[ -f "$out6/$f" ]]; then ok "--yes kept $f"; else err "--yes deleted $f"; fi
done
assert_eq "$(count_lines "$(bundles_in "$out6" proj)")" 2 'the newest old bundle and the new one remain'
run_in "$repo" --out "$out6" --keep 0 >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--keep 0 -> 3'
run_in "$repo" --out "$out6" --keep abc >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--keep abc -> 3'
run_in "$repo" --out "$out6" --yes >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--yes without --keep -> 3'

section "dry run"
out7="$scratch/out7"
out="$(run_in "$repo" --out "$out7" --dry-run 2>&1)"; rc=$?
assert_eq "$rc" 0 '--dry-run exits 0'
assert_contains "$out" 'dry-run: would run: git bundle create' '--dry-run previews the bundle'
assert_contains "$out" 'dry-run: would run: git bundle verify' '--dry-run previews the verify'
assert_contains "$out" 'dry-run complete; no changes written' '--dry-run closes with the summary line'
if [[ ! -e "$out7" ]]; then ok '--dry-run does not even create the output directory'; else err '--dry-run created the output directory'; fi
out8="$scratch/out8"
seed_dir "$out8" || err 'seed the dry-run directory'
tree_before="$(find "$out8" | sort)"
out="$(run_in "$repo" --out "$out8" --name proj --keep 1 --yes --dry-run 2>&1)"; rc=$?
assert_eq "$rc" 0 '--dry-run with --keep --yes exits 0'
assert_contains "$out" 'dry-run: would run: rm' '--dry-run previews the deletions'
assert_eq "$(find "$out8" | sort)" "$tree_before" '--dry-run with --keep --yes deletes and writes nothing'
home_tree="$(find "$HOME" | sort)"
out="$(run_in "$repo" --dry-run 2>&1)"; rc=$?
assert_eq "$rc" 0 'a bare --dry-run exits 0'
assert_contains "$out" "$HOME/git-bundles" 'the default output directory is under HOME'
assert_eq "$(find "$HOME" | sort)" "$home_tree" 'a bare --dry-run writes nothing under HOME'

section "nothing to back up, bad output, usage"
git init -q -b main "$scratch/empty" || err 'create empty repository'
run_in "$scratch/empty" --out "$scratch/out9" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 'a repository with no refs -> 4'
if [[ -e "$scratch/out9" ]]; then err 'an empty repository still created the output directory'; else ok 'an empty repository creates nothing'; fi
printf 'not a directory\n' >"$scratch/a-file"
run_in "$repo" --out "$scratch/a-file" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 2 '--out naming a regular file -> 2'
run_in "$repo" --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'unknown flag -> 3'
run_in "$repo" --out >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 '--out without a value -> 3'
run_in "$repo" --name 'bad name' >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 'a --name with a space -> 3'
mkdir -p "$scratch/plain" || err 'create plain directory'
(cd "$scratch/plain" && GIT_CEILING_DIRECTORIES="$scratch" "$BUNDLE_BACKUP" --out "$scratch/out10") >/dev/null 2>&1; rc=$?
assert_eq "$rc" 2 'outside a repository -> 2'

end_section
if (( checks == 0 || failures > 0 )); then
  printf '=== %s of %s bundle backup checks failed ===\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s bundle backup checks passed ===\n' "$checks"

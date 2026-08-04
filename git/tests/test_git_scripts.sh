#!/usr/bin/env bash
# Run from the Linux tester container; repo root is mounted read-only at /repo.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
G="$REPO_ROOT/git"
GACP="$G/gacp.sh"
SET="$G/set_git_profile.sh"
WHO="$G/git_whoami.sh"
STATUS="$G/git_status_summary.sh"
SYNC="$G/git_sync_default.sh"
CLEANUP="$G/git_cleanup_merged.sh"
RECENT="$G/git_recent_branches.sh"
ROOT="$G/git_repo_root.sh"
DIFFBR="$G/git_diff_branch.sh"
UNDO="$G/git_undo_last_commit.sh"
AMEND="$G/git_amend_last.sh"
HOOKS="$G/git_hooks_install.sh"

if [[ ! -d "$G" ]]; then
  echo "expected git scripts at $G" >&2
  exit 1
fi

failures=0
ok() { echo "[ ok ] $*"; }
err() { echo "[fail] $*" >&2; failures=$((failures + 1)); }

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "$needle" <<<"$haystack"; then
    ok "$label"
  else
    err "$label: expected output to contain '$needle'; got: $haystack"
  fi
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"

  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    err "$label: expected '$expected', got '$actual'"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "$needle" <<<"$haystack"; then
    err "$label: expected output not to contain '$needle'; got: $haystack"
  else
    ok "$label"
  fi
}

new_home() {
  mktemp -d /tmp/git-profile-home.XXXXXX
}

new_repo() {
  local repo
  repo="$(mktemp -d /tmp/git-script-repo.XXXXXX)"
  git init -q -b main "$repo"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.com"
  printf "initial\n" >"$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -m "initial commit" >/dev/null
  printf "%s\n" "$repo"
}

run_with_home() {
  local home_dir="$1"
  shift
  HOME="$home_dir" XDG_CONFIG_HOME="$home_dir/.config" "$@"
}

# --- static checks ---
# Discovered rather than listed. A hardcoded array only covers a new script if
# someone remembers to add it, and the macOS suite proves how that ends: its
# list has silently never included brewfile.sh or launchd/stay_fresh_agent.sh.
# Built without mapfile so this still runs under Bash 3.2 (see CONTRIBUTING.md).
sh_scripts=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  sh_scripts+=("$f")
done < <(find "$G" -maxdepth 1 -name '*.sh' -type f | sort)

if (( ${#sh_scripts[@]} == 0 )); then
  echo "discovered no scripts under $G — discovery is broken" >&2
  exit 1
fi
ok "discovered ${#sh_scripts[@]} scripts under git/"
for f in "${sh_scripts[@]}"; do
  rel="${f#"$REPO_ROOT/"}"
  if bash -n "$f"; then
    ok "bash -n $rel"
  else
    err "bash -n $rel"
  fi

  if shellcheck --severity=error -x -s bash "$f"; then
    ok "shellcheck $rel"
  else
    err "shellcheck $rel"
  fi
done

set +e
sc_err="$(shellcheck --severity=error -s zsh "$G/git_aliases.zsh" 2>&1)"
sc_rc=$?
set -e
if [[ "$sc_rc" -eq 0 ]]; then
  ok "shellcheck git/git_aliases.zsh"
elif grep -q "Unknown shell" <<<"$sc_err"; then
  ok "shellcheck git/git_aliases.zsh skipped (no zsh in this shellcheck build)"
else
  echo "$sc_err" >&2
  err "shellcheck git/git_aliases.zsh"
fi

# --- help and validation ---
for f in "${sh_scripts[@]}"; do
  rel="${f#"$G/"}"
  if "$f" --help >/dev/null; then ok "$rel --help"; else err "$rel --help"; fi
done

repo="$(new_repo)"
if (cd "$repo" && "$WHO" >/dev/null); then ok "git_whoami.sh runs inside repo"; else err "git_whoami.sh runs inside repo"; fi
if zsh -f -c "source '$G/git_aliases.zsh'; alias gacp | grep -Fq '$G/gacp.sh'"; then
  ok "git_aliases.zsh defines gacp"
else
  err "git_aliases.zsh defines gacp"
fi

home="$(new_home)"
set +e
out="$(run_with_home "$home" "$SET" --definitely-invalid 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 3 ]]; then ok "unknown flag -> exit 3"; else err "unknown flag: expected exit 3, got $rc: $out"; fi

for flag in --name --email --profile --save --save-current --state-file; do
  home="$(new_home)"
  set +e
  out="$(run_with_home "$home" "$SET" "$flag" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 3 ]]; then
    ok "$flag without value -> exit 3"
  else
    err "$flag without value: expected exit 3, got $rc: $out"
  fi
  assert_contains "$out" "$flag requires a value" "$flag without value explains error"
done

# --- direct global set ---
home="$(new_home)"
out="$(run_with_home "$home" "$SET" --name "Sergey" --email "sergey@example.com")"
assert_contains "$out" "Git global profile updated" "direct set reports success"
actual_name="$(run_with_home "$home" git config --global --get user.name)"
actual_email="$(run_with_home "$home" git config --global --get user.email)"
assert_eq "$actual_name" "Sergey" "direct set writes user.name"
assert_eq "$actual_email" "sergey@example.com" "direct set writes user.email"

# --- save named profile and apply it ---
home="$(new_home)"
state="$home/.config/pretty-useful-scripts/git-profiles.conf"
out="$(run_with_home "$home" "$SET" --save personal --name "Sergey" --email "sergey@example.com")"
assert_contains "$out" "saved Git profile 'personal'" "save profile reports success"
saved_name="$(run_with_home "$home" git config --file "$state" --get profile.personal.name)"
saved_email="$(run_with_home "$home" git config --file "$state" --get profile.personal.email)"
assert_eq "$saved_name" "Sergey" "save profile writes name to state"
assert_eq "$saved_email" "sergey@example.com" "save profile writes email to state"

out="$(run_with_home "$home" "$SET" --profile personal)"
assert_contains "$out" "applying saved Git profile: personal" "apply profile reports profile"
actual_name="$(run_with_home "$home" git config --global --get user.name)"
actual_email="$(run_with_home "$home" git config --global --get user.email)"
assert_eq "$actual_name" "Sergey" "apply profile writes user.name"
assert_eq "$actual_email" "sergey@example.com" "apply profile writes user.email"

out="$(run_with_home "$home" "$SET" --list)"
assert_contains "$out" "personal: Sergey <sergey@example.com>" "list shows saved profile"

# --- save current identity as named profile ---
home="$(new_home)"
run_with_home "$home" git config --global user.name "Work Sergey"
run_with_home "$home" git config --global user.email "work@example.com"
state="$home/.config/pretty-useful-scripts/git-profiles.conf"
out="$(run_with_home "$home" "$SET" --save-current work)"
assert_contains "$out" "saved current Git profile as 'work'" "save-current reports success"
saved_name="$(run_with_home "$home" git config --file "$state" --get profile.work.name)"
saved_email="$(run_with_home "$home" git config --file "$state" --get profile.work.email)"
assert_eq "$saved_name" "Work Sergey" "save-current writes name"
assert_eq "$saved_email" "work@example.com" "save-current writes email"

# --- dry-run must not write state or global config ---
home="$(new_home)"
state="$home/.config/pretty-useful-scripts/git-profiles.conf"
out="$(run_with_home "$home" "$SET" --dry-run --save personal --name "Dry Sergey" --email "dry@example.com")"
assert_contains "$out" "dry-run: would save profile 'personal'" "dry-run save previews state write"
assert_contains "$out" "dry-run complete; no changes written" "dry-run save reports no writes"
assert_not_contains "$out" "saved Git profile 'personal'" "dry-run save does not report saved"
if [[ ! -e "$state" ]]; then ok "dry-run save does not create state file"; else err "dry-run save created state file"; fi

run_with_home "$home" git config --global user.name "Before"
run_with_home "$home" git config --global user.email "before@example.com"
run_with_home "$home" "$SET" --save personal --name "After" --email "after@example.com" >/dev/null
out="$(run_with_home "$home" "$SET" --dry-run --profile personal)"
assert_contains "$out" "dry-run: would run: git config --global user.name \"After\"" "dry-run apply previews name write"
assert_contains "$out" "dry-run complete; no changes written" "dry-run apply reports no writes"
assert_not_contains "$out" "Git global profile updated" "dry-run apply does not report updated"
actual_name="$(run_with_home "$home" git config --global --get user.name)"
actual_email="$(run_with_home "$home" git config --global --get user.email)"
assert_eq "$actual_name" "Before" "dry-run apply keeps existing user.name"
assert_eq "$actual_email" "before@example.com" "dry-run apply keeps existing user.email"

out="$(run_with_home "$home" "$SET" --dry-run --name "Direct Dry" --email "direct-dry@example.com")"
assert_contains "$out" "dry-run: would run: git config --global user.name \"Direct Dry\"" "dry-run direct set previews name write"
assert_contains "$out" "dry-run complete; no changes written" "dry-run direct set reports no writes"
assert_not_contains "$out" "Git global profile updated" "dry-run direct set does not report updated"
actual_name="$(run_with_home "$home" git config --global --get user.name)"
actual_email="$(run_with_home "$home" git config --global --get user.email)"
assert_eq "$actual_name" "Before" "dry-run direct set keeps existing user.name"
assert_eq "$actual_email" "before@example.com" "dry-run direct set keeps existing user.email"

# --- missing saved profile ---
home="$(new_home)"
set +e
out="$(run_with_home "$home" "$SET" --profile missing 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 4 ]]; then ok "missing profile -> exit 4"; else err "missing profile: expected exit 4, got $rc: $out"; fi

# --- gacp ---
repo="$(new_repo)"
printf "dry\n" >>"$repo/file.txt"
before_head="$(git -C "$repo" rev-parse HEAD)"
out="$(cd "$repo" && "$GACP" --dry-run -m "dry commit")"
assert_contains "$out" "dry-run: would run: git add --all" "gacp dry-run previews add"
assert_contains "$out" "dry-run: would run: git commit -m" "gacp dry-run previews commit"
assert_contains "$out" "dry-run complete; no changes written" "gacp dry-run reports no writes"
after_head="$(git -C "$repo" rev-parse HEAD)"
assert_eq "$after_head" "$before_head" "gacp dry-run keeps HEAD"

out="$(cd "$repo" && "$GACP" --no-push -m "local commit")"
assert_contains "$out" "committed without push: local commit" "gacp can commit without push"
last_subject="$(git -C "$repo" log -1 --format=%s)"
assert_eq "$last_subject" "local commit" "gacp writes commit message"

remote="$(mktemp -d /tmp/gacp-remote.XXXXXX)/origin.git"
work="$(mktemp -d /tmp/gacp-work.XXXXXX)"
git init -q --bare -b main "$remote"
git clone -q "$remote" "$work" 2>/dev/null
git -C "$work" switch -q -c main
git -C "$work" config user.name "Test User"
git -C "$work" config user.email "test@example.com"
printf "one\n" >"$work/file.txt"
git -C "$work" add file.txt
git -C "$work" commit -m "initial" >/dev/null
git -C "$work" push -q -u origin main
printf "two\n" >>"$work/file.txt"
out="$(cd "$work" && "$GACP" -m "push commit")"
assert_contains "$out" "committed and pushed: push commit" "gacp commits and pushes"
remote_subject="$(git --git-dir="$remote" log -1 --format=%s main)"
assert_eq "$remote_subject" "push commit" "gacp updates remote branch"

repo="$(new_repo)"
set +e
out="$(cd "$repo" && "$GACP" -m "nothing to do" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 4 ]]; then ok "gacp clean tree -> exit 4"; else err "gacp clean tree: expected exit 4, got $rc: $out"; fi

repo="$(new_repo)"
git -C "$repo" switch -q --detach HEAD
printf "detached\n" >>"$repo/file.txt"
set +e
out="$(cd "$repo" && "$GACP" -m "from detached" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 5 ]]; then ok "gacp detached HEAD with push -> exit 5"; else err "gacp detached HEAD: expected exit 5, got $rc: $out"; fi

# --- status summary ---
repo="$(new_repo)"
printf "dirty\n" >>"$repo/file.txt"
printf "new\n" >"$repo/new.txt"
out="$(cd "$repo" && "$STATUS")"
assert_contains "$out" "branch:    main" "status summary shows branch"
assert_contains "$out" "changed:   2" "status summary counts changed files"
assert_contains "$out" "unstaged:  1" "status summary counts unstaged files"
assert_contains "$out" "untracked: 1" "status summary counts untracked files"

# --- cleanup merged branches ---
repo="$(new_repo)"
git -C "$repo" switch -q -c merged-feature
printf "merged\n" >>"$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -m "merged feature" >/dev/null
git -C "$repo" switch -q main
git -C "$repo" merge -q --ff-only merged-feature
git -C "$repo" switch -q -c unmerged-feature
printf "unmerged\n" >"$repo/unmerged.txt"
git -C "$repo" add unmerged.txt
git -C "$repo" commit -m "unmerged feature" >/dev/null
git -C "$repo" switch -q main

out="$(cd "$repo" && "$CLEANUP" --dry-run --base main)"
assert_contains "$out" "dry-run: would delete branch: merged-feature" "cleanup dry-run previews merged branch"
if git -C "$repo" show-ref --verify --quiet refs/heads/merged-feature; then ok "cleanup dry-run keeps merged branch"; else err "cleanup dry-run deleted merged branch"; fi

out="$(cd "$repo" && "$CLEANUP" --base main)"
assert_contains "$out" "deleted 1 merged local branch(es)" "cleanup deletes merged branch"
if ! git -C "$repo" show-ref --verify --quiet refs/heads/merged-feature; then ok "cleanup removed merged branch"; else err "cleanup did not remove merged branch"; fi
if git -C "$repo" show-ref --verify --quiet refs/heads/unmerged-feature; then ok "cleanup keeps unmerged branch"; else err "cleanup removed unmerged branch"; fi

# --- recent branches ---
repo="$(new_repo)"
git -C "$repo" switch -q -c alpha
printf "alpha\n" >"$repo/alpha.txt"
git -C "$repo" add alpha.txt
git -C "$repo" commit -m "alpha branch" >/dev/null
git -C "$repo" switch -q main
git -C "$repo" switch -q -c beta
printf "beta\n" >"$repo/beta.txt"
git -C "$repo" add beta.txt
git -C "$repo" commit -m "beta branch" >/dev/null

out="$(cd "$repo" && "$RECENT" --limit 2)"
assert_contains "$out" "Recent local branches:" "recent branches prints header"
assert_contains "$out" "beta" "recent branches includes beta"
out="$(cd "$repo" && "$RECENT" --switch 2)"
assert_contains "$out" "switched to" "recent branches can switch by index"

# --- sync default branch with local bare remote ---
remote="$(mktemp -d /tmp/git-script-remote.XXXXXX)/origin.git"
seed="$(mktemp -d /tmp/git-script-seed.XXXXXX)"
work="$(mktemp -d /tmp/git-script-work.XXXXXX)"
updater="$(mktemp -d /tmp/git-script-updater.XXXXXX)"
git init -q --bare -b main "$remote"
git init -q -b main "$seed"
git -C "$seed" config user.name "Test User"
git -C "$seed" config user.email "test@example.com"
printf "one\n" >"$seed/file.txt"
git -C "$seed" add file.txt
git -C "$seed" commit -m "one" >/dev/null
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q -u origin main
git -C "$remote" symbolic-ref HEAD refs/heads/main
git clone -q --branch main "$remote" "$work"
git clone -q --branch main "$remote" "$updater"
git -C "$updater" config user.name "Test User"
git -C "$updater" config user.email "test@example.com"
printf "two\n" >>"$updater/file.txt"
git -C "$updater" add file.txt
git -C "$updater" commit -m "two" >/dev/null
git -C "$updater" push -q origin main

before_head="$(git -C "$work" rev-parse HEAD)"
out="$(cd "$work" && "$SYNC" --dry-run --branch main)"
assert_contains "$out" "dry-run: would run: git fetch origin main" "sync dry-run previews fetch"
after_dry_head="$(git -C "$work" rev-parse HEAD)"
assert_eq "$after_dry_head" "$before_head" "sync dry-run keeps HEAD"

out="$(cd "$work" && "$SYNC" --branch main)"
assert_contains "$out" "synced main with origin/main" "sync fast-forwards default branch"
after_sync_head="$(git -C "$work" rev-parse HEAD)"
remote_head="$(git -C "$updater" rev-parse HEAD)"
assert_eq "$after_sync_head" "$remote_head" "sync updates HEAD to remote"

# --- repo root ---
repo="$(new_repo)"
mkdir -p "$repo/nested/dir"
got="$(cd "$repo/nested/dir" && "$ROOT")"
assert_eq "$got" "$repo" "git_repo_root prints toplevel from subdirectory"

# --- diff branch ---
repo="$(new_repo)"
git -C "$repo" switch -q -c feature
printf "extra\n" >"$repo/feature.txt"
git -C "$repo" add feature.txt
git -C "$repo" commit -m "feature commit" >/dev/null
out="$(cd "$repo" && "$DIFFBR" --stat --base main)"
assert_contains "$out" "feature.txt" "git_diff_branch shows new file in stat"

# --- undo last commit ---
repo="$(new_repo)"
printf "second\n" >>"$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -m "second commit" >/dev/null
parent="$(git -C "$repo" rev-parse HEAD~1)"
before_undo="$(git -C "$repo" rev-parse HEAD)"
out="$(cd "$repo" && "$UNDO" --dry-run)"
assert_contains "$out" "git reset --soft HEAD~1" "undo dry-run shows soft reset"
after_dry="$(git -C "$repo" rev-parse HEAD)"
assert_eq "$after_dry" "$before_undo" "undo dry-run keeps HEAD"
(cd "$repo" && "$UNDO") >/dev/null
after_undo="$(git -C "$repo" rev-parse HEAD)"
assert_eq "$after_undo" "$parent" "undo soft moves HEAD to parent"

repo="$(new_repo)"
set +e
out="$(cd "$repo" && "$UNDO" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 4 ]]; then ok "undo with single commit -> exit 4"; else err "undo single commit: expected exit 4, got $rc: $out"; fi

# --- amend last ---
repo="$(new_repo)"
printf "amendment\n" >>"$repo/file.txt"
(cd "$repo" && "$AMEND" --add-all) >/dev/null
count="$(git -C "$repo" rev-list --count HEAD)"
assert_eq "$count" "1" "amend keeps single commit"
last_line="$(git -C "$repo" show -s --format=%B HEAD | head -1)"
assert_eq "$last_line" "initial commit" "amend preserves commit message"
assert_contains "$(git -C "$repo" show --stat HEAD)" "file.txt" "amend includes file change"

repo="$(new_repo)"
set +e
out="$(cd "$repo" && "$AMEND" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 4 ]]; then ok "amend without staged changes -> exit 4"; else err "amend empty: expected exit 4, got $rc: $out"; fi

# --- git_hooks_install.sh ---
# The hook must judge the *staged blob*, never the working tree. The first
# version of it read the working tree, which failed in both directions: a
# private key staged and then deleted from disk was committed, and a clean
# staged file whose worktree copy had since gained a conflict marker was
# blocked. Both are asserted below because neither is caught by any check that
# only ever stages and commits in one step.
commit_rc() {
  local repo="$1" msg="$2" rc
  set +e
  git -C "$repo" commit -q -m "$msg" >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

repo="$(new_repo)"
out="$(cd "$repo" && "$HOOKS" install 2>&1)"
assert_contains "$out" "installed pre-commit hook" "hooks install reports success"
if [[ -x "$repo/.git/hooks/pre-commit" ]]; then
  ok "hooks install wrote an executable hook"
else
  err "hooks install left no executable hook"
fi

out="$(cd "$repo" && "$HOOKS" status 2>&1)"
assert_contains "$out" "installed and current" "hooks status reports current"

# The hook body must survive the installer going away, which is the reason it
# is embedded rather than copied from a path on disk.
assert_not_contains "$(cat "$repo/.git/hooks/pre-commit")" "$HOOKS" \
  "the installed hook does not reference the installer's path"

printf 'a\n<<<<<<< HEAD\n' >"$repo/bad.txt"
git -C "$repo" add bad.txt
assert_eq "$(commit_rc "$repo" "marker")" "1" "staged conflict marker is refused"
git -C "$repo" reset -q; rm -f "$repo/bad.txt"

# Prose is not a conflict. A hook with false positives gets --no-verify'd once
# and then never runs again, so this matters as much as the catch above.
printf 'use <<< for here-strings, and <<<<<<<<<<< as a rule\n' >"$repo/prose.txt"
git -C "$repo" add prose.txt
assert_eq "$(commit_rc "$repo" "prose")" "0" "prose containing <<< is allowed"

# Staged, then removed from disk: the working tree cannot answer this.
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nx\n' >"$repo/leak.pem"
git -C "$repo" add leak.pem
rm -f "$repo/leak.pem"
assert_eq "$(commit_rc "$repo" "key")" "1" "a staged private key is refused even with no file on disk"
git -C "$repo" reset -q

# Clean in the index, dirty in the working tree: must not block.
printf 'clean\n' >"$repo/notes.txt"
git -C "$repo" add notes.txt
printf 'clean\n<<<<<<< HEAD\n' >"$repo/notes.txt"
assert_eq "$(commit_rc "$repo" "clean index")" "0" "an unstaged conflict marker does not block the commit"

# 2 MB, comfortably over the 1024 KB default.
head -c 2000000 /dev/zero >"$repo/big.bin"
git -C "$repo" add big.bin
assert_eq "$(commit_rc "$repo" "big")" "1" "a staged file over --max-size is refused"
out="$(cd "$repo" && "$HOOKS" install --force --max-size 4096 2>&1)"
assert_contains "$out" "max-size 4096" "--max-size is reflected in the installed hook"
assert_eq "$(commit_rc "$repo" "big under raised limit")" "0" "the same file passes once --max-size allows it"

# A hook this script did not write is somebody else's; clobbering it silently
# would be the worst thing an installer can do.
repo="$(new_repo)"
printf '#!/bin/sh\nexit 0\n' >"$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
set +e
out="$(cd "$repo" && "$HOOKS" install 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "install refuses to clobber a foreign hook -> exit 1"
assert_contains "$(cat "$repo/.git/hooks/pre-commit")" "exit 0" "the foreign hook is left untouched"

(cd "$repo" && "$HOOKS" install --force) >/dev/null
if [[ -f "$repo/.git/hooks/pre-commit.hooks-install-backup" ]]; then
  ok "--force backs the foreign hook up"
else
  err "--force did not back the foreign hook up"
fi
(cd "$repo" && "$HOOKS" uninstall) >/dev/null
assert_contains "$(cat "$repo/.git/hooks/pre-commit")" "exit 0" "uninstall restores the backed-up hook"

# The restored hook is now foreign again, so a second uninstall must refuse it
# rather than delete somebody else's work.
set +e
(cd "$repo" && "$HOOKS" uninstall) >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "uninstall refuses to remove a hook it did not install"

repo="$(new_repo)"
set +e
(cd "$repo" && "$HOOKS" uninstall) >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "4" "uninstall with nothing installed -> exit 4"

out="$(cd "$repo" && "$HOOKS" install --dry-run 2>&1)"
assert_contains "$out" "no changes written" "hooks install --dry-run says so"
if [[ -e "$repo/.git/hooks/pre-commit" ]]; then
  err "install --dry-run wrote a hook"
else
  ok "install --dry-run wrote nothing"
fi

if (( failures )); then
  echo "=== $failures test(s) failed ===" >&2
  exit 1
fi

echo "=== all git script (docker) checks passed ==="

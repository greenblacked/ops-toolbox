#!/usr/bin/env bash
# Delete local branches whose upstream has been deleted on the remote.

set -euo pipefail

DRY_RUN=0
REMOTE="origin"
FORCE=0
ALLOW_UNMERGED=0
NO_FETCH=0
INCLUDES=()
EXCLUDES=()

usage() {
  cat <<EOF
git_prune_gone.sh - delete local branches whose upstream is gone

Companion to git_cleanup_merged.sh, which only sees branches merged with a
real merge commit. A squash-merged or rebase-merged pull request leaves no
such commit, so its branch is never "merged" locally and that script will
never touch it — which is most branches on most projects. This one keys off
the remote instead: once the forge deletes the branch after merging, its
local counterpart is left tracking something that no longer exists, and that
is the signal to clean up.

Tips not reachable from HEAD require --allow-unmerged: a deleted upstream
alone does not prove a squash/rebase merge or distinguish abandoned work.
--force only overrides protected names; it does not grant this consent.

Before any deletion, every candidate tip is saved under a durable recovery ref
and printed as a full SHA with a restore command. Recovery refs survive reflog
expiry and garbage collection. At most 1,000 distinct branch/tip recovery refs
are retained; a full store refuses new deletions until you explicitly clean it.
Refs never expire automatically. See git/README.md for cleanup and lock recovery.

Usage:
  $(basename "$0") [--dry-run] [--remote origin] [--no-fetch] [--include GLOB] [--exclude GLOB] [--force] [--allow-unmerged]

Options:
  --dry-run       Show branches that would be deleted
  --remote NAME   Only consider upstreams on this remote (default: origin)
  --no-fetch      Skip 'git fetch --prune'; use the refs already on disk
  --include GLOB  Only consider matching branches (repeatable)
  --exclude GLOB  Skip matching branches (repeatable)
  --force         Also delete protected-looking names such as develop
  --allow-unmerged  Allow tips not reachable from HEAD (e.g. squash merges)
  --help, -h      Show this help

Exit codes: 0 success, 1 recovery could not be prepared or a deletion failed, 2 not a git repo,
3 usage, 4 remote not found
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --remote)
      require_value "$1" "${2:-}"
      shift
      REMOTE="$1"
      ;;
    --remote=*)
      REMOTE="${1#*=}"
      require_value "--remote" "$REMOTE"
      ;;
    --no-fetch)
      NO_FETCH=1
      ;;
    --allow-unmerged)
      ALLOW_UNMERGED=1
      ;;
    --force)
      FORCE=1
      ;;
    --include)
      require_value "$1" "${2:-}"
      shift
      INCLUDES+=("$1")
      ;;
    --include=*)
      value="${1#*=}"
      require_value "--include" "$value"
      INCLUDES+=("$value")
      ;;
    --exclude)
      require_value "$1" "${2:-}"
      shift
      EXCLUDES+=("$1")
      ;;
    --exclude=*)
      value="${1#*=}"
      require_value "--exclude" "$value"
      EXCLUDES+=("$value")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf "unknown argument: %s\n" "$1" >&2
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  printf "remote not found: %s\n" "$REMOTE" >&2
  exit 4
fi

# Without this the upstream refs still look alive and nothing is ever found.
# --no-fetch exists for working offline, and for tests.
if (( NO_FETCH == 0 )); then
  if (( DRY_RUN == 1 )); then
    printf "dry-run: would run: git fetch --prune %s\n" "$REMOTE"
    printf "dry-run: preview uses current refs; no remote-tracking refs were changed\n"
  else
    git fetch --prune "$REMOTE"
  fi
fi

current_branch="$(git branch --show-current)"
protected_regex='^(main|master|develop|development|dev|staging|stage|production|prod|release)$'
recovery_prefix="refs/ops-toolbox/prune-gone"
recovery_limit=1000
branches=()
shas=()
recovery_refs=()
removed=0
failed=0

branch_selected() {
  local branch="$1" pattern matched
  matched=0
  if (( ${#INCLUDES[@]} == 0 )); then
    matched=1
  else
    for pattern in ${INCLUDES[@]+"${INCLUDES[@]}"}; do
      [[ "$branch" == $pattern ]] && { matched=1; break; }
    done
  fi
  (( matched == 1 )) || return 1
  for pattern in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    [[ "$branch" == $pattern ]] && return 1
  done
  return 0
}

branch_in_worktree() {
  local branch="$1" line
  # Capture first so a failed listing cannot silently make every branch eligible.
  local worktrees
  worktrees="$(git worktree list --porcelain)" || return 2
  while IFS= read -r line; do
    [[ "$line" == "branch refs/heads/$branch" ]] && return 0
  done <<< "$worktrees"
  return 1
}

common_dir="$(git rev-parse --git-common-dir)"
git_operation_active() {
  local state_dir
  # Rebase/bisect can detach HEAD while reserving branches, including additional
  # --update-refs branches. Conservatively pause the whole run instead of
  # reproducing Git's internal branch reservation parser. Metadata for all
  # linked worktrees is under the common directory, independent of their paths.
  for state_dir in "$common_dir" "$common_dir"/worktrees/*; do
    [[ -d "$state_dir" ]] || continue
    if [[ -e "$state_dir/rebase-merge" || -e "$state_dir/rebase-apply" || -e "$state_dir/BISECT_START" ]]; then
      return 0
    fi
  done
  return 1
}
if git_operation_active; then
  printf "skip pruning: rebase or bisect is active in a worktree\n"
  if (( DRY_RUN == 1 )); then
    printf "dry-run complete; no changes written\n"
  fi
  exit 0
fi

# Real invocations serialize capacity checks and recovery transactions across
# linked worktrees. A crashed run leaves an empty lock directory: fail closed
# until an operator confirms no run is active and removes it (see README).
lock_dir=""
release_lock() {
  if [[ -n "$lock_dir" ]]; then
    rmdir "$lock_dir" || printf "warning: could not release prune lock: %s\n" "$lock_dir" >&2
  fi
}
if (( DRY_RUN == 0 )); then
  prune_lock="$common_dir/ops-toolbox-prune-gone.lock"
  if ! mkdir "$prune_lock"; then
    printf "cannot acquire prune lock: %s; no branches deleted\n" "$prune_lock" >&2
    exit 1
  fi
  lock_dir="$prune_lock"
  trap release_lock EXIT
  trap 'exit 1' HUP INT TERM
fi

# A gone upstream must belong to the requested remote, including --no-fetch.
# Branch names and SHAs have no spaces; the remote is the last field so its
# value is compared exactly rather than guessed from a tracking-ref prefix.
branch_listing="$(git for-each-ref --format='%(refname:strip=2) %(objectname) %(upstream:track) %(upstream:remotename)' refs/heads)"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  branch="${line%% *}"
  rest="${line#* }"
  sha="${rest%% *}"
  rest="${rest#* }"
  [[ "$rest" == "[gone] $REMOTE" ]] || continue
  # Symbolic branch aliases can resolve to a current or protected branch.
  # Reject aliases; --no-deref also protects against a later alias replacement.
  if git symbolic-ref -q "refs/heads/$branch" >/dev/null; then
    printf "skip symbolic branch: %s\n" "$branch"
    continue
  else
    rc=$?
    if (( rc != 1 )); then
      printf "cannot inspect branch reference; no branches deleted\n" >&2
      exit 1
    fi
  fi
  branch_selected "$branch" || continue

  if [[ "$branch" == "$current_branch" ]]; then
    printf "skip current branch: %s\n" "$branch"
    continue
  fi
  if branch_in_worktree "$branch"; then
    printf "skip worktree branch: %s\n" "$branch"
    continue
  else
    rc=$?
    if (( rc != 1 )); then
      printf "cannot inspect worktrees; no branches deleted\n" >&2
      exit 1
    fi
  fi
  if (( FORCE == 0 )) && [[ "$branch" =~ $protected_regex ]]; then
    printf "skip protected branch: %s\n" "$branch"
    continue
  fi
  if git merge-base --is-ancestor "$sha" HEAD; then
    :
  else
    rc=$?
    if (( rc != 1 )); then
      printf "cannot check reachability of %s; no branches deleted\n" "$branch" >&2
      exit 1
    fi
    if (( ALLOW_UNMERGED == 0 )); then
      printf "skip branch not reachable from HEAD: %s (use --allow-unmerged after review)\n" "$branch"
      continue
    fi
    printf "allow branch not reachable from HEAD: %s\n" "$branch"
  fi

  # Hash the name without -w: no object is written, even during dry-run. The
  # fixed-depth key avoids collisions between branch names such as foo and foo/bar.
  branch_key="$(printf '%s' "$branch" | git hash-object --stdin)"
  branches+=("$branch")
  shas+=("$sha")
  recovery_refs+=("$recovery_prefix/$branch_key/$sha")
done <<< "$branch_listing"

candidates=${#branches[@]}
if (( candidates == 0 )); then
  printf "no eligible local branches with a deleted upstream on %s\n" "$REMOTE"
  if (( DRY_RUN == 1 )); then
    printf "dry-run complete; no changes written\n"
  fi
  exit 0
fi

# Check capacity before writing. Existing exact mappings are reusable; neither
# another invocation nor a failed deletion can overwrite a retained tip.
existing_refs="$(git for-each-ref --format='%(refname) %(objectname)' "$recovery_prefix/")"
recovery_count=0
while IFS= read -r line; do
  [[ -n "$line" ]] && recovery_count=$((recovery_count + 1))
done <<< "$existing_refs"
creates=()
for (( i=0; i<candidates; i++ )); do
  recovery_ref="${recovery_refs[$i]}"
  found=0
  while IFS= read -r line; do
    [[ "${line%% *}" == "$recovery_ref" ]] || continue
    if [[ "${line#* }" != "${shas[$i]}" ]]; then
      printf "recovery ref has an unexpected tip: %s; no branches deleted\n" "$recovery_ref" >&2
      exit 1
    fi
    if git symbolic-ref -q "$recovery_ref" >/dev/null; then
      printf "recovery ref is symbolic: %s; no branches deleted\n" "$recovery_ref" >&2
      exit 1
    else
      rc=$?
      if (( rc != 1 )); then
        printf "cannot inspect recovery reference; no branches deleted\n" >&2
        exit 1
      fi
    fi
    found=1
    break
  done <<< "$existing_refs"
  if (( found == 0 )); then
    creates+=("create $recovery_ref ${shas[$i]}")
  fi
done
if (( recovery_count + ${#creates[@]} > recovery_limit )); then
  printf "recovery ref limit (%s) reached; review and clean retained refs before pruning; no branches deleted\n" "$recovery_limit" >&2
  exit 1
fi

if (( DRY_RUN == 1 )); then
  for command in ${creates[@]+"${creates[@]}"}; do
    printf "dry-run: would run: git update-ref --no-deref --stdin (%s)\n" "$command"
  done
else
  # Save ALL candidate tips atomically before deleting ANY branch. 'create'
  # refuses existing refs, and prepare/commit failures abort the whole batch.
  if (( ${#creates[@]} > 0 )); then
    if ! {
      printf 'start\n'
      printf '%s\n' "${creates[@]}"
      printf 'prepare\ncommit\n'
    } | git update-ref --no-deref --stdin >/dev/null; then
      printf "could not create recovery refs; no branches deleted\n" >&2
      exit 1
    fi
  fi
fi

for (( i=0; i<candidates; i++ )); do
  branch="${branches[$i]}"
  sha="${shas[$i]}"
  recovery_ref="${recovery_refs[$i]}"
  if (( DRY_RUN == 1 )); then
    printf 'dry-run: would run: git update-ref --no-deref -d %q %s (recovery %s)\n' "refs/heads/$branch" "$sha" "$recovery_ref"
    continue
  fi
  printf 'saved %s at %s in %s — restore with: git branch -- %q %s\n' \
    "$branch" "$sha" "$recovery_ref" "$branch" "$sha"
  # Recheck worktrees just before deletion; fail closed if inspection fails.
  # The expected old SHA makes a racing tip update fail rather than deleting
  # commits missing from recovery. Keep branch config for restoration, avoiding
  # unsafe cleanup if another process recreates the branch after deletion.
  if git_operation_active; then
    printf "rebase or bisect started in a worktree; remaining branches preserved\n" >&2
    exit 1
  fi
  if branch_in_worktree "$branch"; then
    printf "skip worktree branch: %s; recovery retained\n" "$branch"
    continue
  else
    rc=$?
    if (( rc != 1 )); then
      printf "cannot inspect worktrees; remaining branches preserved\n" >&2
      exit 1
    fi
  fi
  if git update-ref --no-deref -d "refs/heads/$branch" "$sha"; then
    removed=$((removed + 1))
    printf "deleted %s (was %s)\n" "$branch" "$sha"
  else
    printf "warn: branch changed or could not be deleted: %s; recovery retained\n" "$branch" >&2
    failed=$((failed + 1))
  fi
done

if (( DRY_RUN == 1 )); then
  printf "dry-run complete; no changes written\n"
else
  printf "deleted %s branch(es) whose upstream was gone on %s\n" "$removed" "$REMOTE"
fi
if (( failed > 0 )); then
  printf "warning: failed to delete %s branch(es)\n" "$failed" >&2
  exit 1
fi

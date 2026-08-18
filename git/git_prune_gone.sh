#!/usr/bin/env bash
# Delete local branches whose upstream has been deleted on the remote.

set -euo pipefail

DRY_RUN=0
REMOTE="origin"
FORCE=0
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

Deletion uses 'git branch -D', not -d, and that is not an oversight. A
squash-merged branch is by definition not an ancestor of HEAD — its commits
were replaced by a single new one — so -d refuses it, and screening on
"is it merged" would keep precisely the branches this script exists to
remove.

What makes that safe is recoverability, not caution: every deletion prints
the commit it pointed at and the command to put it back, and the branch stays
in the reflog for gc.reflogExpire (90 days by default). Branches that were
not reachable from HEAD are called out separately in the summary, so an
abandoned branch that was never merged is visible rather than silent.

Usage:
  $(basename "$0") [--dry-run] [--remote origin] [--no-fetch] [--include GLOB] [--exclude GLOB] [--force]

Options:
  --dry-run       Show branches that would be deleted
  --remote NAME   Remote to prune (default: origin)
  --no-fetch      Skip 'git fetch --prune'; use the refs already on disk
  --include GLOB  Only consider matching branches (repeatable)
  --exclude GLOB  Skip matching branches (repeatable)
  --force         Also delete protected-looking names such as develop
  --help, -h      Show this help

Exit codes: 0 success, 1 one or more deletions failed, 2 not a git repo,
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
candidates=0
removed=0
failed=0
unmerged=0

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

# `%(upstream:track)` renders exactly "[gone]" once the upstream is deleted and
# the remote-tracking ref has been pruned. Reading the porcelain here is
# deliberate: there is no plumbing equivalent that reports gone-ness directly.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  branch="${line%% *}"
  track="${line#* }"

  [[ "$track" == "[gone]" ]] || continue
  [[ -n "$branch" ]] || continue
  branch_selected "$branch" || continue

  if [[ "$branch" == "$current_branch" ]]; then
    printf "skip current branch: %s\n" "$branch"
    continue
  fi

  if (( FORCE == 0 )) && [[ "$branch" =~ $protected_regex ]]; then
    printf "skip protected branch: %s\n" "$branch"
    continue
  fi

  # Not a gate — a label. A squash-merged branch lands here too, so refusing
  # on it would defeat the point. It is reported so an abandoned branch is
  # distinguishable from a merged one.
  unreachable=0
  if ! git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
    unreachable=1
    unmerged=$((unmerged + 1))
  fi

  sha="$(git rev-parse --short "$branch")"
  candidates=$((candidates + 1))

  if (( DRY_RUN == 1 )); then
    if (( unreachable == 1 )); then
      printf "dry-run: would run: git branch -D %s  (at %s, not reachable from HEAD)\n" \
        "$branch" "$sha"
    else
      printf "dry-run: would run: git branch -D %s  (at %s)\n" "$branch" "$sha"
    fi
  else
    if git branch -D "$branch" >/dev/null; then
      removed=$((removed + 1))
      printf "deleted %s (was %s) — restore with: git branch %s %s\n" \
        "$branch" "$sha" "$branch" "$sha"
    else
      printf "warn: could not delete branch: %s\n" "$branch" >&2
      failed=$((failed + 1))
    fi
  fi
done < <(git branch --format='%(refname:short) %(upstream:track)')

if (( candidates == 0 )); then
  printf "no local branches with a deleted upstream\n"
elif (( DRY_RUN == 1 )); then
  printf "dry-run complete; no branches deleted\n"
else
  if (( removed > 0 )); then
    printf "deleted %s branch(es) whose upstream was gone\n" "$removed"
  fi
fi

if (( unmerged > 0 )); then
  printf "note: %s of them were not reachable from HEAD — squash-merged work looks\n" "$unmerged"
  printf "      exactly like this, but so does an abandoned branch. Restore commands above.\n"
fi
if (( failed > 0 )); then
  printf "warning: failed to delete %s branch(es)\n" "$failed" >&2
  exit 1
fi

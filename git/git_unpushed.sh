#!/usr/bin/env bash
# List everything in this repository that exists only on this machine.

set -euo pipefail

# --- output ----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_RED=''; C_YELLOW=''; C_BOLD=''; C_DIM=''
fi

err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# --- defaults --------------------------------------------------------------
REMOTE=""
LIMIT=5
TAGS=0
PORCELAIN=0
STRICT=0

usage() {
  cat <<EOF
git_unpushed.sh - everything in this repository that exists only on this machine

The question before reinstalling a laptop, destroying a dev VM or deleting a
clone is "what would I lose?". Git keeps the answer in five places, and this
reports all five:

  commits      commits on local branches that no remote-tracking ref contains
               (and, on a detached HEAD, commits no branch holds either)
  no-upstream  local branches with no upstream configured, even when their
               commits happen to be on a remote already
  stash        stash entries
  uncommitted  changed tracked files and untracked files (ignored files are
               not counted)
  tag          with --tags: local tags the remote does not have, or has at
               a different object

Usage:
  $(basename "$0") [--remote NAME] [--limit N] [--tags] [--porcelain] [--strict]

Options:
  --remote NAME   Count a commit as pushed only when it is on this remote
                  (default: any remote-tracking ref). Also the remote --tags asks.
  --limit N       Subjects listed per branch (default: 5)
  --tags          Also list local tags missing on the remote or
                  pointing at a different object there. The one network
                  call this script makes: 'git ls-remote --tags', read-only.
  --porcelain     Tab-separated rows for scripts: kind name count detail
  --strict        Exit 1 when anything exists only on this machine
  -h, --help      Show this help

Read-only. It does not fetch: remote-tracking refs are only as fresh as the
last fetch, so a commit someone else pushed this morning is not counted as
pushed until 'git fetch' has run. A report that quietly rewrote refs would not
be read-only.

Exit codes: 0 success (whether or not anything was found; a git status that
could not be read does not change that), 1 --strict found something or could
not read git status, or --tags could not reach the remote, 2 not a git repo,
3 usage, 4 no commits yet or remote not found
EOF
}

# Byte-identical to git/git_sync_default.sh — see CONTRIBUTING.md for why
# this is copied rather than sourced from a shared library.
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

require_number() {
  local option="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      printf "%s requires a whole number, got: %s\n" "$option" "$value" >&2
      exit 3
      ;;
  esac
}

# --- arguments -------------------------------------------------------------
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --remote)
      require_value "$1" "${2:-}"; shift; REMOTE="$1" ;;
    --remote=*)
      REMOTE="${1#*=}"; require_value "--remote" "$REMOTE" ;;
    --limit)
      require_value "$1" "${2:-}"; shift; require_number "--limit" "$1"; LIMIT="$1" ;;
    --limit=*)
      LIMIT="${1#*=}"; require_value "--limit" "$LIMIT"; require_number "--limit" "$LIMIT" ;;
    --tags)      TAGS=1 ;;
    --porcelain) PORCELAIN=1 ;;
    --strict)    STRICT=1 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

# Leading zeros must not read as octal inside (( )).
LIMIT=$((10#$LIMIT))

# --- preflight -------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if [[ -n "$REMOTE" ]] && ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  # Checked up front because rev-list takes an unknown --remotes=NAME pattern
  # without complaint, matches nothing, and would report every commit as
  # unpushed.
  printf "remote not found: %s\n" "$REMOTE" >&2
  exit 4
fi

head_exists=0
git rev-parse --verify --quiet HEAD >/dev/null 2>&1 && head_exists=1
if (( head_exists == 0 )) && [[ -z "$(git for-each-ref --count=1 refs/heads)" ]]; then
  printf "no commits yet; there is nothing Git could have pushed\n" >&2
  exit 4
fi

remote_count="$(git remote | wc -l | tr -d ' ')"

tag_remote=""
if (( TAGS == 1 )); then
  if [[ -n "$REMOTE" ]]; then
    tag_remote="$REMOTE"
  elif [[ "$remote_count" == "1" ]]; then
    tag_remote="$(git remote)"
  else
    printf -- "--tags needs to know which remote to ask; pass --remote NAME\n" >&2
    exit 3
  fi
fi

if [[ -n "$REMOTE" ]]; then
  remote_refs=("--remotes=$REMOTE")
  commits_heading="commits not on $REMOTE"
else
  remote_refs=(--remotes)
  commits_heading="commits on no remote"
fi
not_remotes=(--not "${remote_refs[@]}")

# --- collect ---------------------------------------------------------------
commit_total=0
commit_branches=0
noup_total=0
uncommitted_total=0
tag_total=0
tags_failed=0
found_any=0

commit_rows=()
noup_rows=()

# Branch names come from the full refname, never %(refname:short): short names
# turn into heads/NAME when a tag of the same name exists, and every git call
# below takes the full ref so a branch called like a file is never ambiguous.
while IFS=$'\t' read -r ref upstream; do
  [[ -n "$ref" ]] || continue
  branch="${ref#refs/heads/}"
  count="$(git rev-list --count "$ref" "${not_remotes[@]}")"
  if (( count > 0 )); then
    commit_rows+=("$branch")
    commit_total=$((commit_total + count))
    commit_branches=$((commit_branches + 1))
  fi
  if [[ -z "$upstream" ]]; then
    noup_rows+=("$branch")
    noup_total=$((noup_total + 1))
  fi
done < <(git for-each-ref --format=$'%(refname)\t%(upstream)' refs/heads)

# Work committed on a detached HEAD lives on no branch at all, so the loop above
# cannot see it and it is the easiest thing here to lose.
detached_count=0
if (( head_exists == 1 )) && [[ -z "$(git branch --show-current)" ]]; then
  detached_count="$(git rev-list --count HEAD --not --branches "${remote_refs[@]}")"
  if (( detached_count > 0 )); then
    commit_total=$((commit_total + detached_count))
    commit_branches=$((commit_branches + 1))
  fi
fi

stash_count="$(git stash list | wc -l | tr -d ' ')"
stash_subject=""
if (( stash_count > 0 )); then
  stash_subject="$(git stash list -n 1 --format=%gs)"
fi

# --no-optional-locks: a report has no business refreshing the index.
# The output and exit code are captured first: status inside a process
# substitution would hide a failure (corrupt or unreadable index) and report
# a checkout it could not read as having nothing uncommitted.
tracked_changes=0
untracked_paths=0
status_failed=0
status_out=""
if ! status_out="$(git --no-optional-locks status --porcelain=v1 2>/dev/null)"; then
  status_failed=1
  status_out=""
fi
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  case "$line" in
    '?? '*) untracked_paths=$((untracked_paths + 1)) ;;
    *)      tracked_changes=$((tracked_changes + 1)) ;;
  esac
done <<<"$status_out"
uncommitted_total=$((tracked_changes + untracked_paths))

missing_tags=()
if (( TAGS == 1 )); then
  remote_tags=""
  # Not --refs: an annotated tag is listed twice, as the tag object and as
  # NAME^{} (the commit it points at), and both are compared below.
  if listing="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "$tag_remote" 2>/dev/null)"; then
    while IFS=$'\t' read -r sha tag_ref; do
      [[ -n "$tag_ref" ]] || continue
      remote_tags="$remote_tags${tag_ref#refs/tags/} $sha"$'\n'
    done <<<"$listing"
    # A tag counts as pushed only when the remote has the same name at the
    # same object. A tag rewritten locally (moved, or re-annotated) keeps its
    # name, so a name match alone would hide the only copy of the new target.
    while read -r tag oid peeled; do
      [[ -n "$tag" ]] || continue
      # %(*objectname) peels one level, but ls-remote's NAME^{} peels fully
      # (a tag of a tag lists the commit), so peel fully on this side too.
      if [[ -n "$peeled" ]]; then
        peeled="$(git rev-parse -q --verify "refs/tags/$tag^{}" 2>/dev/null)" || peeled="?"
      fi
      # A here-string, not a pipe into grep -q: under pipefail an early exit
      # kills the writer and a match reads as a miss.
      same=1
      grep -Fxq -- "$tag $oid" <<<"$remote_tags" || same=0
      if (( same == 1 )) && [[ -n "$peeled" ]]; then
        # The remote's NAME^{} line when it lists one, else the plain line
        # (already matched above). A listing without peeled lines (a server
        # or proxy that hides them) must not flag a matching tag.
        if [[ $'\n'"$remote_tags" == *$'\n'"$tag^{} "* ]]; then
          grep -Fxq -- "$tag^{} $peeled" <<<"$remote_tags" || same=0
        fi
      fi
      if (( same == 0 )); then
        missing_tags+=("$tag")
        tag_total=$((tag_total + 1))
      fi
    done < <(git for-each-ref --format='%(refname:strip=2) %(objectname) %(*objectname)' refs/tags)
  else
    tags_failed=1
  fi
fi

if (( commit_total > 0 || noup_total > 0 || stash_count > 0 || uncommitted_total > 0 || tag_total > 0 )); then
  found_any=1
fi

# --- report ----------------------------------------------------------------
heading() {
  printf "%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"
}

if (( PORCELAIN == 1 )); then
  for branch in "${commit_rows[@]+"${commit_rows[@]}"}"; do
    count="$(git rev-list --count "refs/heads/$branch" "${not_remotes[@]}")"
    printf "commits\t%s\t%s\t%s\n" "$branch" "$count" \
      "$(git log -1 --format=%s "refs/heads/$branch")"
  done
  if (( detached_count > 0 )); then
    printf "commits\tHEAD\t%s\t%s\n" "$detached_count" "$(git log -1 --format=%s HEAD)"
  fi
  for branch in "${noup_rows[@]+"${noup_rows[@]}"}"; do
    count="$(git rev-list --count "refs/heads/$branch" "${not_remotes[@]}")"
    printf "no-upstream\t%s\t%s\t\n" "$branch" "$count"
  done
  if (( stash_count > 0 )); then
    printf "stash\tstash\t%s\t%s\n" "$stash_count" "$stash_subject"
  fi
  if (( tracked_changes > 0 )); then
    printf "uncommitted\ttracked\t%s\t\n" "$tracked_changes"
  fi
  if (( untracked_paths > 0 )); then
    printf "uncommitted\tuntracked\t%s\t\n" "$untracked_paths"
  fi
  for tag in "${missing_tags[@]+"${missing_tags[@]}"}"; do
    printf "tag\t%s\t1\t%s\n" "$tag" "$tag_remote"
  done
else
  if [[ "$remote_count" == "0" ]]; then
    printf "%sno remotes configured: every commit here exists only on this machine%s\n\n" \
      "$C_YELLOW" "$C_RESET"
  fi

  if (( ${#commit_rows[@]} > 0 || detached_count > 0 )); then
    heading "$commits_heading"
    for branch in "${commit_rows[@]+"${commit_rows[@]}"}"; do
      ref="refs/heads/$branch"
      count="$(git rev-list --count "$ref" "${not_remotes[@]}")"
      newest="$(git log -1 --format='%cr%x09%s' "$ref")"
      printf "  %s%s%s  %s commit(s), newest %s: %s\n" "$C_YELLOW" "$branch" "$C_RESET" \
        "$count" "${newest%%	*}" "${newest#*	}"
      if (( LIMIT > 0 )); then
        git log --format='    %h %s' -n "$LIMIT" "$ref" "${not_remotes[@]}"
      fi
      if (( count > LIMIT )); then
        printf "    %s... and %s more%s\n" "$C_DIM" "$((count - LIMIT))" "$C_RESET"
      fi
    done
    if (( detached_count > 0 )); then
      newest="$(git log -1 --format='%cr%x09%s' HEAD)"
      printf "  %sHEAD (detached)%s  %s commit(s) on no branch, newest %s: %s\n" \
        "$C_YELLOW" "$C_RESET" "$detached_count" "${newest%%	*}" "${newest#*	}"
      if (( LIMIT > 0 )); then
        git log --format='    %h %s' -n "$LIMIT" HEAD --not --branches "${remote_refs[@]}"
      fi
    fi
    printf "\n"
  fi

  if (( noup_total > 0 )); then
    heading "branches with no upstream"
    for branch in "${noup_rows[@]}"; do
      printf "  %s\n" "$branch"
    done
    printf "\n"
  fi

  if (( stash_count > 0 )); then
    heading "stashes"
    printf "  %s stash(es), newest: %s\n\n" "$stash_count" "$stash_subject"
  fi

  if (( uncommitted_total > 0 )); then
    heading "uncommitted"
    printf "  %s tracked change(s), %s untracked path(s)\n\n" \
      "$tracked_changes" "$untracked_paths"
  fi

  if (( tag_total > 0 )); then
    heading "tags missing or different on $tag_remote"
    for tag in "${missing_tags[@]}"; do
      printf "  %s\n" "$tag"
    done
    printf "\n"
  fi
fi

if (( tags_failed == 1 )); then
  err "cannot reach $tag_remote; tags were not compared"
fi
if (( status_failed == 1 )); then
  err "git status failed; uncommitted work could not be checked"
fi

if (( PORCELAIN == 0 )); then
  if (( found_any == 0 )); then
    printf "nothing exists only on this machine\n"
  else
    summary="$commit_total unpushed commit(s) on $commit_branches branch(es), $noup_total branch(es) without upstream, $stash_count stash(es), $uncommitted_total uncommitted path(s)"
    (( TAGS == 1 )) && summary="$summary, $tag_total unpushed tag(s)"
    printf "%s\n" "$summary"

    # Printed, never run: each line is the next step for one kind of finding.
    hint_remote="$REMOTE"
    if [[ -z "$hint_remote" ]]; then
      hint_remote="<remote>"
      [[ "$remote_count" == "1" ]] && hint_remote="$(git remote)"
    fi
    printf "\n=== what to do about it ===\n"
    if (( ${#commit_rows[@]} > 0 || noup_total > 0 )); then
      printf "  push a branch and set its upstream:\n"
      printf "    git push -u %s <branch>\n" "$hint_remote"
    fi
    if (( detached_count > 0 )); then
      printf "  keep the detached commits on a branch first:\n"
      printf "    git switch -c <new-branch>\n"
    fi
    if (( stash_count > 0 )); then
      printf "  turn a stash into a branch you can push:\n"
      printf "    git stash branch <new-branch> stash@{0}\n"
    fi
    if (( uncommitted_total > 0 )); then
      printf "  commit what should be kept, then push it:\n"
      printf "    git status\n"
    fi
    if (( tag_total > 0 )); then
      printf "  push the missing tags:\n"
      printf "    git push %s <tag>\n" "$hint_remote"
    fi
  fi
fi

if (( tags_failed == 1 )); then
  exit 1
fi
if (( STRICT == 1 && status_failed == 1 )); then
  exit 1
fi
if (( STRICT == 1 && found_any == 1 )); then
  exit 1
fi
exit 0

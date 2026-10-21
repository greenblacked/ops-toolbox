#!/usr/bin/env bash
# Forecast whether branches merge cleanly into a base, without a checkout.

set -euo pipefail

# --- output ----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
else
  C_RESET=''; C_RED=''; C_GREEN=''
fi

err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# --- defaults --------------------------------------------------------------
BASE=""
ALL_LOCAL=0
PORCELAIN=0
BRANCHES=()

usage() {
  cat <<EOF
git_merge_check.sh - will these branches merge cleanly? A conflict forecast with no checkout

Runs the real three-way merge of each branch into BASE in memory with
'git merge-tree --write-tree' (Git 2.38 or newer) and reports the outcome:

  clean     merges with no conflict
  conflict  would conflict; the conflicting paths are listed
  merged    already contained in BASE
  ff        BASE is an ancestor, so the merge would be a fast-forward
  error     git could not merge them at all (for example unrelated histories)

Nothing is checked out and HEAD, the index, the working tree and every ref are
left alone, so it works with a dirty tree, in the middle of a rebase and in a
bare repository. It is not entirely write-free: merge-tree stores the merge
result's trees and blobs in the object database, unreachable from any ref,
where 'git gc' collects them like any other loose garbage.

Usage:
  $(basename "$0") [--into BASE] [--all-local] [--porcelain] [BRANCH...]

Options:
  --into BASE    Branch to merge into (default: the remote's HEAD branch, else
                 main, else master; local if it exists, else origin/NAME)
  --all-local    Check every local branch except BASE
  --porcelain    Tab-separated rows: status branch base path, one row per
                 conflicting path (path is empty for other statuses)
  --             End of options; everything after is a branch
  -h, --help     Show this help

With no BRANCH and no --all-local, HEAD is checked. Paths with unusual bytes
appear C-quoted, the way git prints them.

Exit codes: 0 every branch clean, merged or ff, 1 at least one conflict or
error, 2 not a git repo or git older than 2.38, 3 usage, 4 base or branch not
found, or HEAD has no commits yet
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

# --- arguments -------------------------------------------------------------
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --into)
      require_value "$1" "${2:-}"; shift; BASE="$1" ;;
    --into=*)
      BASE="${1#*=}"; require_value "--into" "$BASE" ;;
    --all-local) ALL_LOCAL=1 ;;
    --porcelain) PORCELAIN=1 ;;
    --)
      shift
      while (( $# > 0 )); do BRANCHES+=("$1"); shift; done
      break
      ;;
    -*)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
    *) BRANCHES+=("$1") ;;
  esac
  shift
done

# --- preflight -------------------------------------------------------------
# --git-dir rather than --is-inside-work-tree: nothing here needs a working
# tree, and a bare repository is a fine place to ask the question.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  printf "HEAD has no commits yet; there is nothing to merge\n" >&2
  exit 4
fi

# A self-merge is clean on 2.38 and later and a usage error (129) before it.
# Failing closed here is the point: an old git would otherwise have every
# branch reported as an error, which reads as a conflict forecast.
if ! git merge-tree --write-tree --name-only HEAD HEAD >/dev/null 2>&1; then
  err "git 2.38 or newer is required for merge-tree --write-tree"
  exit 2
fi

# Resolved the way git_sync_default.sh resolves the default branch, then
# preferring the local branch and falling back to the remote-tracking one, so
# a fresh CI checkout with only origin/main still has a base.
if [[ -z "$BASE" ]]; then
  name=""
  remote_head="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$remote_head" ]]; then
    name="${remote_head#origin/}"
  elif git show-ref --verify --quiet refs/remotes/origin/main || git show-ref --verify --quiet refs/heads/main; then
    name="main"
  elif git show-ref --verify --quiet refs/remotes/origin/master || git show-ref --verify --quiet refs/heads/master; then
    name="master"
  fi
  if [[ -n "$name" ]] && git show-ref --verify --quiet "refs/heads/$name"; then
    BASE="$name"
  elif [[ -n "$name" ]] && git show-ref --verify --quiet "refs/remotes/origin/$name"; then
    BASE="origin/$name"
  else
    printf "could not determine base branch; pass --into\n" >&2
    exit 4
  fi
fi

# Every name is resolved to a commit once, here. The git calls below take the
# object names, so a branch name can never be read as an option or a path.
resolve() {
  [[ "$1" != -* ]] || return 1
  git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null
}

if ! base_sha="$(resolve "$BASE")"; then
  printf "base not found: %s\n" "$BASE" >&2
  exit 4
fi

if (( ALL_LOCAL == 1 )); then
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    name="${ref#refs/heads/}"
    [[ "$name" == "$BASE" ]] && continue
    BRANCHES+=("$name")
  done < <(git for-each-ref --format='%(refname)' refs/heads)
fi
if (( ${#BRANCHES[@]} == 0 && ALL_LOCAL == 0 )); then
  BRANCHES=(HEAD)
fi

shas=()
for b in "${BRANCHES[@]+"${BRANCHES[@]}"}"; do
  if ! sha="$(resolve "$b")"; then
    printf "branch not found: %s\n" "$b" >&2
    exit 4
  fi
  shas+=("$sha")
done

# --- check -----------------------------------------------------------------
n_clean=0
n_conflict=0
n_merged=0
n_ff=0
n_error=0

report() {
  local status="$1" branch="$2" detail="$3" colour="$C_GREEN"
  case "$status" in conflict|error) colour="$C_RED" ;; esac
  # Padded first, coloured after, so escape codes never count towards the
  # column width.
  if [[ -n "$detail" ]]; then
    printf "%s%-9s%s %s  %s\n" "$colour" "$status" "$C_RESET" "$branch" "$detail"
  else
    printf "%s%-9s%s %s\n" "$colour" "$status" "$C_RESET" "$branch"
  fi
}

i=0
while (( i < ${#shas[@]} )); do
  branch="${BRANCHES[$i]}"
  sha="${shas[$i]}"
  i=$((i + 1))

  if git merge-base --is-ancestor "$sha" "$base_sha"; then
    n_merged=$((n_merged + 1))
    if (( PORCELAIN == 1 )); then
      printf "merged\t%s\t%s\t\n" "$branch" "$BASE"
    else
      report merged "$branch" "already in $BASE"
    fi
    continue
  fi
  if git merge-base --is-ancestor "$base_sha" "$sha"; then
    n_ff=$((n_ff + 1))
    if (( PORCELAIN == 1 )); then
      printf "ff\t%s\t%s\t\n" "$branch" "$BASE"
    else
      report ff "$branch" "fast-forward"
    fi
    continue
  fi

  rc=0
  out="$(git merge-tree --write-tree --name-only "$base_sha" "$sha" 2>/dev/null)" || rc=$?
  if (( rc == 0 )); then
    n_clean=$((n_clean + 1))
    if (( PORCELAIN == 1 )); then
      printf "clean\t%s\t%s\t\n" "$branch" "$BASE"
    else
      report clean "$branch" ""
    fi
  elif (( rc == 1 )); then
    # Output shape: the tree id on line 1, then one conflicted path per line,
    # then a blank line, then git's informational messages.
    n_conflict=$((n_conflict + 1))
    files=()
    line_no=0
    while IFS= read -r line; do
      line_no=$((line_no + 1))
      (( line_no == 1 )) && continue
      [[ -n "$line" ]] || break
      files+=("$line")
    done <<<"$out"
    if (( PORCELAIN == 1 )); then
      for f in "${files[@]+"${files[@]}"}"; do
        printf "conflict\t%s\t%s\t%s\n" "$branch" "$BASE" "$f"
      done
      (( ${#files[@]} > 0 )) || printf "conflict\t%s\t%s\t\n" "$branch" "$BASE"
    else
      list=""
      for f in "${files[@]+"${files[@]}"}"; do
        if [[ -z "$list" ]]; then list="$f"; else list="$list, $f"; fi
      done
      report conflict "$branch" "${#files[@]} file(s): $list"
    fi
  else
    n_error=$((n_error + 1))
    all="$(git merge-tree --write-tree --name-only "$base_sha" "$sha" 2>&1 >/dev/null || true)"
    msg=""
    IFS= read -r msg <<<"$all" || true
    [[ -n "$msg" ]] || msg="git merge-tree exited $rc"
    if (( PORCELAIN == 1 )); then
      printf "error\t%s\t%s\t\n" "$branch" "$BASE"
    else
      report error "$branch" "$msg"
    fi
  fi
done

if (( PORCELAIN == 0 )); then
  printf "\n%s branch(es) into %s: %s clean, %s conflicting, %s merged, %s fast-forward, %s error(s)\n" \
    "${#shas[@]}" "$BASE" "$n_clean" "$n_conflict" "$n_merged" "$n_ff" "$n_error"
fi

if (( n_conflict > 0 || n_error > 0 )); then
  exit 1
fi
exit 0

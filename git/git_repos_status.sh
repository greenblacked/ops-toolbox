#!/usr/bin/env bash
# Report every Git checkout under one or more directories on one screen.

set -euo pipefail

# --- output ----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_DIM=''
fi

err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# --- defaults --------------------------------------------------------------
DIRS=()
DEPTH=2
ONLY=""
FETCH=0
DRY_RUN=0
STRICT=0
PORCELAIN=0

usage() {
  cat <<EOF
git_repos_status.sh - one-screen status of every checkout under a directory

The read side of clone-repos.sh: across every checkout under --dir, which ones
have uncommitted work, commits that exist on no remote, stashes, or are behind
their upstream. With --strict it becomes a gate for "is this machine safe to
wipe": exit 1 while anything here exists only locally.

Usage:
  $(basename "$0") [--dir DIR]... [--depth N] [--only dirty|ahead|behind|unpushed|stash]
                      [--fetch] [--dry-run] [--strict] [--porcelain]

Options:
  --dir DIR       Where to look (repeatable; default: the current directory).
                  A DIR that is itself a checkout is reported alone.
  --depth N       How many directory levels below DIR to search (default: 2)
  --only STATE    Only show repositories that are dirty, ahead, behind, have
                  unpushed commits, or have a stash. Rows that could not be
                  checked (failed git status, fetch, stash list or upstream
                  walk, or an unreadable repository) are kept under every
                  filter.
  --fetch         Run 'git fetch --prune --quiet' for every remote of each
                  repository first, so all are refreshed and pruned.
                  Network; it updates remote-tracking refs and nothing else.
                  A failure on any remote counts as work at risk.
  --dry-run       Print the fetch each repository would get and report from
                  the refs already on disk; changes nothing. With --porcelain
                  the dry-run lines go to stderr, so stdout stays rows only
  --strict        Exit 1 when any reported repository has work at risk
  --porcelain     Tab-separated rows for scripts, no header or colour:
                  path branch upstream ahead behind changed stash unpushed notes
  -h, --help      Show this help

Work at risk means uncommitted or untracked changes, commits ahead of the
upstream, commits on local branches that no remote-tracking ref contains, a
stash, a git status, stash list or history walk that failed (noted
status-failed, stash-failed or walk-failed), or (with --fetch) a fetch that
failed. Without --fetch nothing is fetched, so remote-tracking refs are only
as fresh as the last fetch in each repository: "behind" means behind what this
machine last saw.

Never pulls, merges, checks out, stashes or cleans. A plain run exits 0 even
when repositories need attention; --strict is the only way it returns 1.

Exit codes: 0 success, 1 --strict found work at risk, 2 git missing or a --dir is not a readable directory, 3 usage, 4 no repository found
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
# --help is handled here, before any preflight check, so it keeps working on a
# machine without git.
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir)
      require_value "$1" "${2:-}"; shift; DIRS+=("$1") ;;
    --dir=*)
      value="${1#*=}"; require_value "--dir" "$value"; DIRS+=("$value") ;;
    --depth)
      require_value "$1" "${2:-}"; shift; require_number "--depth" "$1"; DEPTH="$1" ;;
    --depth=*)
      DEPTH="${1#*=}"; require_value "--depth" "$DEPTH"; require_number "--depth" "$DEPTH" ;;
    --only)
      require_value "$1" "${2:-}"; shift; ONLY="$1" ;;
    --only=*)
      ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --fetch)     FETCH=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --strict)    STRICT=1 ;;
    --porcelain) PORCELAIN=1 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$ONLY" in
  ''|dirty|ahead|behind|unpushed|stash) ;;
  *)
    printf -- "--only must be dirty, ahead, behind, unpushed, or stash\n" >&2
    exit 3
    ;;
esac

(( ${#DIRS[@]} > 0 )) || DIRS=(".")
# 10# so a value written with a leading zero (08) is not read as octal.
DEPTH=$((10#$DEPTH))

# Dry-run lines go to stderr under --porcelain so stdout stays rows only.
dry_say() {
  if (( PORCELAIN == 1 )); then
    printf '%s\n' "$1" >&2
  else
    printf '%s\n' "$1"
  fi
}

# --- preflight -------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  err "git is not installed or not in PATH"
  exit 2
fi
for d in "${DIRS[@]}"; do
  if [[ ! -d "$d" || ! -r "$d" || ! -x "$d" ]]; then
    err "not a readable directory: $d"
    exit 2
  fi
done

# --- discovery -------------------------------------------------------------
# A directory holding .git is a checkout: a directory for a normal clone, a
# file for a linked worktree or a submodule. Either way it is reported and not
# descended into, so a repository's own subdirectories are never scanned.
# Pure globbing rather than find(1), whose -exec and -maxdepth spellings differ
# between BSD and GNU; the glob skips dot-directories, which is what you want
# under ~/src.
scan_dir() {
  local dir="$1" depth="$2" child
  if [[ -e "$dir/.git" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi
  (( depth > 0 )) || return 0
  for child in "$dir"/*/; do
    [[ -d "$child" ]] || continue
    scan_dir "${child%/}" $((depth - 1))
  done
}

# --- per repository ----------------------------------------------------------
# Parallel indexed arrays rather than an associative one, which Bash 3.2 does
# not have. Every row is collected first so the human table can size its
# first column to the longest path.
row_path=()
row_rel=()
row_branch=()
row_upstream=()
row_sync=()
row_ahead=()
row_behind=()
row_changed=()
row_stash=()
row_unpushed=()
row_notes=()
row_risk=()

found=0
shown=0
at_risk=0
behind_count=0

add_note() {
  if [[ -z "$notes" ]]; then notes="$1"; else notes="$notes,$1"; fi
}

inspect_repo() {
  local repo="$1" rel="$2"
  local branch upstream counts ahead=0 behind=0 changed=0 stash=0 unpushed=0
  local sync risk=0 keep=1 has_remote remotes remote tips status_out stash_out status_failed=0 fetch_failed=0 walk_failed=0
  local stash_failed=0 unreadable=0
  notes=""

  # A checkout git cannot read (a broken .git file, an ownership refusal) is
  # not safe to wipe just because it could not be inspected, so it counts as
  # work at risk rather than disappearing from the report.
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    unreadable=1
    add_note "unreadable"
    branch=""; upstream=""; sync="?"; ahead=""; behind=""
    changed=""; stash=""; unpushed=""; risk=1
  else
    has_remote=0
    remotes="$(git -C "$repo" remote 2>/dev/null || true)"
    [[ -n "$remotes" ]] && has_remote=1
    if (( has_remote == 1 )); then
      if (( DRY_RUN == 1 )); then
        while IFS= read -r remote; do
          [[ -n "$remote" ]] || continue
          dry_say "dry-run: would run: git -C $repo fetch --prune --quiet $remote"
        done <<EOF_REMOTES
$remotes
EOF_REMOTES
      elif (( FETCH == 1 )); then
        # No terminal prompt: one repository asking for a password would
        # otherwise stall the whole sweep.
        # --prune drops remote-tracking refs for branches deleted on the
        # remote; otherwise a stale ref makes formerly pushed commits look
        # pushed. Each remote is fetched by name because 'fetch --all'
        # skips remotes with remote.<name>.skipFetchAll set, which would
        # leave their stale refs behind. A failure on any remote leaves
        # the refs unverified, so it counts as work at risk below.
        while IFS= read -r remote; do
          [[ -n "$remote" ]] || continue
          if ! GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --prune --quiet "$remote" </dev/null >/dev/null 2>&1; then
            fetch_failed=1
          fi
        done <<EOF_REMOTES
$remotes
EOF_REMOTES
        (( fetch_failed == 0 )) || add_note "fetch-failed"
      fi
    fi

    branch="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
      branch="detached@$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || printf '?')"
    fi
    # rev-parse prints the literal '@{upstream}' before failing when the
    # tracking ref is gone (for instance just pruned), so the output is kept
    # only when the command succeeds.
    if ! upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
      upstream=""
    fi
    walk_failed=0
    if [[ -n "$upstream" ]]; then
      if counts="$(git -C "$repo" rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null)" && [[ -n "$counts" ]]; then
        behind="${counts%%	*}"
        ahead="${counts##*	}"
      else
        walk_failed=1
      fi
    fi
    # --no-optional-locks keeps status from refreshing the index on disk, so
    # a report over checkouts an editor has open writes nothing to any of them.
    # The output is captured before it is counted: a pipe into wc would hide a
    # failing status (corrupt or unreadable index) as "0 changed", and a
    # --strict gate would then pass a checkout it could not read.
    status_failed=0
    if status_out="$(git --no-optional-locks -C "$repo" status --porcelain=v1 2>/dev/null)"; then
      if [[ -n "$status_out" ]]; then
        changed="$(printf '%s\n' "$status_out" | wc -l | tr -d ' ')"
      fi
    else
      status_failed=1
    fi
    # Captured like status: a pipe into wc would turn a damaged refs/stash
    # (a missing object) into "0 stashes" and let --strict pass.
    stash_failed=0
    if stash_out="$(git -C "$repo" stash list 2>/dev/null)"; then
      stash=0
      if [[ -n "$stash_out" ]]; then
        stash="$(printf '%s\n' "$stash_out" | wc -l | tr -d ' ')"
      fi
    else
      stash=0
      stash_failed=1
    fi
    # Commits on any local branch that no remote-tracking ref contains. In a
    # repository with no remotes that is every commit, which is the truth.
    # HEAD is added when it exists, so work committed on a detached HEAD
    # counts too; an unborn HEAD would make rev-list fail, so it is left out.
    tips=(--branches)
    if git -C "$repo" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
      tips=(HEAD --branches)
    fi
    # A failed walk (a missing or unreadable object) says nothing about what
    # is unpushed, so it is never read as zero: it is flagged and counts as
    # work at risk.
    if ! unpushed="$(git -C "$repo" rev-list "${tips[@]}" --not --remotes --count 2>/dev/null)" || [[ -z "$unpushed" ]]; then
      unpushed=0
      walk_failed=1
    fi

    (( changed > 0 )) && add_note "dirty"
    (( status_failed == 1 )) && add_note "status-failed"
    (( walk_failed == 1 )) && add_note "walk-failed"
    (( stash_failed == 1 )) && add_note "stash-failed"
    if (( ahead > 0 && behind > 0 )); then
      add_note "diverged"
    elif (( ahead > 0 )); then
      add_note "ahead"
    elif (( behind > 0 )); then
      add_note "behind"
    fi
    if [[ "$branch" == detached@* ]]; then
      add_note "detached"
    elif [[ -z "$upstream" ]]; then
      add_note "no-upstream"
    fi
    (( has_remote == 1 )) || add_note "no-remote"
    (( stash > 0 )) && add_note "stash"

    if [[ -z "$upstream" ]]; then
      sync="-"
    elif (( ahead > 0 && behind > 0 )); then
      sync="+$ahead/-$behind"
    elif (( ahead > 0 )); then
      sync="+$ahead"
    elif (( behind > 0 )); then
      sync="-$behind"
    else
      sync="="
    fi

    if (( changed > 0 || status_failed == 1 || walk_failed == 1 || stash_failed == 1 || fetch_failed == 1 || ahead > 0 || unpushed > 0 || stash > 0 )); then
      risk=1
    fi
  fi

  # A row that could not be checked is kept under every filter: an
  # unreadable checkout, a failed git status, fetch, upstream walk or stash
  # list. No filter can say such a row is clear, and --strict must still
  # fail on it.
  if [[ -n "$ONLY" ]] && (( unreadable == 0 && status_failed == 0 && fetch_failed == 0 && walk_failed == 0 && stash_failed == 0 )); then
    case "$ONLY" in
      dirty)    (( changed > 0 )) || keep=0 ;;
      ahead)    (( ahead > 0 )) || keep=0 ;;
      behind)   (( behind > 0 )) || keep=0 ;;
      unpushed) (( unpushed > 0 )) || keep=0 ;;
      stash)    (( stash > 0 )) || keep=0 ;;
    esac
  fi
  (( keep == 1 )) || return 0

  row_path+=("$repo")
  row_rel+=("$rel")
  row_branch+=("$branch")
  row_upstream+=("$upstream")
  row_sync+=("$sync")
  row_ahead+=("$ahead")
  row_behind+=("$behind")
  row_changed+=("$changed")
  row_stash+=("$stash")
  row_unpushed+=("$unpushed")
  row_notes+=("$notes")
  row_risk+=("$risk")
  shown=$((shown + 1))
  (( risk == 1 )) && at_risk=$((at_risk + 1))
  if [[ -n "$behind" ]] && (( behind > 0 )); then
    behind_count=$((behind_count + 1))
  fi
  return 0
}

for top in "${DIRS[@]}"; do
  # Trailing slashes off, so the relative names below come out clean; "/"
  # itself stays "/".
  while [[ "$top" == */ && "$top" != "/" ]]; do top="${top%/}"; done
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    found=$((found + 1))
    if [[ "$repo" == "$top" ]]; then
      rel="$top"
    else
      rel="${repo#"$top"/}"
    fi
    inspect_repo "$repo" "$rel"
  done < <(scan_dir "$top" "$DEPTH" | sort)
done

if (( found == 0 )); then
  err "no Git repository found under: ${DIRS[*]} (depth $DEPTH)"
  exit 4
fi

# --- report ----------------------------------------------------------------
plural() {
  if [[ "$1" == "1" ]]; then printf '%s' "$2"; else printf '%s' "$3"; fi
}

if (( PORCELAIN == 1 )); then
  i=0
  while (( i < shown )); do
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "${row_path[$i]}" "${row_branch[$i]}" "${row_upstream[$i]}" \
      "${row_ahead[$i]}" "${row_behind[$i]}" "${row_changed[$i]}" \
      "${row_stash[$i]}" "${row_unpushed[$i]}" "${row_notes[$i]}"
    i=$((i + 1))
  done
else
  width=4
  i=0
  while (( i < shown )); do
    (( ${#row_rel[$i]} > width )) && width=${#row_rel[$i]}
    i=$((i + 1))
  done
  printf "%s%-*s  %-20s %-9s %7s %5s %8s  %s%s\n" "$C_BOLD" "$width" "REPO" \
    "BRANCH" "SYNC" "CHANGED" "STASH" "UNPUSHED" "NOTES" "$C_RESET"
  i=0
  while (( i < shown )); do
    if (( ${row_risk[$i]} == 1 )); then
      colour="$C_YELLOW"
    else
      colour="$C_GREEN"
    fi
    notes_text="${row_notes[$i]}"
    [[ -n "$notes_text" ]] || notes_text="${C_DIM}clean${C_RESET}"
    # Padded first, coloured after, so escape codes never count towards a
    # column's width.
    printf "%-*s  %-20.20s %-9s %7s %5s %8s  %s%s%s\n" "$width" "${row_rel[$i]}" \
      "${row_branch[$i]}" "${row_sync[$i]}" "${row_changed[$i]:-?}" \
      "${row_stash[$i]:-?}" "${row_unpushed[$i]:-?}" \
      "$colour" "$notes_text" "$C_RESET"
    i=$((i + 1))
  done
  printf "\n%s %s: %s with work at risk, %s behind\n" \
    "$shown" "$(plural "$shown" repository repositories)" "$at_risk" "$behind_count"
fi

if (( DRY_RUN == 1 )); then
  dry_say "dry-run complete; no changes written"
fi

if (( STRICT == 1 && at_risk > 0 )); then
  exit 1
fi
exit 0

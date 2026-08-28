#!/usr/bin/env bash
# Report branches nobody has touched in a while, and who touched them last.

set -euo pipefail

DAYS=90
INCLUDE_REMOTES=0
REMOTE=""
STATE=""

usage() {
  cat <<EOF
git_stale_branches.sh - list branches older than a threshold, with their last author

Read-only. It deletes nothing, fetches nothing and writes nothing; it answers
"what is still here that nobody has touched" and hands the answer to the two
scripts that do the deleting.

Age is the last commit date of the branch tip, which is the only date Git keeps.
A branch created yesterday from a commit made a year ago therefore reads as a
year old — that is Git's answer, not a bug in this one.

Each branch is labelled so the list can be acted on rather than just read:

  gone      the upstream was deleted on the remote — git_prune_gone.sh
  merged    reachable from HEAD, so git_cleanup_merged.sh will remove it
  unmerged  neither: either squash-merged and forgotten, or genuinely abandoned

Usage:
  $(basename "$0") [--days 90] [--state gone|merged|unmerged] [--remote [NAME]]

Options:
  --days N        Only report branches older than this many days (default: 90)
  --remote        Also report remote-tracking branches, for every remote
  --remote NAME   As above, but only for that one remote
  --state STATE   Only show gone, merged, or unmerged branches
  --help, -h      Show this help

Remote-tracking refs are only as fresh as the last fetch, so a branch someone
deleted this morning still shows up until 'git fetch --prune' has run. This
script does not fetch, because a read-only report that quietly rewrites refs is
not read-only.

Exit codes: 0 success, 2 not a git repo, 3 usage, 4 nothing older than the threshold
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

while (( $# > 0 )); do
  case "$1" in
    --days)
      require_value "$1" "${2:-}"; shift; require_number "--days" "$1"; DAYS="$1" ;;
    --days=*)
      DAYS="${1#*=}"; require_value "--days" "$DAYS"; require_number "--days" "$DAYS" ;;
    --remote)
      INCLUDE_REMOTES=1
      # A bare --remote means every remote. A value is accepted too, because
      # git_prune_gone.sh spells it --remote NAME and a habit formed there
      # should not land here as a usage error.
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        shift
        REMOTE="$1"
      fi
      ;;
    --remote=*)
      INCLUDE_REMOTES=1
      REMOTE="${1#*=}"
      require_value "--remote" "$REMOTE"
      ;;
    --state)
      require_value "$1" "${2:-}"; shift; STATE="$1" ;;
    --state=*)
      STATE="${1#*=}"; require_value "--state" "$STATE" ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      printf "unknown argument: %s\n" "$1" >&2
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$STATE" in
  ''|gone|merged|unmerged) ;;
  *)
    printf -- "--state must be gone, merged, or unmerged\n" >&2
    exit 3
    ;;
esac

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_DIM=''; C_BOLD=''
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if [[ -n "$REMOTE" ]] && ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  printf "remote not found: %s\n" "$REMOTE" >&2
  exit 3
fi

now="$(date +%s)"
current_branch="$(git branch --show-current)"
cutoff_seconds=$(( DAYS * 86400 ))

local_count=0
remote_count=0
gone_count=0
merged_count=0
unmerged_count=0

print_header() {
  printf "  %s%5s  %-11s %-22s %-9s %s%s\n" \
    "$C_BOLD" "AGE" "LAST COMMIT" "AUTHOR" "STATE" "BRANCH" "$C_RESET"
}

# `%(committerdate:unix)` is the tip's own date; ordering by it puts the
# stalest first, which is the order you want to read the list in. Fields are
# tab-separated: a '|' is a legal character in a ref name (see
# git_recent_branches.sh), and putting the free-form author name last still
# keeps a tab inside the author from shifting the other columns.
scan_refs() {
  local namespace="$1" kind="$2"
  local line branch unix when track author age state colour flag
  while IFS=$'\t' read -r branch unix when track author; do
    [[ -n "$branch" ]] || continue

    [[ -n "$unix" ]] || continue
    # A remote's HEAD is a symbolic pointer at another branch in this list.
    [[ "$branch" == */HEAD ]] && continue

    age=$(( (now - unix) / 86400 ))
    (( age >= DAYS )) || continue

    state="unmerged"
    colour="$C_YELLOW"
    if [[ "$track" == "[gone]" ]]; then
      state="gone"
      colour="$C_RED"
    elif git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
      state="merged"
      colour="$C_GREEN"
    fi

    [[ -z "$STATE" || "$state" == "$STATE" ]] || continue

    if [[ "$kind" == "local" ]]; then
      local_count=$((local_count + 1))
      case "$state" in
        gone)     gone_count=$((gone_count + 1)) ;;
        merged)   merged_count=$((merged_count + 1)) ;;
        unmerged) unmerged_count=$((unmerged_count + 1)) ;;
      esac
    else
      remote_count=$((remote_count + 1))
    fi

    flag=""
    [[ "$branch" == "$current_branch" ]] && flag=" ${C_DIM}(current)${C_RESET}"

    # Colour is applied around the already-padded field, so the escape codes
    # never count towards the column width.
    printf "  %s%4dd%s  %-11s %-22.22s %s%-9s%s %s%s\n" \
      "$C_YELLOW" "$age" "$C_RESET" "$when" "$author" \
      "$colour" "$state" "$C_RESET" "$branch" "$flag"
  done < <(git for-each-ref --sort=committerdate \
    --format=$'%(refname:short)%09%(committerdate:unix)%09%(committerdate:short)%09%(upstream:track)%09%(authorname)' \
    "$namespace")
}

printf "%s== local branches older than %s days ==%s\n" "$C_BOLD" "$DAYS" "$C_RESET"
print_header
scan_refs refs/heads local
if (( local_count == 0 )); then
  printf "  %snone%s\n" "$C_DIM" "$C_RESET"
fi

if (( INCLUDE_REMOTES == 1 )); then
  if [[ -n "$REMOTE" ]]; then
    namespace="refs/remotes/$REMOTE"
  else
    namespace="refs/remotes"
  fi
  printf "\n%s== remote-tracking branches older than %s days ==%s\n" \
    "$C_BOLD" "$DAYS" "$C_RESET"
  print_header
  scan_refs "$namespace" remote
  if (( remote_count == 0 )); then
    printf "  %snone%s\n" "$C_DIM" "$C_RESET"
  fi
fi

if (( local_count == 0 && remote_count == 0 )); then
  printf "\nnothing older than %s days\n" "$DAYS"
  exit 4
fi

printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s local branch(es): %s gone, %s merged, %s unmerged\n" \
  "$local_count" "$gone_count" "$merged_count" "$unmerged_count"
if (( INCLUDE_REMOTES == 1 )); then
  printf "  %s remote-tracking branch(es)\n" "$remote_count"
fi

cat <<'EOF'

=== what to do about it ===
  Branches marked "gone" have had their upstream deleted, which is what a
  squash-merged pull request leaves behind:
    git_prune_gone.sh --dry-run

  Branches marked "merged" are reachable from HEAD and safe to remove:
    git_cleanup_merged.sh --dry-run --base main

  An "unmerged" branch is the one to look at by hand. It is either work that
  was squash-merged before that remote branch was deleted, or work that was
  abandoned — and the two are indistinguishable from here:
    git log --oneline main..<branch>
EOF

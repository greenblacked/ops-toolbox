#!/usr/bin/env bash
# Lint every commit message in a range against the commit-msg hook's rules.

set -euo pipefail

# --- output ----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
else
  C_RESET=''; C_RED=''; C_GREEN=''
fi

err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# --- defaults --------------------------------------------------------------
RANGE=""
BASE=""
MAX_SUBJECT=72
TYPES="build,chore,ci,docs,feat,fix,perf,refactor,revert,style,test"
FORBID=()
ALLOW_FIXUP=0
PORCELAIN=0

usage() {
  cat <<EOF
git_commitlint.sh - lint the commit messages a branch adds, for CI

The commit-msg hook from git_hooks_install.sh checks one message at commit time
and is skipped by --no-verify. This checks every commit in a range, so a pull
request can be held to the same rules where nobody can skip them:

  not-conventional  the subject is not 'type(optional scope): subject', with an
                    optional '!'; subjects starting 'Merge ' or 'Revert ' are
                    exempt, as in the hook
  too-long          the subject is longer than --max-subject characters
  no-blank-line     the second line of the message is not blank
  fixup             a fixup!, squash! or amend! commit that was never squashed
  forbidden         the message matches a --forbid pattern

Merge commits are never linted. Every problem of every commit is reported.

Usage:
  $(basename "$0") [--range REVRANGE | --base REF] [--max-subject N] [--types LIST]
                     [--forbid ERE]... [--allow-fixup] [--porcelain]

Options:
  --range REVRANGE  Commits to lint, used as given (CI: <base-sha>..<head-sha>)
  --base REF        Lint merge-base(REF, HEAD)..HEAD (default REF: main, else
                    master, else the branch origin/HEAD points at)
  --max-subject N   Longest subject allowed, in characters (default: 72)
  --types LIST      Comma-separated types, replacing the default
                    build,chore,ci,docs,feat,fix,perf,refactor,revert,style,test
  --forbid ERE      Flag any message matching this extended regex, ignoring
                    case (repeatable)
  --allow-fixup     Do not flag fixup!, squash! and amend! commits
  --porcelain       Tab-separated rows: sha problem subject, one per problem
  -h, --help        Show this help

The whole range has to be in the clone. A shallow CI checkout that lacks the
base exits 3 or 4 rather than passing: fetch with full depth, or fetch the base
explicitly, before running this.

Exit codes: 0 every commit is fine, 1 problems found, 2 not a git repo,
3 usage, bad range or bad type, 4 empty range or no base branch could be inferred
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
    --range)
      require_value "$1" "${2:-}"; shift; RANGE="$1" ;;
    --range=*)
      RANGE="${1#*=}"; require_value "--range" "$RANGE" ;;
    --base)
      require_value "$1" "${2:-}"; shift; BASE="$1" ;;
    --base=*)
      BASE="${1#*=}"; require_value "--base" "$BASE" ;;
    --max-subject)
      require_value "$1" "${2:-}"; shift; require_number "--max-subject" "$1"; MAX_SUBJECT="$1" ;;
    --max-subject=*)
      MAX_SUBJECT="${1#*=}"; require_value "--max-subject" "$MAX_SUBJECT"
      require_number "--max-subject" "$MAX_SUBJECT" ;;
    --types)
      require_value "$1" "${2:-}"; shift; TYPES="$1" ;;
    --types=*)
      TYPES="${1#*=}"; require_value "--types" "$TYPES" ;;
    --forbid)
      require_value "$1" "${2:-}"; shift; FORBID+=("$1") ;;
    --forbid=*)
      value="${1#*=}"; require_value "--forbid" "$value"; FORBID+=("$value") ;;
    --allow-fixup) ALLOW_FIXUP=1 ;;
    --porcelain)   PORCELAIN=1 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if [[ -n "$RANGE" && -n "$BASE" ]]; then
  printf -- "--range and --base are alternatives; pass one\n" >&2
  exit 3
fi

# Each type is a lowercase word, joined into the alternation of the subject
# pattern below. Anything else would be read as regex syntax.
types_alt=""
word_re='^[a-z]+$'
IFS=',' read -r -a type_list <<<"$TYPES"
for t in "${type_list[@]+"${type_list[@]}"}"; do
  if [[ ! "$t" =~ $word_re ]]; then
    printf -- "--types takes comma-separated lowercase words, got: %s\n" "$TYPES" >&2
    exit 3
  fi
  if [[ -z "$types_alt" ]]; then types_alt="$t"; else types_alt="$types_alt|$t"; fi
done
if [[ -z "$types_alt" ]]; then
  printf -- "--types needs at least one type\n" >&2
  exit 3
fi
# Held in a variable: [[ =~ ]] with an inline pattern quotes differently across
# Bash versions, and 3.2 is the one that matters here.
subject_re='^('"$types_alt"')(\([a-zA-Z0-9._/-]+\))?!?: .+'

# grep exits 2 for a pattern it cannot compile; that is a usage error, not a
# commit with a problem.
for pattern in "${FORBID[@]+"${FORBID[@]}"}"; do
  rc=0
  grep -Eiq -- "$pattern" <<<"" || rc=$?
  if (( rc > 1 )); then
    printf -- "--forbid is not a valid extended regex: %s\n" "$pattern" >&2
    exit 3
  fi
done

# --- preflight -------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

if [[ -z "$RANGE" ]]; then
  if [[ -z "$BASE" ]]; then
    if git show-ref --verify --quiet refs/heads/main; then
      BASE="main"
    elif git show-ref --verify --quiet refs/heads/master; then
      BASE="master"
    elif git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
      BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)"
    else
      printf "could not infer base branch; pass --base or --range\n" >&2
      exit 4
    fi
  fi
  if [[ "$BASE" == -* ]] || ! base_sha="$(git merge-base "$BASE" HEAD 2>/dev/null)"; then
    err "no merge base between $BASE and HEAD (is the base fetched?)"
    exit 3
  fi
  RANGE="$base_sha..HEAD"
fi

if [[ "$RANGE" == -* ]]; then
  err "bad range: $RANGE"
  exit 3
fi
if ! shas="$(git rev-list --no-merges --reverse "$RANGE" -- 2>/dev/null)"; then
  err "bad range: $RANGE"
  exit 3
fi
if [[ -z "$shas" ]]; then
  printf "no commits in %s\n" "$RANGE"
  exit 4
fi

# --- lint ------------------------------------------------------------------
total=0
bad=0

while IFS= read -r sha; do
  [[ -n "$sha" ]] || continue
  total=$((total + 1))
  subject="$(git log -1 --format=%s "$sha")"
  message="$(git log -1 --format=%B "$sha")"
  problems=()
  matched=()

  is_fixup=0
  case "$subject" in
    fixup!*|squash!*|amend!*) is_fixup=1 ;;
  esac

  # Exempt exactly as the hook exempts them: a merge or revert subject git
  # wrote (a squash merge keeps it on a plain commit), and the fixup family,
  # which has its own finding below.
  if (( is_fixup == 0 )) && [[ "$subject" != "Merge "* && "$subject" != "Revert "* ]] &&
    [[ ! "$subject" =~ $subject_re ]]; then
    problems+=("not-conventional")
  fi
  if (( ${#subject} > MAX_SUBJECT )); then
    problems+=("too-long")
  fi
  line_no=0
  second=""
  while IFS= read -r line; do
    line_no=$((line_no + 1))
    if (( line_no == 2 )); then
      second="$line"
      break
    fi
  done <<<"$message"
  if [[ -n "$second" ]]; then
    problems+=("no-blank-line")
  fi
  if (( is_fixup == 1 && ALLOW_FIXUP == 0 )); then
    problems+=("fixup")
  fi
  for pattern in "${FORBID[@]+"${FORBID[@]}"}"; do
    # A here-string, not a pipe into grep -q: under pipefail an early exit
    # kills the writer and a match reads as a miss.
    if grep -Eiq -- "$pattern" <<<"$message"; then
      matched+=("$pattern")
    fi
  done
  if (( ${#matched[@]} > 0 )); then
    problems+=("forbidden")
  fi

  (( ${#problems[@]} > 0 )) || continue
  bad=$((bad + 1))
  short="$(git rev-parse --short "$sha")"

  if (( PORCELAIN == 1 )); then
    for p in "${problems[@]}"; do
      printf "%s\t%s\t%s\n" "$sha" "$p" "$subject"
    done
    continue
  fi

  list=""
  for p in "${problems[@]}"; do
    if [[ "$p" == "forbidden" ]]; then
      for pattern in "${matched[@]}"; do
        p="forbidden /$pattern/"
        if [[ -z "$list" ]]; then list="$p"; else list="$list, $p"; fi
      done
      continue
    fi
    if [[ -z "$list" ]]; then list="$p"; else list="$list, $p"; fi
  done
  shown="$subject"
  if (( ${#shown} > 60 )); then
    shown="${shown:0:57}..."
  fi
  printf "%s%s%s  %s  %s\n" "$C_RED" "$short" "$C_RESET" "$list" "$shown"
done <<<"$shas"

if (( PORCELAIN == 0 )); then
  if (( bad == 0 )); then
    printf "%s%s commit(s) checked, all fine%s\n" "$C_GREEN" "$total" "$C_RESET"
  else
    printf "\n%s of %s commit(s) have problems\n" "$bad" "$total"
  fi
fi

if (( bad > 0 )); then
  exit 1
fi
exit 0

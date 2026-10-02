#!/usr/bin/env bash
# Hold a pull request's branch name, and the type in its title, to the
# repository's naming convention. CONTRIBUTING.md ("Branch names") is the prose;
# this is the rule, and the CI branch filters are checked against it.
#
# A branch is <type>/<slug>:
#
#   feat/     a new script, flag or behaviour
#   fix/      a bug fix
#   docs/     documentation only
#   ci/       workflows, linters, the static suite
#   test/     tests only
#   perf/     faster, same behaviour
#   refactor/ same behaviour, different shape
#   deps/     a version bump: a pinned tool, image or RouterOS release
#   release/  a release pull request, release/<MAJOR.MINOR.PATCH>
#
# plus dependabot/, which Dependabot names itself and cannot be told otherwise.
# The slug is lowercase letters, digits, '.', '_' and '-', and may hold further
# '/'-separated segments.
#
# There is no chore/. "chore" says only that a change is not a feature, which
# every type above says better: a version bump is deps/, a release is release/,
# tooling is ci/. A tool-named prefix (claude/, ai/, bot/, codex/, copilot/) is
# refused with its own message, because it is the one mistake an automated
# author makes by default.
#
# Usage:
#   check_branch_name.sh BRANCH                 check a branch name
#   check_branch_name.sh --title TITLE BRANCH   also check the title's type
#   check_branch_name.sh --list-types           print the branch types, one a line
#   check_branch_name.sh -h | --help
#
# A title is checked only for the type it opens with: a "chore" type
# ("chore: ...", "chore(scope): ...") is refused, because a squash merge makes
# the title the commit subject on master. Free-form titles are left alone.
#
# Exit codes: 0 conforms, 1 does not, 3 bad arguments.
set -uo pipefail

TYPES="feat fix docs ci test perf refactor deps release"
# Owned by the bot: Dependabot builds the name itself, and the only knob it
# offers is the separator.
BOT_PREFIXES="dependabot"
TOOL_PREFIXES="claude ai bot codex copilot"
SLUG_RE='^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*$'
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

usage() {
  cat <<EOF
check_branch_name.sh - check a branch name (and a PR title's type) against the convention

Usage:
  $(basename "$0") BRANCH
  $(basename "$0") --title TITLE BRANCH
  $(basename "$0") --list-types

Branch types: $TYPES
Also allowed: $BOT_PREFIXES/ (bot-owned)
Release branches are release/MAJOR.MINOR.PATCH.

Options:
      --title TITLE   also refuse a "chore" type at the start of TITLE
      --list-types    print the branch types, one per line, and exit
  -h, --help          show this help

Exit codes: 0 conforms, 1 does not, 3 bad arguments
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

title=""
branch=""
while (( $# > 0 )); do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --list-types) tr ' ' '\n' <<< "$TYPES"; exit 0 ;;
    --title)      require_value "$1" "${2:-}"; title="$2"; shift ;;
    --title=*)    title="${1#*=}"; require_value "--title" "$title" ;;
    -*)           printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 3 ;;
    *)
      if [[ -n "$branch" ]]; then
        printf 'unexpected argument: %s\n' "$1" >&2; exit 3
      fi
      branch="$1"
      ;;
  esac
  shift
done
if [[ -z "$branch" ]]; then
  printf 'a BRANCH is required\n' >&2
  usage >&2
  exit 3
fi
# A ref passed whole is checked by its branch name.
branch="${branch#refs/heads/}"

problems=0
fail() { printf '[fail] %s\n' "$*" >&2; problems=$((problems + 1)); }

prefix="${branch%%/*}"
slug="${branch#*/}"

if [[ "$branch" != */* ]]; then
  fail "$branch has no type: name it <type>/<slug>, type one of: $TYPES"
elif [[ " $TOOL_PREFIXES " == *" $prefix "* ]]; then
  fail "$branch is named after a tool; name it after the change: <type>/<slug>, type one of: $TYPES"
elif [[ "$prefix" == "chore" ]]; then
  fail "$branch: there is no chore/ - use deps/ for a version bump, release/ for a release, ci/ for tooling"
elif [[ " $BOT_PREFIXES " == *" $prefix "* ]]; then
  :  # the bot's own scheme; not ours to judge
elif [[ " $TYPES " != *" $prefix "* ]]; then
  fail "$branch: '$prefix/' is not a branch type; use one of: $TYPES"
elif [[ ! "$slug" =~ $SLUG_RE ]]; then
  fail "$branch: the part after '$prefix/' must be lowercase letters, digits, '.', '_' or '-'"
elif [[ "$prefix" == "release" && ! "$slug" =~ $SEMVER_RE ]]; then
  fail "$branch: a release branch is release/MAJOR.MINOR.PATCH, e.g. release/1.0.0"
fi

if [[ -n "$title" ]]; then
  # The type is the first word, up to "(", "!" or ":". Matched case-blind:
  # "Chore:" is the same type to a reader.
  lowered="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lowered" =~ ^chore(\([^\)]*\))?!?: ]]; then
    fail "title '$title' uses the chore type; use the type its branch has (deps:, release:, ci:, ...)"
  fi
fi

if (( problems > 0 )); then
  exit 1
fi
printf '[ ok ] %s\n' "$branch"
exit 0

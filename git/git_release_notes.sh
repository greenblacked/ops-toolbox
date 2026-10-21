#!/usr/bin/env bash
# Print release notes grouped by Conventional Commit type since the last tag.

set -euo pipefail

# --- defaults --------------------------------------------------------------
FROM=""
TO="HEAD"
FORMAT="text"
MATCH='v[0-9]*'
NEXT_VERSION=0

usage() {
  cat <<EOF
git_release_notes.sh - release notes and the next version, from Conventional Commits

Groups the commits between two refs by Conventional Commit type, breaking
changes first, and prints them as text or markdown ready to paste into a
release or a change ticket. The same convention the commit-msg hook from
git_hooks_install.sh enforces, read in the other direction.

Sections, in this order, each printed only when it has commits:

  Breaking changes   a '!' after the type, or a body line 'BREAKING CHANGE:'
  Features           feat
  Fixes              fix
  Performance        perf
  Documentation      docs
  Build and CI       build, ci
  Other              chore, refactor, style, test, revert, any other type, and
                     every subject that is not a Conventional Commit, so
                     nothing is dropped silently

Merge commits are left out.

Usage:
  $(basename "$0") [--from REF] [--to REF] [--format text|markdown] [--match GLOB] [--next-version]

Options:
  --from REF        Start after this ref (default: the nearest tag matching
                    --match reachable from --to, not counting a tag on --to
                    itself; with none, the whole history)
  --to REF          End at this ref (default: HEAD)
  --format FORMAT   text (default) or markdown
  --match GLOB      Tags considered for the default --from (default: v[0-9]*)
  --next-version    Print only the version the commits imply after --from:
                    major for a breaking change, else minor for a feature,
                    else patch. Needs --from to be a MAJOR.MINOR.PATCH tag,
                    with or without a leading v.
  -h, --help        Show this help

A 0.x project often bumps the minor version for a breaking change instead;
--next-version applies the plain semver rule and leaves that call to you.

Read-only: it creates no tag and writes no file. Redirect the output where it
should go. A shallow clone may not have the tag; fetch it with
'git fetch --tags --unshallow' first.

Exit codes: 0 success, 2 not a git repo, 3 usage, bad ref, or a --from tag that
is not semver for --next-version, 4 no commits between FROM and TO
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
    --from)
      require_value "$1" "${2:-}"; shift; FROM="$1" ;;
    --from=*)
      FROM="${1#*=}"; require_value "--from" "$FROM" ;;
    --to)
      require_value "$1" "${2:-}"; shift; TO="$1" ;;
    --to=*)
      TO="${1#*=}"; require_value "--to" "$TO" ;;
    --format)
      require_value "$1" "${2:-}"; shift; FORMAT="$1" ;;
    --format=*)
      FORMAT="${1#*=}"; require_value "--format" "$FORMAT" ;;
    --match)
      require_value "$1" "${2:-}"; shift; MATCH="$1" ;;
    --match=*)
      MATCH="${1#*=}"; require_value "--match" "$MATCH" ;;
    --next-version) NEXT_VERSION=1 ;;
    *)
      printf "unknown argument: %s\n" "$1" >&2
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$FORMAT" in
  text|markdown) ;;
  *)
    printf -- "--format must be text or markdown\n" >&2
    exit 3
    ;;
esac

# --- preflight -------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf "not inside a Git repository\n" >&2
  exit 2
fi

# Every ref is resolved to a commit once; the calls below take the object
# names, so a ref can never be read as an option.
resolve() {
  [[ "$1" != -* ]] || return 1
  git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null
}

if ! to_sha="$(resolve "$TO")"; then
  printf "bad ref: %s\n" "$TO" >&2
  exit 3
fi

from_label="$FROM"
from_sha=""
if [[ -n "$FROM" ]]; then
  if ! from_sha="$(resolve "$FROM")"; then
    printf "bad ref: %s\n" "$FROM" >&2
    exit 3
  fi
else
  from_label="$(git describe --tags --abbrev=0 --match "$MATCH" "$to_sha" 2>/dev/null || true)"
  # A tag on --to itself is the release being described, not the one before
  # it: `--to v1.3.0` wants the notes since v1.2.x, not an empty range.
  if [[ -n "$from_label" && "$(git rev-parse "$from_label^{commit}")" == "$to_sha" ]]; then
    from_label="$(git describe --tags --abbrev=0 --match "$MATCH" "$to_sha^" 2>/dev/null || true)"
  fi
  if [[ -n "$from_label" ]]; then
    from_sha="$(git rev-parse "$from_label^{commit}")"
  else
    printf "no tag matches %s; using the whole history\n" "$MATCH" >&2
  fi
fi

if [[ -n "$from_sha" ]]; then
  shas="$(git rev-list --no-merges --reverse "$from_sha..$to_sha")"
else
  shas="$(git rev-list --no-merges --reverse "$to_sha")"
fi
if [[ -z "$shas" ]]; then
  printf "no commits between %s and %s\n" "${from_label:-the root}" "$TO" >&2
  exit 4
fi

# --- classify --------------------------------------------------------------
# Bash 3.2 has no associative arrays, so each section accumulates in its own
# string and they are printed in a fixed order below.
subject_re='^([a-z]+)(\(([^)]*)\))?(!)?: (.+)$'
if [[ "$FORMAT" == "markdown" ]]; then
  bullet="- "
else
  bullet="  - "
fi

sec_breaking=""
sec_feat=""
sec_fix=""
sec_perf=""
sec_docs=""
sec_build=""
sec_other=""
any_breaking=0
any_feat=0

while IFS= read -r sha; do
  [[ -n "$sha" ]] || continue
  subject="$(git log -1 --format=%s "$sha")"
  body="$(git log -1 --format=%b "$sha")"
  short="$(git rev-parse --short "$sha")"

  type=""
  scope=""
  bang=""
  desc="$subject"
  if [[ "$subject" =~ $subject_re ]]; then
    type="${BASH_REMATCH[1]}"
    scope="${BASH_REMATCH[3]}"
    bang="${BASH_REMATCH[4]}"
    desc="${BASH_REMATCH[5]}"
  fi

  breaking=0
  [[ -n "$bang" ]] && breaking=1
  while IFS= read -r line; do
    case "$line" in
      "BREAKING CHANGE:"*|"BREAKING-CHANGE:"*) breaking=1 ;;
    esac
  done <<<"$body"

  if [[ -n "$scope" ]]; then
    entry="$bullet$scope: $desc ($short)"
  else
    entry="$bullet$desc ($short)"
  fi
  entry="$entry"$'\n'

  if (( breaking == 1 )) && [[ -n "$type" ]]; then
    sec_breaking="$sec_breaking$entry"
    any_breaking=1
    continue
  fi
  case "$type" in
    feat)     sec_feat="$sec_feat$entry"; any_feat=1 ;;
    fix)      sec_fix="$sec_fix$entry" ;;
    perf)     sec_perf="$sec_perf$entry" ;;
    docs)     sec_docs="$sec_docs$entry" ;;
    build|ci) sec_build="$sec_build$entry" ;;
    *)        sec_other="$sec_other$entry" ;;
  esac
done <<<"$shas"

# --- next version ----------------------------------------------------------
if (( NEXT_VERSION == 1 )); then
  semver_re='^v?([0-9]+)\.([0-9]+)\.([0-9]+)$'
  if [[ -z "$from_label" ]]; then
    printf -- "--next-version needs a tag to start from, and no tag matches %s\n" "$MATCH" >&2
    exit 3
  fi
  if [[ ! "$from_label" =~ $semver_re ]]; then
    printf -- "--next-version needs a MAJOR.MINOR.PATCH tag, got: %s\n" "$from_label" >&2
    exit 3
  fi
  # 10# so a component written with a leading zero is not read as octal.
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))
  if (( any_breaking == 1 )); then
    printf "%s.0.0\n" "$((major + 1))"
  elif (( any_feat == 1 )); then
    printf "%s.%s.0\n" "$major" "$((minor + 1))"
  else
    printf "%s.%s.%s\n" "$major" "$minor" "$((patch + 1))"
  fi
  exit 0
fi

# --- print -----------------------------------------------------------------
if git show-ref --verify --quiet "refs/tags/$TO"; then
  title="$TO ($(git for-each-ref --format='%(creatordate:short)' "refs/tags/$TO"))"
elif [[ -n "$from_label" ]]; then
  title="$from_label..$TO"
else
  title="everything up to $TO"
fi

if [[ "$FORMAT" == "markdown" ]]; then
  printf "## %s\n" "$title"
else
  printf "%s\n" "$title"
fi

print_section() {
  local name="$1" lines="$2"
  [[ -n "$lines" ]] || return 0
  if [[ "$FORMAT" == "markdown" ]]; then
    printf "\n### %s\n\n%s" "$name" "$lines"
  else
    printf "\n%s\n%s" "$name" "$lines"
  fi
}

print_section "Breaking changes" "$sec_breaking"
print_section "Features" "$sec_feat"
print_section "Fixes" "$sec_fix"
print_section "Performance" "$sec_perf"
print_section "Documentation" "$sec_docs"
print_section "Build and CI" "$sec_build"
print_section "Other" "$sec_other"
exit 0

#!/usr/bin/env bash
# Assemble CHANGELOG.md from one file per change, so two pull requests never
# edit the same line of it.
#
# Every entry used to be inserted at the top of the [Unreleased] section, which
# is one line in one file: any two branches open at the same time conflicted
# the moment one of them merged, and the resolution was always "keep both".
# A fragment is that entry as its own file, under the directory named for its
# Keep a Changelog type:
#
#   changelog.d/added/<slug>.md
#   changelog.d/changed/<slug>.md
#   changelog.d/deprecated/<slug>.md
#   changelog.d/removed/<slug>.md
#   changelog.d/fixed/<slug>.md
#   changelog.d/security/<slug>.md
#
# A fragment holds one or more list items in the voice CHANGELOG.md already
# uses: a line starting with "- " and continuation lines indented two spaces.
# No heading, no other prose; the heading is the directory it sits in.
#
# Commands:
#   preview           Print the [Unreleased] section as it will read: the
#                     fragments first, then whatever the section already holds,
#                     type by type in Keep a Changelog order. Writes nothing.
#   check             Validate every fragment; exit 1 on the first shape that
#                     would not paste cleanly. Runs in the static suite.
#   release VERSION   Move the fragments and the entries still under
#                     [Unreleased] under "## [VERSION] - DATE", leave
#                     [Unreleased] empty, and delete the fragment files.
#                     --dry-run prints what would happen and writes nothing.
#
# Options:
#   -n, --dry-run     For release: describe the rewrite, change nothing.
#       --date DATE   For release: the date to stamp, YYYY-MM-DD (default: today, UTC).
#   -h, --help        Show this help.
#
# CHANGELOG_ROOT names the directory holding CHANGELOG.md and changelog.d/;
# it defaults to the repository root and exists so the tests can point the
# script at a scratch copy.
#
# Exit codes:
#   0   done
#   1   check found a fragment it would not paste, or release could not proceed
#   3   bad CLI arguments
#   4   release found nothing to release
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CHANGELOG_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CHANGELOG="$ROOT/CHANGELOG.md"
FRAGMENTS="$ROOT/changelog.d"

# Keep a Changelog section order; a type outside this list is a typo.
TYPES="added changed deprecated removed fixed security"

DRY_RUN=0
DATE=""

info()  { printf '[info] %s\n' "$*"; }
ok()    { printf '[ ok ] %s\n' "$*"; }
warn()  { printf '[warn] %s\n' "$*"; }
err()   { printf '[err ] %s\n' "$*" >&2; }

usage() {
  cat <<EOF
changelog.sh - assemble CHANGELOG.md from one fragment per change

Usage:
  $(basename "$0") [--dry-run] [--date DATE] <command> [VERSION]

Commands:
  preview            Print the [Unreleased] section as it will read; writes nothing
  check              Validate every fragment under changelog.d/; exit 1 on a problem
  release VERSION    Move the fragments and the current [Unreleased] entries under
                     "## [VERSION] - DATE" in CHANGELOG.md and delete the fragments

Options:
  -n, --dry-run      For release: print what would change and write nothing
      --date DATE    For release: the date to stamp, YYYY-MM-DD (default: today, UTC)
  -h, --help         Show this help

A fragment is changelog.d/<type>/<slug>.md, where <type> is one of:
  $TYPES
It holds list items only ("- " first line, two-space continuation), in the
voice the entries in CHANGELOG.md already use.

Examples:
  $(basename "$0") preview
  $(basename "$0") check
  $(basename "$0") release 1.0.0 --dry-run
  $(basename "$0") release 1.0.0 --date 2026-10-01

Exit codes: 0 done, 1 problem found, 3 usage, 4 nothing to release
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
# --help is answered before anything is read, so it works in a checkout with
# no CHANGELOG.md at all.
command=""
version=""
while (( $# > 0 )); do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --date)       require_value "$1" "${2:-}"; DATE="$2"; shift ;;
    --date=*)     DATE="${1#*=}"; require_value "--date" "$DATE" ;;
    --)           shift; break ;;
    -*)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
    *)
      if [[ -z "$command" ]]; then
        command="$1"
      elif [[ -z "$version" && "$command" == "release" ]]; then
        version="$1"
      else
        err "unexpected argument: $1"
        usage >&2
        exit 3
      fi
      ;;
  esac
  shift
done
# Anything after a lone -- is positional too.
for extra in "$@"; do
  if [[ -z "$command" ]]; then
    command="$extra"
  elif [[ -z "$version" && "$command" == "release" ]]; then
    version="$extra"
  else
    err "unexpected argument: $extra"
    usage >&2
    exit 3
  fi
done

case "$command" in
  preview|check|release) ;;
  "")
    err "a command is required: preview, check or release"
    usage >&2
    exit 3
    ;;
  *)
    err "unknown command: $command"
    usage >&2
    exit 3
    ;;
esac
if [[ "$command" == "release" && -z "$version" ]]; then
  err "release needs a VERSION"
  usage >&2
  exit 3
fi
if [[ "$command" != "release" && -n "$DATE" ]]; then
  err "--date applies to release only"
  exit 3
fi
if [[ "$command" != "release" && "$DRY_RUN" == 1 ]]; then
  err "--dry-run applies to release only"
  exit 3
fi

# --- helpers ---------------------------------------------------------------
label_of() {
  # added -> Added
  printf '%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')${1:1}"
}

# Fragment files of one type, in a stable order (LC_ALL=C so the order does
# not depend on the caller's locale).
fragments_of() {
  local type="$1" f
  [[ -d "$FRAGMENTS/$type" ]] || return 0
  for f in "$FRAGMENTS/$type"/*.md; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

# Drop blank lines at the top and bottom of stdin; keep the ones in between.
trim_blank() {
  sed -e '/./,$!d' -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

# The three parts of CHANGELOG.md: everything before "## [Unreleased]", the
# body of that section, and everything from the next "## " heading onward.
part_head()       { awk '/^## \[Unreleased\]/{exit} {print}' "$CHANGELOG"; }
part_unreleased() { awk 's==1 && /^## /{exit} s==1{print} /^## \[Unreleased\]/{s=1}' "$CHANGELOG"; }
part_tail()       { awk 's==1 && /^## /{s=2} s==2{print} /^## \[Unreleased\]/{s=1}' "$CHANGELOG"; }

# Lines of [Unreleased] before its first "### " heading: a preamble, if any.
# The reader must not exit early. It used to (`/^### /{exit}`), which closed
# the pipe while part_unreleased was still writing the section body into it:
# the writer died of SIGPIPE, pipefail promoted that to the pipeline's status,
# and `set -e` aborted `preview` with no message and two lines of output. The
# section only has to outgrow one pipe buffer for that to happen, which it
# already has under gawk. Setting a flag and printing nothing after it reads
# the same and consumes all of the input.
unreleased_preamble() { part_unreleased | awk '/^### /{f=1} !f' | trim_blank; }

# The list items already under one "### Label" of [Unreleased].
unreleased_section() {
  part_unreleased | awk -v want="### $1" '/^### /{p=($0==want); next} p{print}' | trim_blank
}

# Count list items in a block of text.
count_items() { grep -c '^- ' || true; }

# Everything that will appear under one type: fragments first, then what the
# section already holds. Empty output means the type has nothing.
assembled_type() {
  local type="$1" label f first=1
  label="$(label_of "$type")"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    (( first )) || printf '\n'
    first=0
    trim_blank < "$f"
  done < <(fragments_of "$type")
  local existing
  existing="$(unreleased_section "$label")"
  if [[ -n "$existing" ]]; then
    (( first )) || printf '\n'
    printf '%s\n' "$existing"
  fi
}

# The whole section body, headings included, for preview and release.
assembled_body() {
  local type body pre
  pre="$(unreleased_preamble)"
  [[ -z "$pre" ]] || printf '%s\n\n' "$pre"
  for type in $TYPES; do
    body="$(assembled_type "$type")"
    [[ -n "$body" ]] || continue
    printf '### %s\n\n%s\n\n' "$(label_of "$type")" "$body"
  done
}

need_changelog() {
  if [[ ! -f "$CHANGELOG" ]]; then
    err "no CHANGELOG.md at $ROOT"
    exit 1
  fi
  if ! grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
    err "$CHANGELOG has no '## [Unreleased]' heading"
    exit 1
  fi
  # `grep` exits 1 when the section has no headings at all, which is the
  # state right after a release; `|| true` keeps that from tripping `set -e`
  # inside the substitution.
  local unknown
  unknown="$(part_unreleased | { grep '^### ' || true; } | sed 's/^### //' | while IFS= read -r l; do
    case " $(for t in $TYPES; do label_of "$t"; printf ' '; done)" in
      *" $l "*) ;;
      *) printf '%s\n' "$l" ;;
    esac
  done)"
  if [[ -n "$unknown" ]]; then
    err "[Unreleased] has a section this script does not know: $unknown"
    exit 1
  fi
}

# --- check -----------------------------------------------------------------
do_check() {
  local problems=0 count=0 f rel type base
  if [[ ! -d "$FRAGMENTS" ]]; then
    err "no changelog.d/ at $ROOT"
    return 1
  fi
  # Anything at the top level other than the script, its README and the lint
  # config is a fragment that missed its type directory.
  #
  # Dot-files are deliberately not enumerated here or below. They are never
  # pasted (fragments_of globs *.md, with dotglob off), so counting one as a
  # fragment promised an entry that release then silently dropped; and the
  # ones that actually turn up are .DS_Store, which Finder writes unbidden on
  # the machines this repository targets, and a .swp for as long as a fragment
  # is open in vim - both gitignored, and neither a reason to fail the static
  # suite. What check enumerates now matches what release pastes.
  for f in "$FRAGMENTS"/*; do
    [[ -e "$f" ]] || continue
    base="${f##*/}"
    if [[ -d "$f" ]]; then
      case " $TYPES " in
        *" $base "*) ;;
        *) err "changelog.d/$base/ is not a changelog type (one of: $TYPES)"; problems=$((problems + 1)) ;;
      esac
      continue
    fi
    case "$base" in
      README.md|changelog.sh|.markdownlint-cli2.yaml) ;;
      *) err "changelog.d/$base sits outside a type directory; move it under changelog.d/<type>/"; problems=$((problems + 1)) ;;
    esac
  done
  for type in $TYPES; do
    [[ -d "$FRAGMENTS/$type" ]] || continue
    for f in "$FRAGMENTS/$type"/*; do
      [[ -e "$f" ]] || continue
      rel="changelog.d/$type/${f##*/}"
      if [[ ! -f "$f" ]]; then
        err "$rel is not a file"; problems=$((problems + 1)); continue
      fi
      case "$f" in
        *.md) ;;
        *) err "$rel: a fragment is a .md file"; problems=$((problems + 1)); continue ;;
      esac
      # -s catches a zero-byte file; a file of nothing but newlines is just
      # as empty, and reached no validation at all below, because the awk rule
      # that skips blank lines fires before the one that requires an item. It
      # contributed nothing and left two blank lines behind it in the pasted
      # section, which markdownlint counts as MD012.
      if [[ ! -s "$f" ]] || ! grep -q '[^[:space:]]' "$f"; then
        err "$rel is empty"; problems=$((problems + 1)); continue
      fi
      # Shape: first non-blank line is an item; every other line is an item, a
      # two-space continuation, or blank; no headings, tabs or trailing spaces;
      # ends with a newline so it pastes cleanly.
      local bad
      bad="$(awk '
        BEGIN { first = 1 }
        /^[[:space:]]*$/ { next }
        first && !/^- /   { print NR ": first line must start with \"- \""; first = 0; next }
        { first = 0 }
        /^#/              { print NR ": a fragment has no headings; its type is its directory" }
        /\t/              { print NR ": tab character" }
        /[[:space:]]$/    { print NR ": trailing whitespace" }
        !/^- / && !/^  /  { print NR ": a line is an item (\"- \") or a two-space continuation" }
      ' "$f")"
      if [[ -n "$bad" ]]; then
        err "$rel:"
        printf '%s\n' "$bad" | sed 's/^/       line /' >&2
        problems=$((problems + 1)); continue
      fi
      if [[ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" != '\n' ]]; then
        err "$rel does not end with a newline"; problems=$((problems + 1)); continue
      fi
      count=$((count + 1))
      ok "$rel"
    done
  done
  if (( problems > 0 )); then
    err "$problems fragment problem(s)"
    return 1
  fi
  ok "$count fragment(s) would paste cleanly"
  return 0
}

# --- preview ---------------------------------------------------------------
do_preview() {
  need_changelog
  printf '## [Unreleased]\n\n'
  assembled_body
}

# --- release ---------------------------------------------------------------
do_release() {
  need_changelog
  do_check >/dev/null || { err "fix the fragments before releasing"; exit 1; }
  if [[ "$version" == *[[:space:]]* || "$version" == "["* ]]; then
    err "VERSION must be a single token without brackets: $version"
    exit 3
  fi
  if [[ -z "$DATE" ]]; then
    DATE="$(date -u +%Y-%m-%d)"
  elif [[ ! "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    err "--date must be YYYY-MM-DD: $DATE"
    exit 3
  fi
  if grep -q "^## \[$version\]" "$CHANGELOG"; then
    err "CHANGELOG.md already has a section for [$version]"
    exit 1
  fi

  local body total from_fragments f
  body="$(assembled_body)"
  total="$(printf '%s\n' "$body" | count_items)"
  from_fragments=0
  local fragment_files=""
  for type in $TYPES; do
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      from_fragments=$((from_fragments + $(count_items < "$f")))
      fragment_files="$fragment_files$f"$'\n'
    done < <(fragments_of "$type")
  done
  if (( total == 0 )); then
    warn "nothing to release: no fragments and [Unreleased] is empty"
    (( DRY_RUN )) && printf 'dry-run complete; no changes written\n'
    exit 4
  fi

  local heading="## [$version] - $DATE"
  if (( DRY_RUN )); then
    printf 'dry-run: would write CHANGELOG.md: "%s" with %s entries (%s from fragments)\n' \
      "$heading" "$total" "$from_fragments"
    printf '%s' "$fragment_files" | while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      printf 'dry-run: would remove %s\n' "${f#"$ROOT"/}"
    done
    printf 'dry-run complete; no changes written\n'
    return 0
  fi

  # The head is streamed so its trailing blank line survives; the tail goes
  # through a substitution so a blank line can be put before its first
  # heading only when there is a tail at all.
  local tmp rest
  tmp="$CHANGELOG.tmp.$$"
  rest="$(part_tail)"
  {
    part_head
    printf '## [Unreleased]\n\n'
    printf '%s\n\n' "$heading"
    printf '%s\n' "$body"
    [[ -z "$rest" ]] || printf '\n%s\n' "$rest"
  } > "$tmp"
  mv "$tmp" "$CHANGELOG"
  ok "wrote CHANGELOG.md: \"$heading\" with $total entries ($from_fragments from fragments)"
  printf '%s' "$fragment_files" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rm -f "$f"
    ok "removed ${f#"$ROOT"/}"
  done
  info "commit CHANGELOG.md and the removed fragments together; the [Unreleased] section is empty again"
}

case "$command" in
  preview) do_preview ;;
  check)   do_check ;;
  release) do_release ;;
esac

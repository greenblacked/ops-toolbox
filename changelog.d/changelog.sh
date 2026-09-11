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
#   check             Validate every fragment: the shape that would not paste
#                     cleanly, and the claims it makes about the tree it ships
#                     with — a file or a long flag named in backticks that is
#                     nowhere in this checkout. Runs in the static suite.
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
  check              Validate every fragment under changelog.d/ — its shape, and the
                     files and flags it names against this tree; exit 1 on a problem
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

# --- claims ----------------------------------------------------------------
# The shape check below asks whether a fragment would paste. It does not ask
# whether it is true, and two pull requests shipped fragments describing work
# that was never committed: #36 said `v1_stay_fresh.sh` had grown a
# `--legacy-run` opt-in, #37 said `install_apps.sh` "grew `--list-casks` and
# `--list-formulae`" and listed twelve new Homebrew entries. Both branches held
# nothing but the fragments. Both passed check, because both would have pasted
# perfectly. A fragment was a promise nothing tested.
#
# Prose cannot be validated. Two forms in it can, and they are the two the
# incidents turned on: a file named in backticks should be in the tree, and a
# long flag named in backticks should be one some script here accepts. The
# scoping is the whole design — a check that fires on correct writing is a
# check people learn to work around, and test_doc_citations.sh already carries
# the scar of that (it dropped bare `name.sh` in prose after flagging the
# hostname `formulae.brew.sh`). So:
#
#   * A code span is one span even when it wraps onto a continuation line, and
#     only its first word can name a file. `winget upgrade --all
#     --include-unknown --accept-package-agreements` is one quoted command line
#     for another tool, not four claims about this repository.
#   * A flag is claimed only when it stands alone in its span. That is the line
#     between "this repository accepts `--list-casks`" and the borrowed flags
#     the fragments quote constantly — `brew --cache`, `apt-get --yes`,
#     `find -delete`, `git add -A`, `sed -i` — every one of which names its
#     tool inside the span. Write a borrowed flag that way and it is not a
#     claim about this tree. Single-dash flags are not claimed at all: that is
#     where the other tools live, and telling `-Yes` (PowerShell, ours) from
#     `-printf` (find, not ours) needs a list of other people's CLIs.
#   * A flag claim is resolved against the scripts its own item names, and only
#     against the whole tree when the item names none. Item scope is what makes
#     it bite: `--list-casks` was nowhere, but a repo-wide search for a
#     `--yes` or a `--dry-run` finds one in some other script and passes
#     anything. Item, not sentence — an entry may name its script in one
#     sentence and its new flag in the next — and any one of the named scripts
#     satisfies it, because "`install_devtools.sh` and `stay_fresh.sh` learned
#     `--trend`" is true when one of them did. Requiring all of them was tried
#     against the fragments in the tree and produced five false reports.
#   * An invocation — `./x.sh`, `.\stay_fresh.ps1` — is not a file claim. The
#     fragment on file modes writes "every usage line in the repository is
#     written `./x.sh`", which is prose about a form, not about a file.
#   * A file extension is a source extension. Fragments name runtime state in
#     backticks too — `last-run.json`, `history.tsv`, `steps.tsv` — and those
#     are written on the machine, not committed here.
#   * Removal wording ("removed", "deleted", "no longer", "renamed",
#     "formerly", "retired", "replaced by", "gone") exempts the *sentence* it
#     sits in, not the whole entry. A fragment about a deletion has to be able
#     to name what it deleted; but #36's own first sentence was "`v1_stay_fresh.sh`
#     no longer runs its fixed cleanup", and exempting the entry would have
#     exempted the `--legacy-run` claim two sentences later — the one lie here
#     that is mechanically catchable.
#
# What this does NOT catch, so nobody reads a pass as more than it is: #36's
# other fragment claimed the installers "refuse a non-interactive real run that
# omitted `--yes`". Both installers already contained `--yes`; the claim was
# about behaviour, and behaviour is what the package suites are for.
#
# Claims are resolved against the tree under ROOT — the working tree, not the
# index, so a file created but not yet `git add`ed satisfies a claim locally.
# CI checks out the branch, where the two are the same thing, and that is the
# gate that caught nothing before this existed.

# Emits one claim per line: KIND \t item-line \t exempt \t value.
# The item's lines are joined before they are read, so a span that wraps is one
# span. Deliberately POSIX awk: no interval expressions (the awk on older macOS
# matches them literally), no gensub, no delete-whole-array.
CLAIM_AWK='
BEGIN { item = 0; buf = ""; c = 0 }
/^- / { flush(); item = NR; buf = $0; next }
      { buf = (buf == "" ? $0 : buf " " $0) }
END   { flush() }

function add(kind, value, sid) { c++; ck[c] = kind; cv[c] = value; cs[c] = sid }

function record(span, sid,   first, base, d) {
  gsub(/^[ \t]+|[ \t]+$/, "", span)
  if (span == "") return
  if (span ~ /^--[A-Za-z][A-Za-z0-9-]*$/) { add("FLAG", span, sid); return }
  first = span; sub(/[ \t].*$/, "", first)
  if (first ~ /\\/ || first ~ /^\.\//) return
  if (first !~ /^[A-Za-z0-9_.~\/-]+\.(sh|zsh|ps1|psm1|psd1|py|lua|awk|md)$/) return
  base = first; sub(/^.*\//, "", base)
  d = gsub(/\./, ".", base)
  if (d != 1) return
  add("FILE", first, sid)
}

function flush(   n, part, i, p, sid, j, ex) {
  if (buf == "") return
  n = split(buf, part, "`")
  sid = 1; stext[1] = ""
  for (i = 1; i <= n; i++) {
    if (i % 2 == 1) {
      p = part[i]
      while (match(p, /\. /)) {
        stext[sid] = stext[sid] substr(p, 1, RSTART + RLENGTH - 1)
        sid++; stext[sid] = ""
        p = substr(p, RSTART + RLENGTH)
      }
      stext[sid] = stext[sid] p
    } else {
      stext[sid] = stext[sid] part[i]
      if (i < n) record(part[i], sid)
    }
  }
  for (j = 1; j <= c; j++) {
    ex = (tolower(stext[cs[j]]) ~ /remove|delet|no longer|renamed|formerly|retired|replaced by|gone/) ? 1 : 0
    printf "%s\t%d\t%d\t%s\n", ck[j], item, ex, cv[j]
  }
  c = 0; buf = ""
  split("", stext)
}
'

TREE_INDEX=""
SCRIPT_FILES=()
CLAIMS_FILE=0
CLAIMS_FLAG=0
CLAIMS_EXEMPT=0
CLAIM_PROBLEMS=0

# Every file under ROOT, repo-relative. .git is pruned for speed and for
# honesty: a branch name in .git/logs mentioning a flag is not a script that
# accepts it, and the first draft passed on exactly that.
build_tree_index() {
  local p
  TREE_INDEX="$(cd "$ROOT" && find . \
    -name .git -prune -o -name __pycache__ -prune -o -name .ruff_cache -prune -o \
    -type f -print | sed 's|^\./||' | LC_ALL=C sort)"
  SCRIPT_FILES=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    SCRIPT_FILES[${#SCRIPT_FILES[@]}]="$ROOT/$p"
  done <<< "$({ grep -E '\.(sh|zsh|ps1|psm1|py|lua|awk)$' <<< "$TREE_INDEX"; } || true)"
}

# Paths in the tree ending in this token at a path-segment boundary, so a fragment
# may name `install_apps.sh` or `macos-initial-setup/install_apps.sh` and mean
# the same file. A bare basename that matches two files (there are two
# stay_fresh.sh) resolves to both; the fragment has not said which.
paths_named() {
  local esc="${1//./\\.}"
  { grep -E "(^|/)$esc\$" <<< "$TREE_INDEX"; } || true
}

# The flag as a script would write it: not preceded by another dash, and not
# the prefix of a longer flag, so a claim on `--list` is not satisfied by
# `--list-casks`.
flag_pattern() { printf '(^|[^-[:alnum:]])%s([^-A-Za-z0-9_]|$)' "$1"; }

check_claims() {
  local f="$1" rel="$2"
  local claims items item kind ln ex value hits h pat scope bad=0
  # `|| true` rather than letting set -e take it: an awk that cannot run is a
  # broken check, and the floor above is what says so out loud. Exiting here
  # would leave no message at all.
  claims="$(awk "$CLAIM_AWK" "$f")" || true
  [[ -n "$claims" ]] || return 0
  items="$(cut -f2 <<< "$claims" | uniq)"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    local named=() named_rel=""
    # The file claims of this item come first: they are what a flag claim in
    # the same item is resolved against.
    while IFS=$'\t' read -r kind ln ex value; do
      [[ "$kind" == "FILE" && "$ln" == "$item" ]] || continue
      if [[ "$ex" == 1 ]]; then CLAIMS_EXEMPT=$((CLAIMS_EXEMPT + 1)); else CLAIMS_FILE=$((CLAIMS_FILE + 1)); fi
      hits="$(paths_named "$value")"
      if [[ -z "$hits" ]]; then
        # Exempt means "do not fail when it is gone", not "do not look": a
        # removal sentence that does resolve still scopes this item's flags.
        # It has to. #36's entry opened "`v1_stay_fresh.sh` no longer runs its
        # fixed cleanup" — its only mention of the script — and announced
        # `--legacy-run` three sentences later. Dropping the exempt mention
        # from the scope sent that flag to a repo-wide search, which found it
        # in the script's own test file and passed the lie.
        [[ "$ex" == 1 ]] || { err "$rel:$ln names \`$value\`, which is not a file in this tree"; bad=$((bad + 1)); }
        continue
      fi
      while IFS= read -r h; do
        # A README is not a CLI: a flag documented in Markdown and implemented
        # nowhere is the half-done change this is here to catch.
        case "$h" in
          *.md) ;;
          *)
            named[${#named[@]}]="$ROOT/$h"
            if [[ -z "$named_rel" ]]; then named_rel="$h"; else named_rel="$named_rel, $h"; fi
            ;;
        esac
      done <<< "$hits"
    done <<< "$claims"
    while IFS=$'\t' read -r kind ln ex value; do
      [[ "$kind" == "FLAG" && "$ln" == "$item" ]] || continue
      if [[ "$ex" == 1 ]]; then CLAIMS_EXEMPT=$((CLAIMS_EXEMPT + 1)); continue; fi
      CLAIMS_FLAG=$((CLAIMS_FLAG + 1))
      pat="$(flag_pattern "$value")"
      if (( ${#named[@]} > 0 )); then
        grep -qE -- "$pat" "${named[@]}" && continue
        if (( ${#named[@]} > 1 )); then
          scope="none of $named_rel accepts"
        else
          scope="$named_rel does not accept"
        fi
        err "$rel:$ln says \`$value\`, which $scope"
      else
        if (( ${#SCRIPT_FILES[@]} > 0 )); then
          grep -qE -- "$pat" "${SCRIPT_FILES[@]}" && continue
        fi
        err "$rel:$ln says \`$value\`, which no script in this tree accepts"
      fi
      bad=$((bad + 1))
    done <<< "$claims"
  done <<< "$items"
  CLAIM_PROBLEMS=$((CLAIM_PROBLEMS + bad))
  (( bad == 0 ))
}

# Every check in this repository carries a guard against having quietly stopped
# checking. The usual one — "it inspected zero subjects" — cannot be used here:
# changelog.d/ is legitimately empty right after a release, and a fragment is
# allowed to be prose with no backticks in it, so zero claims is a normal
# Tuesday. The guard is a canary instead: one line carrying one file claim, one
# flag claim and one sentence that exempts itself, pushed through the same
# extractor the fragments go through. If the span reader, the classifier, the
# sentence split or the removal wording stops working, this stops matching and
# says so, whatever the fragments happen to contain.
claim_floor() {
  local got want
  want='FILE 1 0 canary_floor.sh FLAG 1 0 --canary-floor FILE 1 1 canary_gone.sh'
  got="$(awk "$CLAIM_AWK" <<EOF | tr '\t\n' '  '
- \`canary_floor.sh\` grew \`--canary-floor\`. The old \`canary_gone.sh\` was removed.
EOF
)" || true
  got="${got%"${got##*[![:space:]]}"}"
  if [[ "$got" != "$want" ]]; then
    err "the claim extractor no longer reads its own canary — this check has stopped checking"
    err "       wanted: $want"
    err "       got:    ${got:-(nothing)}"
    return 1
  fi
  return 0
}

# --- check -----------------------------------------------------------------
do_check() {
  local problems=0 count=0 f rel type base
  if [[ ! -d "$FRAGMENTS" ]]; then
    err "no changelog.d/ at $ROOT"
    return 1
  fi
  build_tree_index
  # A claim check that cannot read its own canary reads nothing; running it
  # over fifty fragments would bury that one line under fifty copies of
  # whatever awk is complaining about.
  local claims_ok=1
  claim_floor || { problems=$((problems + 1)); claims_ok=0; }
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
      # Shape first, claims second: a fragment that would not paste is already
      # a failure, and reading the tree for it would only bury that line.
      if (( claims_ok == 0 )); then
        ok "$rel"
      elif check_claims "$f" "$rel"; then
        ok "$rel"
      else
        problems=$((problems + 1))
      fi
    done
  done
  if (( problems > 0 )); then
    err "$problems fragment problem(s)"
    if (( CLAIM_PROBLEMS > 0 )); then
      err "a fragment is checked against the tree it ships with: add the file or the flag,"
      err "correct the name, say the change removes it, or — for another tool's flag —"
      err "write it in the span with its tool, the way \`brew --cache\` already is"
    fi
    return 1
  fi
  ok "$count fragment(s) would paste cleanly"
  ok "$CLAIMS_FILE file and $CLAIMS_FLAG flag claim(s) hold against this tree ($CLAIMS_EXEMPT about removals, not checked)"
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

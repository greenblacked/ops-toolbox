#!/usr/bin/env bash
# The documentation cites the scripts. Nothing checked that the citations were
# true, and they rotted: CONTRIBUTING.md pointed at git_sync_default.sh:25-33
# for a function that had moved to 27, at stay_fresh.sh:357-405 for one that had
# moved to 499, and at windows/README.md:29-31 for a rule that was no longer in
# that file at all. Every one of those was written accurately and went stale
# underneath, because a line number does not survive an edit above it.
#
# So this checks the three things that can be checked mechanically:
#
#   1. no line-number citations at all — they are the format that rots
#   2. every relative link resolves
#   3. every "`fn()` in `path`" citation resolves to a function in that file
#   4. every package README names the scripts beside it, and documents no
#      script that is not there
#
# What is deliberately NOT checked: a bare `name.sh` written in prose. The
# first draft did check those and flagged `formulae.brew.sh` (a hostname) and
# a README's own note that v1_stay_fresh.sh was "formerly old_stay_fresh.sh".
# Both are correct prose. A check that has to grow an exemption list for
# correct writing is the check people switch off, so this one stays on the
# three forms that are unambiguous claims about the tree.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
cd "$REPO_ROOT" || { echo "cannot enter $REPO_ROOT" >&2; exit 1; }

failures=0
ok()   { printf '[ ok ] %s\n' "$*"; }
err()  { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
head_() { printf '\n--- %s ---\n' "$*"; }

docs=()
while IFS= read -r f; do docs+=("$f"); done < <(git ls-files '*.md')

# --------------------------------------------------------------------------
head_ "no line-number citations"
# CHANGELOG.md is history: an entry describing a bug at the line it lived on
# stays true of the commit it describes, so it is exempt rather than rewritten.
found=0
for f in "${docs[@]}"; do
  case "$f" in CHANGELOG.md) continue ;; esac
  hits="$(grep -noE '`[A-Za-z0-9_./-]+\.(sh|py|ps1|psd1|lua|yml|yaml):[0-9]+(-[0-9]+)?`' "$f")"
  if [[ -n "$hits" ]]; then
    err "$f cites a line number; cite the function or the file instead"
    printf '%s\n' "$hits" | sed 's/^/       /' >&2
    found=$((found + 1))
  fi
done
(( found == 0 )) && ok "no document cites a line number"

# --------------------------------------------------------------------------
head_ "relative links resolve"
# markdownlint does not check link targets. docs/good-first-issues.md was
# deleted while README.md and CONTRIBUTING.md still linked to it, and the lint
# job passed.
broken=0
for f in "${docs[@]}"; do
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    case "$target" in http://*|https://*|mailto:*|'#'*) continue ;; esac
    path="${target%%#*}"
    [[ -n "$path" ]] || continue
    if [[ ! -e "$(dirname "$f")/$path" ]]; then
      err "$f links to $path, which does not exist"
      broken=$((broken + 1))
    fi
  done < <(grep -hoE '\]\([^)]+\)' "$f" | sed 's/^](//; s/)$//')
done
(( broken == 0 )) && ok "every relative link in a document resolves"

# --------------------------------------------------------------------------
head_ "function citations resolve"
# The form CONTRIBUTING.md uses now: `run_cmd()` in `macos-initial-setup/stay_fresh.sh`.
bad_fn=0
checked_fn=0
for f in "${docs[@]}"; do
  while IFS= read -r line; do
    fn="${line%%|*}"
    path="${line##*|}"
    [[ -n "$fn" && -n "$path" ]] || continue
    if [[ ! -f "$path" ]]; then
      err "$f cites $fn() in $path, which is not a file"
      bad_fn=$((bad_fn + 1))
      continue
    fi
    checked_fn=$((checked_fn + 1))
    if ! grep -qE "^[[:space:]]*(function )?${fn}\(\)[[:space:]]*\{" "$path"; then
      err "$f cites $fn() in $path, which does not define it"
      bad_fn=$((bad_fn + 1))
    fi
  done < <(grep -hoE '`[a-z_][a-z0-9_]*\(\)` in `[A-Za-z0-9_./-]+\.(sh|py)`' "$f" \
             | sed 's/`//g; s/() in /|/')
done
if (( checked_fn == 0 )); then
  ok "no function citations to check"
elif (( bad_fn == 0 )); then
  ok "all $checked_fn function citations resolve"
fi

# --------------------------------------------------------------------------
head_ "package READMEs name their scripts"
# Both directions, because both have failed here. Forward: mikrotik once took a
# batch of twelve scripts with no README entry, which is why that package grew
# its own drift check. Reverse: a heading for a script somebody deleted outlives
# the script, and markdownlint has no opinion about it.
#
# A script belongs to the NEAREST README above it, not to every README above it.
# The first draft used `git ls-files "$pkg/*.sh"`, and git pathspec globs cross
# directory boundaries: windows/README.md was silently held to naming the eight
# scripts under windows/setup/ and windows/wsl/, each was counted twice, and
# both error messages named the wrong directory.
#
# Packages are discovered, not listed. The macOS suite's hardcoded script list
# is how launchd/stay_fresh_agent.sh stopped being covered. test-env/ is
# excluded wholesale, the same rule discover_clis.sh uses; so is the repository
# root, whose README is an index of packages rather than a package README.
readmes="$(mktemp)"; mentions="$(mktemp)"
trap 'rm -f "$readmes" "$mentions"' EXIT
# The pathspec is a glob over the whole path, so '*README.md' also matches
# LEGACY_README.md and DESIGN_README.md. The first invented a second entry for
# a package that already had one (orphan headings reported twice) and the
# second invented a package whose README.md does not exist, so the reverse loop
# grepped a missing file. Match the basename exactly.
git ls-files '*README.md' | while IFS= read -r r; do
  [ "${r##*/}" = "README.md" ] || continue
  d="$(dirname "$r")"
  case "$d" in .|test-env|test-env/*) continue ;; esac
  printf '%s\n' "$d"
done > "$readmes"

fwd_missing=0
rev_missing=0
scripts_seen=0
pkgs="$(wc -l < "$readmes" | tr -d ' ')"

# Forward: every script is named in the README of its nearest package.
while IFS= read -r f; do
  case "$f" in */tests/*|test-env/*|run-tests.sh) continue ;; esac
  owner=""
  d="$(dirname "$f")"
  while [ "$d" != "." ] && [ -n "$d" ]; do
    if grep -qxF "$d" "$readmes"; then owner="$d"; break; fi
    d="$(dirname "$d")"
  done
  # Skipping this silently was the largest hole: a brand-new package, or one
  # whose README was deleted, took its scripts out of coverage and left the
  # suite green. Every shipped script lives in a package that documents it.
  if [ -z "$owner" ]; then
    err "$f has no package README above it; add one, or move the script into a package"
    fwd_missing=$((fwd_missing + 1))
    continue
  fi
  scripts_seen=$((scripts_seen + 1))
  base="${f##*/}"
  # Whole-token match at both ends. Without the left boundary the class
  # provides, `v1_stay_fresh.sh` in the prose counts as `stay_fresh.sh`;
  # without the right one, prose about `deploy.shtml` counts as `deploy.sh`.
  # The trailing boundary character, when there is one, is then stripped.
  grep -oE '[A-Za-z0-9_./-]+\.(sh|py|lua|ps1)([^A-Za-z0-9_]|$)' "$owner/README.md" \
    | sed 's/[^A-Za-z0-9]$//; s#.*/##' | sort -u > "$mentions"
  # -F, because the filename is data: an undocumented `bash.aliases.sh` used as
  # a pattern matches the documented `bash_aliases.sh`.
  grep -qxF "$base" "$mentions" && continue
  err "$owner/README.md does not mention $base, which ships beside it"
  fwd_missing=$((fwd_missing + 1))
done < <(git ls-files '*.sh' '*.py' '*.lua' '*.ps1')

# Reverse: a heading naming a script is a claim that the script is there. The
# name may carry a path — `## `launchd/stay_fresh_agent.sh`` — so the pattern
# has to allow a slash. Leaving it out exempted the two scripts documented that
# way, one of them the file this block's own comment cites as the reason it
# exists. Run for every package README, including one whose scripts have all
# been deleted: that is precisely when a heading is left orphaned.
while IFS= read -r pkg; do
  while IFS= read -r named; do
    [ -n "$named" ] || continue
    [ -f "$pkg/$named" ] && continue
    err "$pkg/README.md has a section for $named, which is not in $pkg/"
    rev_missing=$((rev_missing + 1))
  done < <(grep -hoE '^#+ `[A-Za-z0-9_./-]+\.(sh|py|lua|ps1)`' "$pkg/README.md" \
             | sed 's/^#* *//; s/`//g')
done < "$readmes"

if (( pkgs == 0 || scripts_seen == 0 )); then
  err "discovered $pkgs package README(s) and $scripts_seen script(s) — this check has stopped checking"
else
  (( fwd_missing == 0 )) && ok "every script is named in its package README ($scripts_seen across $pkgs packages)"
  (( rev_missing == 0 )) && ok "every documented script section has a script"
fi

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%d documentation citation check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all documentation citation checks passed (%d documents) ===\n' "${#docs[@]}"
exit 0

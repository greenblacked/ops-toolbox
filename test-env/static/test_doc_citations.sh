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
printf '\n'
if (( failures > 0 )); then
  printf '%d documentation citation check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all documentation citation checks passed (%d documents) ===\n' "${#docs[@]}"
exit 0

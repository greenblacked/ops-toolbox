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
# Packages are discovered, not listed. A hardcoded package list is the thing
# that rots — the macOS suite's hardcoded script list silently stopped covering
# launchd/stay_fresh_agent.sh, which is the defect this whole family of checks
# exists to prevent. Anything with a README and a script beside it is in scope;
# test-env/ is excluded wholesale, the same rule discover_clis.sh uses.
fwd_missing=0
rev_missing=0
pkgs=0
scripts_seen=0
while IFS= read -r readme; do
  pkg="$(dirname "$readme")"
  # The root README is an index of packages, not a package README; holding it
  # to "name every script beside you" would mean every script in the tree.
  case "$pkg" in .|test-env|test-env/*) continue ;; esac

  pkg_scripts=""
  while IFS= read -r f; do
    case "$f" in */tests/*) continue ;; esac
    pkg_scripts="$pkg_scripts ${f##*/}"
  done < <(git ls-files "$pkg/*.sh" "$pkg/*.py" "$pkg/*.lua" "$pkg/*.ps1")
  [ -n "$pkg_scripts" ] || continue
  pkgs=$((pkgs + 1))

  for base in $pkg_scripts; do
    scripts_seen=$((scripts_seen + 1))
    grep -qF -- "$base" "$readme" && continue
    err "$readme does not mention $base, which ships beside it"
    fwd_missing=$((fwd_missing + 1))
  done

  # A heading is a stronger claim than a mention: it documents the script.
  while IFS= read -r named; do
    [ -n "$named" ] || continue
    case " $pkg_scripts " in *" $named "*) continue ;; esac
    err "$readme has a section for $named, which is not in $pkg/"
    rev_missing=$((rev_missing + 1))
  done < <(grep -hoE '^#+ `[A-Za-z0-9_.-]+\.(sh|py|lua|ps1)`' "$readme" \
             | sed 's/^#* *//; s/`//g')
done < <(git ls-files '*README.md')

(( fwd_missing == 0 )) && ok "every script is named in its package README ($scripts_seen across $pkgs packages)"
(( rev_missing == 0 )) && ok "every documented script section has a script"

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%d documentation citation check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all documentation citation checks passed (%d documents) ===\n' "${#docs[@]}"
exit 0

#!/usr/bin/env bash
# Repository-wide convention checks. No Docker, no network, no package manager —
# just bash, git and the scripts themselves.
#
# This suite exists because the per-package suites hardcode which scripts they
# check, and those lists drift: the macOS suite silently stopped covering
# brewfile.sh and launchd/stay_fresh_agent.sh. Everything here discovers its own
# subjects, so a new script is covered by the commit that creates it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
cd "$REPO_ROOT" || { echo "cannot enter $REPO_ROOT" >&2; exit 1; }

# shellcheck source=../lib/discover_clis.sh
. "$REPO_ROOT/test-env/lib/discover_clis.sh"

failures=0
checked=0
ok()   { printf '[ ok ] %s\n' "$*"; }
err()  { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
head_() { printf '\n--- %s ---\n' "$*"; }

# Packages whose scripts must run under the Bash 3.2 that ships as /bin/bash on
# macOS. Deliberately not repository-wide: windows/git-bash/ targets Git Bash
# (bash 5) and uses local -A and globstar on purpose, and ci.yml uses mapfile.
BASH32_DIRS="git macos-initial-setup linux"

# --------------------------------------------------------------------------
head_ "discovery"
clis=()
while IFS= read -r -d '' f; do
  clis+=("$f")
done < <(discover_clis "$REPO_ROOT")

if (( ${#clis[@]} == 0 )); then
  err "discovered no command-line scripts at all — discovery is broken"
  exit 1
fi
ok "discovered ${#clis[@]} command-line scripts"

# --------------------------------------------------------------------------
head_ "--help contract"
# --help must work before any preflight check, which is what lets a macOS-only
# script answer --help on this Linux runner. That ordering is the whole point.
for f in "${clis[@]}"; do
  checked=$((checked + 1))
  out=""
  rc=0
  out="$("./$f" --help 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    err "$f --help exited $rc, expected 0"
  elif [[ -z "${out//[[:space:]]/}" ]]; then
    err "$f --help printed nothing"
  else
    ok "$f --help"
  fi
done

# --------------------------------------------------------------------------
head_ "unknown-flag contract"
# Bash scripts exit 3 on an unrecognised flag. The Python helpers use argparse,
# which exits 2 by its own convention and is not worth fighting — they are
# checked for --help above, and for nothing here.
for f in "${clis[@]}"; do
  case "$f" in *.py) continue ;; esac
  rc=0
  "./$f" --definitely-not-a-valid-flag-12345 >/dev/null 2>&1
  rc=$?
  if (( rc == 3 )); then
    ok "$f unknown flag -> 3"
  else
    err "$f unknown flag exited $rc, expected 3"
  fi
done

# --------------------------------------------------------------------------
head_ "shebangs"
for f in "${clis[@]}"; do
  first="$(head -n 1 -- "$f")"
  case "$f" in
    *.sh)
      if [[ "$first" == "#!/usr/bin/env bash" ]]; then
        ok "$f shebang"
      else
        err "$f line 1 is '$first', expected '#!/usr/bin/env bash'"
      fi
      ;;
    *.py)
      if [[ "$first" == "#!/usr/bin/env python3" ]]; then
        ok "$f shebang"
      else
        err "$f line 1 is '$first', expected '#!/usr/bin/env python3'"
      fi
      ;;
  esac
done

# --------------------------------------------------------------------------
head_ "file modes"
# A file marked executable that has no shebang is either a mistake or a sourced
# file someone will try to run. macos-initial-setup/README.md and
# zsh_aliases.zsh were both tracked 100755 before this check existed.
while IFS= read -r -d '' record; do
  mode="${record%% *}"
  path="${record#*$'\t'}"
  [[ "$mode" == "100755" ]] || continue
  if head -n 1 -- "$path" | grep -q '^#!'; then
    continue
  fi
  err "$path is mode 755 but has no shebang"
done < <(git ls-files -s -z)
ok "no executable file lacks a shebang"

while IFS= read -r -d '' record; do
  mode="${record%% *}"
  path="${record#*$'\t'}"
  case "$path" in
    *.zsh)
      [[ "$mode" == "100644" ]] || err "$path is sourced, so it should be mode 644, not $mode"
      ;;
    *.md)
      [[ "$mode" == "100644" ]] || err "$path is documentation, so it should be mode 644, not $mode"
      ;;
  esac
done < <(git ls-files -s -z)
ok "sourced files and documentation are not executable"

# --------------------------------------------------------------------------
head_ ".gitattributes coverage"
# The patterns are path-anchored: a rule naming windows/git-bash/.bashrc does
# NOT match the nested copy under default-git-bash/. That gap existed for the
# exact files whose CRLF corruption the rule was written to prevent.
uncovered=0
while IFS= read -r -d '' path; do
  case "$path" in
    *.sh|*.zsh|*.py|*.lua|*.ps1|*.psd1|*.psm1|\
    windows/git-bash/.bashrc|windows/git-bash/.bash_profile|windows/git-bash/.aliases|\
    windows/git-bash/default-git-bash/.bashrc|\
    windows/git-bash/default-git-bash/.bash_profile|\
    windows/git-bash/default-git-bash/.aliases) ;;
    *) continue ;;
  esac
  attr="$(git check-attr eol -- "$path")"
  if [[ "$attr" != *": eol: lf" ]]; then
    err "$path is not pinned to LF in .gitattributes ($attr)"
    uncovered=$((uncovered + 1))
  fi
done < <(git ls-files -z)
(( uncovered == 0 )) && ok "every script and dotfile is pinned to LF"

# --------------------------------------------------------------------------
head_ "Bash 3.2 compatibility"
# macOS ships bash 3.2 as /bin/bash and that is what these packages run under.
bash4_hits=0
for d in $BASH32_DIRS; do
  [[ -d "$d" ]] || continue
  while IFS= read -r -d '' f; do
    case "$f" in */tests/*) continue ;; esac
    # Strip whole-line comments first. git_recent_branches.sh explains in a
    # comment that it avoids mapfile, and matching that would be absurd.
    hits="$(sed 's/^[[:space:]]*#.*$//' "$f" | grep -nE \
      '(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)|(declare|local)[[:space:]]+-[A-Za-z]*A([[:space:]]|$)|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)')"
    if [[ -n "$hits" ]]; then
      err "$f uses a Bash 4+ construct (see CONTRIBUTING.md)"
      printf '%s\n' "$hits" | head -3 >&2
      bash4_hits=$((bash4_hits + 1))
    fi
  done < <(git ls-files -z -- "$d/*.sh")
done
(( bash4_hits == 0 )) && ok "no Bash 4+ constructs in: $BASH32_DIRS"

# --------------------------------------------------------------------------
head_ "duplicated blocks keep their contract"
# CONTRIBUTING.md says duplication is deliberate, because a script has to work
# when copied alone into ~/bin. The cost of that choice is drift, so the copies
# are checked here instead of being factored into a library.
#
# The assertion is the contract, not byte-identity. The copies genuinely differ
# and defensibly so: set_git_profile.sh reports through its own err() helper
# rather than an inline printf, because it has one. What must not vary is the
# guard and the exit code — a copy that accepts an empty value, or exits
# something other than 3, is a real divergence.
extract_fn() {
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
    inside { print }
    inside && /^\}/ { exit }
  ' "$1"
}

copies=0
drifted=0
while IFS= read -r -d '' f; do
  grep -q '^require_value() {' "$f" || continue
  copies=$((copies + 1))
  body="$(extract_fn "$f" require_value)"
  if ! printf '%s' "$body" | grep -qF 'if [[ -z "$value" || "$value" == --* ]]; then'; then
    err "require_value() in $f has a different guard condition"
    drifted=$((drifted + 1))
    continue
  fi
  if ! printf '%s' "$body" | grep -qE '^[[:space:]]*exit 3$'; then
    err "require_value() in $f does not exit 3"
    drifted=$((drifted + 1))
    continue
  fi
  if ! printf '%s' "$body" | grep -qE 'printf .* >&2|err "'; then
    err "require_value() in $f does not report the failure to stderr"
    drifted=$((drifted + 1))
  fi
done < <(git ls-files -z -- '*.sh')
if (( copies < 2 )); then
  err "expected require_value() in several scripts, found $copies"
elif (( drifted == 0 )); then
  ok "require_value() contract holds across $copies copies"
fi

# --------------------------------------------------------------------------
head_ "error output goes to stderr"
# info/ok/warn print to stdout; only err goes to stderr. A script that gets this
# wrong is invisible to `cmd 2>/dev/null` callers.
bad_err=0
while IFS= read -r -d '' f; do
  grep -q '^err() *{' "$f" || continue
  if ! grep -E '^err\(\) *\{.*>&2' "$f" >/dev/null 2>&1; then
    err "$f defines err() without redirecting to stderr"
    bad_err=$((bad_err + 1))
  fi
done < <(git ls-files -z -- '*.sh')
(( bad_err == 0 )) && ok "every err() writes to stderr"

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%d convention check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all static convention checks passed (%d scripts) ===\n' "${#clis[@]}"
exit 0

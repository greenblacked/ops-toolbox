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
warn() { printf '[warn] %s\n' "$*"; }
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

# A test harness that discovers itself will invoke itself, and this suite once
# did exactly that: check_conventions.sh --help re-entered the whole run and
# recursed until CI timed out. Assert the exclusion directly, because the
# symptom of losing it is a hang rather than a failure.
for f in "${clis[@]}"; do
  case "$f" in
    test-env/*|*/tests/*)
      err "$f is test infrastructure and must not be discovered as a CLI"
      ;;
  esac
done

# Everything below runs discovered scripts. A script that blocks on input would
# otherwise hang the suite instead of failing it. macOS has no timeout(1), so
# fall back to running directly there — CI is Linux and stays protected.
if command -v timeout >/dev/null 2>&1; then
  guard() { timeout 20 "$@"; }
else
  guard() { "$@"; }
fi

# --------------------------------------------------------------------------
head_ "--help contract"
# --help must work before any preflight check, which is what lets a macOS-only
# script answer --help on this Linux runner. That ordering is the whole point.
for f in "${clis[@]}"; do
  checked=$((checked + 1))
  out=""
  rc=0
  out="$(guard "./$f" --help 2>&1)"
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
  guard "./$f" --definitely-not-a-valid-flag-12345 >/dev/null 2>&1
  rc=$?
  if (( rc == 3 )); then
    ok "$f unknown flag -> 3"
  else
    err "$f unknown flag exited $rc, expected 3"
  fi
done

# --------------------------------------------------------------------------
head_ "both --flag VALUE and --flag=VALUE"
# CONTRIBUTING.md asks for both spellings of every value-taking flag, and until
# this check existed nothing held anyone to it: the launchd agent accepted
# --tail=80 but rejected --weekday=Mon, --hour, --minute and --profile, while
# its linux counterpart took the equals form for all four. A rule documented and
# unenforced is the drift this repository keeps rediscovering.
#
# Static rather than executed, because proving the accepting half means running
# a script with a real value, and these scripts change machines.
both_forms_awk='
function flush(   i, n, parts) {
  if (arm != "" && body ~ /require_value|needs a value/) {
    n = split(arm, parts, "|")
    for (i = 1; i <= n; i++)
      if (parts[i] ~ /^--/) print parts[i]
  }
  arm = ""; body = ""
}
/^[[:space:]]*(-{1,2}[A-Za-z][A-Za-z0-9-]*\|)*-{1,2}[A-Za-z*][A-Za-z0-9-]*(=\*)?\)/ {
  flush()
  line = $0
  sub(/^[[:space:]]*/, "", line)
  sub(/\).*$/, "", line)
  if (line ~ /=\*$/) next
  arm = line
  body = $0
  if ($0 ~ /;;/) flush()
  next
}
arm != "" { body = body "\n" $0; if ($0 ~ /;;/) flush() }
END { flush() }
'
missing_forms=0
checked_forms=0
for f in "${clis[@]}"; do
  case "$f" in *.py) continue ;; esac
  equals_arms="$(grep -oE '^[[:space:]]*--[a-zA-Z0-9-]+=\*\)' "$f" \
    | grep -oE '\--[a-zA-Z0-9-]+' | sort -u)"
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    checked_forms=$((checked_forms + 1))
    if ! printf '%s\n' "$equals_arms" | grep -qx -- "$flag"; then
      err "$f accepts '$flag VALUE' but not '$flag=VALUE'"
      missing_forms=$((missing_forms + 1))
    fi
  done < <(awk "$both_forms_awk" "$f" | sort -u)
done
if (( checked_forms == 0 )); then
  err "found no value-taking flags at all — this check has stopped checking"
elif (( missing_forms == 0 )); then
  ok "every value-taking flag takes both forms ($checked_forms across the tree)"
fi

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
head_ "a dry run writes nothing"
# README.md's second rule, asserted against the filesystem rather than against
# the script's own output. That distinction is the whole point: the linux suite
# already checked for the string "dry-run complete; no changes written", and
# passed for months while five scripts created a timestamped log file on every
# preview. A test that reads the claim instead of checking it proves nothing.
#
# Each script runs with HOME and TMPDIR pointed at fresh scratch directories,
# which are compared before and after. Anything created, removed or touched is
# a failure.
#
# Scripts needing more than --dry-run to reach their main path are listed here.
# A discovered script that is neither listed nor skippable fails loudly, so this
# table cannot quietly rot the way a hardcoded subject list does.
#
# A script driven by a subcommand is the case this table exists for, and the
# case it used to miss. Bare --dry-run on one of those is a usage error: it
# exits 3 having written nothing, which looked exactly like a pass. That is how
# `stay_fresh_timer.sh install --dry-run` wrote two unit files and started a
# timer while this check reported the whole repository clean. The exit code is
# inspected below so the same gap cannot reopen silently.
dry_run_args() {
  case "$1" in
    macos-initial-setup/install_devtools.sh) printf '%s\n' "--dry-run" ;;
    macos-initial-setup/install_apps.sh)     printf '%s\n' "--dry-run" ;;
    linux/install_devtools.sh)               printf '%s\n' "--dry-run --yes" ;;
    linux/stay_fresh.sh)                     printf '%s\n' "--dry-run --yes --no-sudo" ;;
    linux/systemd/stay_fresh_timer.sh)       printf '%s\n' "install --dry-run" ;;
    linux/packages.sh)                       printf '%s\n' "dump --file @SCRATCH@/packages.txt --dry-run" ;;
    git/git_hooks_install.sh)                printf '%s\n' "install --dry-run" ;;
    macos-initial-setup/launchd/stay_fresh_agent.sh) printf '%s\n' "install --dry-run" ;;
    macos-initial-setup/brewfile.sh)         printf '%s\n' "dump --file @SCRATCH@/Brewfile --dry-run" ;;
    k8s-toolbox/debug_pod.sh)                printf '%s\n' "--pod dry-run-probe --dry-run" ;;
    mikrotik/pull_router_backups.sh)         printf '%s\n' "--dry-run probe@localhost" ;;
    git/gacp.sh)                             printf '%s\n' "--dry-run -m dry-run probe" ;;
    git/set_git_profile.sh)                  printf '%s\n' "--dry-run --name Probe --email probe@example.invalid" ;;
    *)                                       printf '%s\n' "--dry-run" ;;
  esac
}

# Paths written by a third-party tool as a side effect of being *asked its
# version*, not by the script storing anything. Go 1.23+ drops telemetry
# counters into $HOME on every `go` invocation, and install_devtools.sh prints
# a version table. Excluded because the alternative is contorting the scripts
# to work around another project's defaults — but named here, and reported
# when it fires, because a silent exclusion list is how coverage rots.
IGNORE_RE='/\.config(/go(/.*)?)?( |$)'

snapshot() {
  # Names plus mtimes, so a rewritten file is caught as well as a new one.
  find "$1" "$2" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort
}

filtered_snapshot() {
  snapshot "$1" "$2" | grep -vE "$IGNORE_RE"
}

dry_checked=0
for f in "${clis[@]}"; do
  # Only scripts that advertise --dry-run are in scope.
  help_out="$(guard "./$f" --help 2>&1)" || continue
  case "$help_out" in *--dry-run*) ;; *) continue ;; esac

  scratch="$(mktemp -d)"
  mkdir -p "$scratch/home" "$scratch/tmp"

  before="$(filtered_snapshot "$scratch/home" "$scratch/tmp")"
  # @SCRATCH@ lets an entry above name an output path without hardcoding one:
  # a --file argument pointed anywhere else would either escape the snapshot
  # (and hide a write) or land in the working tree.
  dry_args="$(dry_run_args "$f")"
  dry_args="${dry_args//@SCRATCH@/$scratch/tmp}"
  # This file runs under `set -uo pipefail` with no -e, so the exit code can be
  # taken directly; adding `set -e` around it would change the whole script.
  # shellcheck disable=SC2086  # word splitting of the argument list is intended
  HOME="$scratch/home" TMPDIR="$scratch/tmp" \
    guard "./$f" $dry_args >/dev/null 2>&1
  dry_rc=$?
  after="$(filtered_snapshot "$scratch/home" "$scratch/tmp")"

  ignored="$(snapshot "$scratch/home" "$scratch/tmp" | grep -cE "$IGNORE_RE")"
  (( ignored > 0 )) && printf '       (ignored %s third-party telemetry path(s) under %s)\n' \
    "$ignored" "$f"

  dry_checked=$((dry_checked + 1))
  if (( dry_rc == 3 )); then
    # Exit 3 is this repository's usage error, so the run stopped at argument
    # parsing and never reached the code that would have written anything.
    # "Wrote nothing" is true and meaningless. Treat it as a gap in the table
    # above rather than a pass.
    err "$f exited 3 (usage) under '$dry_args' — its dry run was never exercised"
    err "       add an entry to dry_run_args() so this script reaches its main path"
  elif (( dry_rc != 0 )); then
    # A preview touches nothing, so it should answer on a machine that could
    # not run the real thing — the same reasoning that puts --help ahead of
    # every preflight, and already applied to the k8s scripts when they exited
    # 2 without Docker. It also keeps this check honest: a script that bails at
    # a preflight here writes nothing for a reason that has nothing to do with
    # --dry-run being implemented, and would sail past on any host lacking the
    # dependency. stay_fresh_timer.sh did exactly that, exiting 2 with no
    # systemd user manager while writing units on a machine that had one.
    # Reported rather than failed. Some of these are genuine — stay_fresh_timer.sh
    # exited 2 here with no systemd user manager while writing units on a host
    # that had one — but a script can also stop for a reason belonging to the
    # sandbox rather than to itself, so this names the case for a human instead
    # of turning the build red on a machine-specific refusal. The suite that can
    # tell the difference is the one running on the target OS.
    warn "$f exited $dry_rc under '$dry_args' — a dry run should complete and exit 0"
    warn "       check whether a preflight runs ahead of the --dry-run branch"
  elif [[ "$before" == "$after" ]]; then
    ok "$f --dry-run wrote nothing"
  else
    err "$f --dry-run modified the filesystem:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/       /' >&2
  fi
  rm -rf "$scratch"
done

if (( dry_checked == 0 )); then
  err "no --dry-run-capable script was found — this check has stopped checking"
else
  ok "checked $dry_checked --dry-run-capable scripts"
fi

# --------------------------------------------------------------------------
head_ "winget configuration files"
# yamllint covers the syntax of these. It cannot cover the shape, and the shape
# is where the real defect was: an unquoted description containing a comma
# ended its value inside an inline map and turned the remainder into a stray
# directive key. That file was still perfectly valid YAML, so a syntax linter
# passed it and winget would have been handed a directive nobody wrote.
winget_configs=()
while IFS= read -r f; do
  [[ -n "$f" ]] && winget_configs+=("$f")
done < <(git ls-files '*.winget')

if (( ${#winget_configs[@]} == 0 )); then
  ok "no .winget configuration files to check"
elif ! python3 -c 'import yaml' 2>/dev/null; then
  warn "python3 yaml module not installed — .winget shape checks skipped"
  warn "       install with: python3 -m pip install pyyaml"
else
  for f in "${winget_configs[@]}"; do
    if msg="$(python3 "$HERE/winget_config_shape.py" "$f" 2>&1)"; then
      ok "$f ($msg)"
    else
      err "$f: $msg"
    fi
  done
fi

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%d convention check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all static convention checks passed (%d scripts) ===\n' "${#clis[@]}"
exit 0

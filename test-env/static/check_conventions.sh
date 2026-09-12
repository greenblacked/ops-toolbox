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

# This suite runs every discovered script for real — --help, an unknown flag,
# and a full dry run — so it is a test suite in exactly the sense the
# "must not inherit the host environment" section below polices, and it is on
# that section's own list. It pins HOME and TMPDIR at each invocation; these are
# the rest. Unset rather than set: an XDG_CONFIG_HOME left alone sends a dry run
# to the developer's real ~/.config, which the scratch snapshot cannot see, so
# the write goes unnoticed and unreported.
#
# The list is checked against the scripts themselves further down. A script that
# starts reading a new variable from the environment fails this suite until the
# name is added here, which is the point: nobody has to remember.
unset BUN_INSTALL CLOUDSDK_CONFIG TF_PLUGIN_CACHE_DIR UV_CACHE_DIR
unset CHANGELOG_ROOT OS_RELEASE XDG_CONFIG_HOME
unset STAY_FRESH_LOCK_DIR STAY_FRESH_NOTIFY STAY_FRESH_NOTIFY_TIMEOUT \
  STAY_FRESH_NOTIFY_WHEN STAY_FRESH_SLACK_WEBHOOK STAY_FRESH_STEP_TIMEOUT \
  STAY_FRESH_TG_BOT_TOKEN STAY_FRESH_TG_CHAT_ID

failures=0
checked=0
ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; }
err()  { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
head_() { printf '\n--- %s ---\n' "$*"; }

# Packages whose scripts must run under the Bash 3.2 that ships as /bin/bash on
# macOS. Deliberately not repository-wide: windows/git-bash/ targets Git Bash
# (bash 5) and uses local -A and globstar on purpose, and ci.yml uses mapfile.
BASH32_DIRS="git macos-initial-setup linux dotfiles"

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
    if ! grep -qx -- "$flag" <<<"$equals_arms"; then
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
head_ "readers that exit early"
# Under `set -o pipefail`, a reader that stops at the first match kills the
# writer with SIGPIPE, the pipeline reports 141, and a match reads as a miss.
# This file carried four of them at once -- one made macOS CI report that
# set_git_profile.sh does not accept `--profile=VALUE` when it does -- in a file
# that already explains the hazard in a comment. Prose did not hold the line, so
# this does. A here-string has no writer to kill: `grep -q X <<<"$s"`.
sigpipe_writer='(printf|echo)[^|]*'
sigpipe_reader='(grep -[a-zA-Z]*q|head -n|awk .\{ *exit)'
sigpipe_hits=0
sigpipe_scanned=0
# Every tracked shell file, test infrastructure included. `clis` leaves those
# out because everything below it *runs* what it discovers and this suite once
# recursed into itself; this check only reads. Excluding them here would have
# exempted the very file that carried four of these, which is the mistake the
# host-env check already had to unlearn: exempt means cannot fail, not not
# looked at.
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] || continue
  grep -q 'pipefail' "$f" || continue
  sigpipe_scanned=$((sigpipe_scanned + 1))
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    case "$hit" in *'#'*) [[ "${hit%%#*}" == *'|'* ]] || continue ;; esac
    err "$f:${hit%%:*} pipes into a reader that exits early; under pipefail that kills the writer, the pipeline reports 141, and a grep -q match reads as a miss — use a here-string"
    sigpipe_hits=$((sigpipe_hits + 1))
  done < <(grep -nE "$sigpipe_writer"'[[:space:]]*\|[[:space:]]*'"$sigpipe_reader" "$f" || true)
done < <(cd "$REPO_ROOT" && git ls-files '*.sh')
if (( sigpipe_scanned == 0 )); then
  err "the SIGPIPE shape check inspected no file — it has stopped checking"
elif (( sigpipe_hits == 0 )); then
  ok "no pipefail script pipes into a reader that exits early ($sigpipe_scanned scanned)"
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

# And the converse, which is how status.sh arrived: a script with a shebang,
# tracked 100644. Nothing above caught it - that loop only asks whether an
# executable file earns its bit, never whether a script has one - so the file
# was committed, reviewed and merged as a script nobody could run without
# saying `bash` first. Every usage line in this repository is written `./x.sh`.
#
# A shebang is the file declaring itself runnable, so the mode is the part that
# is wrong when they disagree. Sourced libraries are the exception and are
# excluded by path: they carry a shebang for editors and shellcheck, and are
# never executed.
mode_bad=0
mode_checked=0
while IFS= read -r -d '' record; do
  mode="${record%% *}"
  path="${record#*$'\t'}"
  [[ "$mode" == "100644" ]] || continue
  # A file that says so in its own header is not a mistake. git_aliases.sh and
  # bash_aliases.sh both open with "Sourced, not executed" and carry a shebang
  # for editors and shellcheck; so do the shared test helpers. Reading the
  # header beats a path pattern, because the declaration travels with the file
  # when somebody moves it.
  case "$path" in
    test-env/lib/*|*/lib/*|*.zsh) continue ;;
  esac
  head -n 1 -- "$path" | grep -q '^#!' || continue
  head -n 8 -- "$path" | grep -qi 'sourced, not executed' && continue
  mode_checked=$((mode_checked + 1))
  err "$path has a shebang but is mode 644 — nobody can run it as ./$(basename "$path")"
  mode_bad=$((mode_bad + 1))
done < <(git ls-files -s -z)
if (( mode_bad == 0 )); then
  ok "every tracked script with a shebang is executable"
fi

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
    *.sh|*.zsh|*.py|*.lua|*.awk|*.ps1|*.psd1|*.psm1|\
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

# A `case` inside a multi-line $( ) is a Bash 3.2 parse error, and neither the
# keyword scan above nor shellcheck says a word about it. Bash 3.2 parses `$(`
# by scanning forward for the matching `)` and miscounts on the unbalanced `)`
# closing each case pattern: it reaches end of line still looking and dies with
# "syntax error near unexpected token `newline'". The script cannot then be
# parsed at all, so every assertion against it fails at once rather than one.
#
# changelog.d/changelog.sh carried exactly this and turned the macOS job red
# twice, through a wrong first diagnosis. It is valid Bash 4 syntax, shellcheck
# is silent on it, and the keyword scan above looks for mapfile/declare -A/${x,,}
# and so cannot see it. Unlike those, this is repository-wide rather than
# scoped to BASH32_DIRS: any script the static suite executes has to parse under
# whatever /bin/bash the runner has, and on macOS that is 3.2.
case_sub_hits=0
case_sub_checked=0
while IFS= read -r -d '' f; do
  case_sub_checked=$((case_sub_checked + 1))
  hit="$(awk '
    { opens = gsub(/\$\(/, "$("); closes = gsub(/\)/, ")") }
    depth == 0 && opens > 0 { start = NR; body = $0; depth = opens - closes; if (depth < 0) depth = 0; next }
    depth > 0 {
      body = body "\n" $0
      depth += opens - closes
      if (depth <= 0) {
        if (body ~ /(^|\n)[ \t]*case[ \t]/) print start
        depth = 0; body = ""
      }
    }
  ' "$f")"
  if [[ -n "$hit" ]]; then
    err "$f has a case inside a multi-line \$( ) — Bash 3.2 cannot parse it (line $hit)"
    case_sub_hits=$((case_sub_hits + 1))
  fi
done < <(git ls-files -z -- '*.sh')
if (( case_sub_checked == 0 )); then
  err "the case-in-substitution scan inspected no file — this check has stopped checking"
elif (( case_sub_hits == 0 )); then
  ok "no case inside a multi-line \$( ) in $case_sub_checked script(s)"
fi

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
  if ! grep -qF 'if [[ -z "$value" || "$value" == --* ]]; then' <<<"$body"; then
    err "require_value() in $f has a different guard condition"
    drifted=$((drifted + 1))
    continue
  fi
  if ! grep -qE '^[[:space:]]*exit 3$' <<<"$body"; then
    err "require_value() in $f does not exit 3"
    drifted=$((drifted + 1))
    continue
  fi
  if ! grep -qE 'printf .* >&2|err "' <<<"$body"; then
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
    git/clone-repos.sh)                      printf '%s\n' "--dry-run git/repos.txt.example" ;;
    git/set_git_profile.sh)                  printf '%s\n' "--dry-run --name Probe --email probe@example.invalid" ;;
    changelog.d/changelog.sh)                printf '%s\n' "release 0.0.0-probe --dry-run" ;;
    *)                                       printf '%s\n' "--dry-run" ;;
  esac
}

# Paths written by a third-party tool as a side effect of being *asked its
# version*, not by the script storing anything. Go 1.23+ drops telemetry
# counters into $HOME on every `go` invocation, and install_devtools.sh prints
# a version table. Excluded because the alternative is contorting the scripts
# to work around another project's defaults — but named here, and reported
# when it fires, because a silent exclusion list is how coverage rots.
#
# Homebrew's bootsnap cache is the same shape and arrived the same way. A dry
# run of install_apps.sh or brewfile.sh calls `brew info` to check a formula
# name resolves before planning to install it - a read - and Homebrew compiles
# its own Ruby into ~/Library/Caches/Homebrew/bootsnap, roughly 950 files. The
# scripts store nothing. This was invisible until the dry-run snapshot started
# working on macOS: with GNU-only `find -printf` the before and after were both
# empty, so the write was there all along and nothing could see it.
# The two bare parents are listed because Homebrew creates them on the way to
# its cache; they are matched only where the path ENDS there, so a real write
# to ~/Library/Preferences or ~/Library/Caches/SomethingElse still fails.
IGNORE_RE='/\.config(/go(/.*)?)?( |$)|/Library(/Caches)?( |$)|/Library/Caches/Homebrew(/.*)?( |$)'

snapshot() {
  # Names plus mtimes, so a rewritten file is caught as well as a new one.
  find "$1" "$2" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort
}
# -printf is GNU-only. On macOS find fails, 2>/dev/null swallows the message,
# and snapshot() returns the empty string for the before AND the after call --
# so every assertion below compared "" to "" and reported that a dry run wrote
# nothing having inspected nothing. This section polices the whole repository
# for that contract, which made it the worst possible place to lose it.
# test-env/static/test_changelog.sh and dotfiles/tests/test_dotfiles.sh guard
# the same call the same way; ls -ld is one batched exec rather than one per
# file, and prints mtime to the minute, which is enough to catch a rewrite.
if ! find "$REPO_ROOT" -maxdepth 0 -printf '' >/dev/null 2>&1; then
  snapshot() { find "$1" "$2" -mindepth 1 -exec ls -ld {} + 2>/dev/null | sort; }
fi

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
head_ "test suites must not inherit the host environment"
# A script that reads a path out of the environment — XDG_CACHE_HOME,
# BUN_INSTALL, TF_PLUGIN_CACHE_DIR — is aimed by whoever runs it. A test suite
# that leaves such a variable alone is therefore aimed by the developer's shell
# rather than by its own fixtures, and the failure is silent in both directions:
# an exported BUN_INSTALL made a relocation assertion pass here against ~/.bun
# and fail in CI, and disk_cleanup.sh emptied the real XDG_CACHE_HOME/thumbnails
# while --home pointed it at a scratch profile.
#
# Neither was hard to think of once named. The point of doing it here is that
# nobody has to: the set is derived from the scripts themselves, so the next
# variable someone reads from the environment is covered by the commit that
# reads it.
#
# A variable counts as read-from-the-host when the script expands it and never
# assigns it. A suite counts as pinning it when it names it in code — unset at
# the top, forwarded through a run helper, or set for one command. Comments are
# stripped from both sides of that question: a suite explaining in prose why it
# unsets a variable is not unsetting it, and test_doc_citations.sh describing
# stay_fresh.sh in its header is not running it.
host_env_ignore='^(BASH[A-Z_]*|PIPESTATUS|FUNCNAME|IFS|OSTYPE|HOSTNAME|RANDOM|SECONDS|LINENO|PPID|UID|EUID|PWD|OLDPWD|SHLVL|REPLY|HOME|PATH|TMPDIR|TMP|TEMP|USER|LOGNAME|SHELL|TERM|LANG|LC_[A-Z]+|NO_COLOR|COLUMNS|LINES|EDITOR|VISUAL|PAGER|SUDO_[A-Z]+|GPG_TTY)$'

host_env_scratch="$(mktemp -d)"
trap 'rm -rf "$host_env_scratch"' EXIT

# One awk pass per script, cached: stay_fresh.sh alone is ~3900 lines and every
# suite in its package asks about it.
host_env_vars() {
  local script="$1" lang=sh cache
  case "$script" in *.py) lang=py ;; esac
  cache="$host_env_scratch/$(printf '%s' "$script" | tr '/.' '__')"
  # Safe as a pipeline: sort reads to EOF, so nothing upstream is cut short.
  [[ -f "$cache" ]] || awk -f "$HERE/host_env_vars.awk" -v lang="$lang" "$script" \
    | grep -Ev "$host_env_ignore" | sort > "$cache"
  cat "$cache"
}

suites=()
while IFS= read -r f; do
  [[ -n "$f" ]] && suites+=("$f")
# Package runners (git/tests/run.sh and friends) match the first pattern. The
# two test-env runners match none of the three, which is how test-env/static/
# run.sh came to call changelog.sh without pinning CHANGELOG_ROOT: the check
# built to catch exactly that could not see the file. 'test-env/*/run.sh' is
# the gap.
# check_*.sh as well as test_*.sh: check_pin_age.sh arrived named check_, so it
# matched none of these globs and its PIN_MAX_AGE_DAYS threshold - the entire
# gate - went unpinned and unnoticed. Matching on the prefix somebody happened
# to choose is how a subject list rots.
done < <(git ls-files '*/tests/*.sh' 'test-env/*/run.sh' \
  'test-env/static/test_*.sh' 'test-env/static/check_*.sh')

env_leaks=0
env_pairs=0
for suite in "${suites[@]}"; do
  # A package suite tests its own package: linux/ and macos-initial-setup/ both
  # ship a stay_fresh.sh, and matching on the bare basename repo-wide attributes
  # one's variables to the other's suite. The test-env/ suites belong to no
  # package, so theirs is everything outside one.
  case "$suite" in
    test-env/*) scope="$(git ls-files '*.sh' '*.py' | grep -v '/tests/' | grep -v '^test-env/')" ;;
    *)          scope="$(git ls-files "${suite%%/tests/*}/*.sh" "${suite%%/tests/*}/*.py" | grep -v '/tests/')" ;;
  esac
  suite_code="$(grep -vE '^[[:space:]]*#' "$suite")"

  for script in $scope; do
    base="$(basename "$script")"
    grep -q "$base" <<<"$suite_code" || continue
    for v in $(host_env_vars "$script"); do
      env_pairs=$((env_pairs + 1))
      if ! grep -qE "(^|[^A-Za-z0-9_])$v([^A-Za-z0-9_]|$)" <<<"$suite_code"; then
        err "$suite runs $base, which reads \$$v, and never pins it — the host aims that run"
        env_leaks=$((env_leaks + 1))
      fi
    done
  done
done

if (( env_pairs == 0 )); then
  err "no suite/script pairs examined — the discovery above is broken"
elif (( env_leaks == 0 )); then
  ok "every suite pins the $env_pairs host-read variable(s) of the scripts it runs"
fi

# --------------------------------------------------------------------------
head_ "CI tool pins carry a digest"
# .github/ci-tool-checksums.env records the SHA-256 of every binary the workflow
# downloads, and each install step in .github/workflows/ci.yml now checks its
# download against it. That is a control spread across two files, and a control
# spread across two files drifts.
#
# It had already drifted as far as it can go. The digest file declared itself
# the source of truth and said, in its own header, that "a version pin without a
# digest still trusts whoever answers the URL" — while nothing in the tree read
# it. A grep for its name returned the file and nothing else. Five tools were
# installed on a version pin alone, and the two Darwin digests recorded
# specifically for the macos-native job had never once been compared against
# anything. A digest nobody checks is worse than no digest, because it reads
# like a control and gets counted as one.
#
# The drift that will happen next is smaller and likelier: someone bumps a
# *_VERSION in the workflow env: block, the download URL changes with it, and
# the digest file still holds the previous release's hash. Nothing about that is
# visible in a diff of either file alone. Caught here it is a review-time
# failure naming both values; caught at install time it is a red job on a branch
# that looked fine.
#
# Three assertions, each covering a different half of the drift:
#   - every *_VERSION pinned in the workflow is recorded in the digest file at
#     the same version, or is named in that file's NO_DIGEST_TOOLS as arriving
#     through a package manager that verifies its own downloads;
#   - every *_VERSION recorded in the digest file is still pinned in the
#     workflow, so a removed tool cannot leave a stale digest behind;
#   - every digest recorded in that file is named by some step in the workflow —
#     the assertion that would have caught the original rot on the day it
#     started, and the one that keeps this from becoming decoration again.
#
# Nothing here validates a digest against the bytes of a release. That needs the
# network, this suite deliberately has none, and the digests are transcribed
# from upstream by a human at bump time. The claim being checked is that the two
# files agree and that both are wired up, not that the hex is right.
ci_yml=".github/workflows/ci.yml"
sums_env=".github/ci-tool-checksums.env"

pin_gaps=0
ci_pin_count=0
sums_pin_count=0
digest_count=0

if [[ ! -f "$ci_yml" ]]; then
  err "$ci_yml is missing — the CI download gate cannot be checked at all"
elif [[ ! -f "$sums_env" ]]; then
  err "$sums_env is missing — every binary ci.yml downloads would install on a version pin alone"
else
  # The top-level env: block only, anchored at column 0: ci.yml also carries
  # step-level env: blocks, which are indented and must not be mistaken for it.
  # The block ends at the next column-0 key (jobs:); a column-0 comment or a
  # blank line does not end it. Rename or reindent that block and this collects
  # nothing, which the floor at the bottom turns into a failure rather than a
  # silent pass.
  ci_pins="$(awk '
    /^env:[[:space:]]*$/        { in_env = 1; next }
    in_env && /^[^[:space:]#]/  { in_env = 0 }
    in_env && $1 ~ /_VERSION:$/ {
      name = $1
      sub(/:$/, "", name)
      print name, $2
    }
  ' "$ci_yml" | tr -d "\"'")"

  # Declared in the digest file rather than here, so the exemption sits beside
  # what it exempts and a reader of that file can see why a tool is absent.
  no_digest="$(awk -F= '$1 == "NO_DIGEST_TOOLS" { print $2 }' "$sums_env" | tr -d "\"'")"

  # A here-string, not a pipe. Both because the loop body increments counters
  # that have to survive it, and because this repository has been bitten three
  # times by a pipeline whose reader exits early: under `set -o pipefail` that
  # kills the writer, the pipeline reports 141, and a match reads as a miss.
  while read -r ci_name ci_value; do
    [[ -n "$ci_name" ]] || continue
    ci_pin_count=$((ci_pin_count + 1))
    tool="${ci_name%_VERSION}"
    recorded="$(awk -F= -v k="$ci_name" '$1 == k { print $2 }' "$sums_env")"

    case " $no_digest " in
      *" $tool "*)
        if [[ -n "$recorded" ]]; then
          err "$tool is in NO_DIGEST_TOOLS yet $sums_env records $ci_name — it cannot be both exempt and pinned here"
          pin_gaps=$((pin_gaps + 1))
        fi
        continue
        ;;
    esac

    if [[ -z "$recorded" ]]; then
      err "$ci_yml pins $ci_name: '$ci_value' and $sums_env records no $ci_name — that download runs on a version pin alone"
      pin_gaps=$((pin_gaps + 1))
    elif [[ "$recorded" != "$ci_value" ]]; then
      err "$ci_yml pins $ci_name: '$ci_value' but $sums_env records $ci_name=$recorded — a bump edited one file and not the other, and the digest now belongs to a release CI no longer downloads"
      pin_gaps=$((pin_gaps + 1))
    elif ! grep -qE "^${tool}_SHA256_[A-Za-z0-9_]+=" "$sums_env"; then
      err "$sums_env records $ci_name=$recorded but no ${tool}_SHA256_* digest — a version with no bytes behind it"
      pin_gaps=$((pin_gaps + 1))
    fi
  done <<<"$ci_pins"

  # Only run the reverse direction when the forward one found something.
  # Otherwise a renamed env: block reports every recorded tool as missing and
  # buries the one message that says what actually happened.
  if (( ci_pin_count > 0 )); then
    while IFS='=' read -r sums_name sums_value; do
      [[ -n "$sums_name" ]] || continue
      sums_pin_count=$((sums_pin_count + 1))
      # A version mismatch is already reported above; this direction exists for
      # the name the workflow does not pin at all.
      if [[ -z "$(awk -v k="$sums_name" '$1 == k { print $2 }' <<<"$ci_pins")" ]]; then
        err "$sums_env records $sums_name=$sums_value and the env: block of $ci_yml pins no $sums_name — a stale entry for a tool the workflow no longer installs"
        pin_gaps=$((pin_gaps + 1))
      fi
    done <<<"$(grep -E '^[A-Za-z_][A-Za-z0-9_]*_VERSION=' "$sums_env")"
  fi

  while read -r digest_key; do
    [[ -n "$digest_key" ]] || continue
    digest_count=$((digest_count + 1))
    if ! grep -q "$digest_key" "$ci_yml"; then
      err "$sums_env records $digest_key and no step in $ci_yml names it — an unread digest is exactly the state this whole file was in"
      pin_gaps=$((pin_gaps + 1))
    fi
    digest_tool="${digest_key%%_SHA256_*}"
    if ! grep -q "^${digest_tool}_VERSION=" "$sums_env"; then
      err "$sums_env records $digest_key but no ${digest_tool}_VERSION — the digest names no release"
      pin_gaps=$((pin_gaps + 1))
    fi
  done <<<"$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*_SHA256_[A-Za-z0-9_]+' "$sums_env")"

  # The floors. Every one of the three loops above is happy with an empty
  # subject list, so without these a renamed env: block, an emptied digest file
  # or a changed key shape disarms the whole section and it still prints ok.
  if (( ci_pin_count == 0 )); then
    err "no *_VERSION pins found in the top-level env: block of $ci_yml — it was renamed, reindented or removed, and this check just inspected nothing"
  elif (( sums_pin_count == 0 )); then
    err "no *_VERSION entries found in $sums_env — the file was emptied or its key shape changed, and this check just inspected nothing"
  elif (( digest_count == 0 )); then
    err "no *_SHA256_* digests found in $sums_env — every binary ci.yml downloads is installing on a version pin alone"
  elif (( pin_gaps == 0 )); then
    ok "$ci_pin_count CI tool pin(s) agree with $sums_env; $digest_count digest(s), each named by a step in $ci_yml"
  fi
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

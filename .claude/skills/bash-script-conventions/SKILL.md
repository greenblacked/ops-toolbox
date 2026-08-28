---
name: bash-script-conventions
description: How Bash scripts are actually written in this repository - the three set dialects and which package uses which, Bash 3.2 compatibility, the usage()/argument-loop shape, require_value, the four sanctioned dry-run mechanisms and two output grammars, colour and level helpers, and log-file handling. Use this whenever you create or edit any .sh file here, including small fixes to an existing script, and whenever you need to judge whether a shell change fits this codebase.
---

# Bash scripts in this repository

Copy the canonical block from `templates/new_script.sh` rather than inventing a
variant. The template is tracked and CI holds it to every contract, so if it
ever drifts from these rules the build fails there first.

## The skeleton

Line 1 is `#!/usr/bin/env bash` - exactly that, asserted by the static suite.
Line 2 is a `#` comment saying what the script is for. Then a blank line, then
the `set` line.

## Three set dialects, chosen by role

Do not mix them, and do not "upgrade" a package to `-e` because it looks safer.

| Dialect | Used by | Why |
| --- | --- | --- |
| `set -euo pipefail` | `git/*.sh`, `k8s-toolbox/*.sh` | Short, single-purpose. Any failure should stop everything. |
| `set -u` then `set -o pipefail` on separate lines, no `-e` | `macos-initial-setup/*.sh`, `linux/*.sh` | Long maintenance runs where a missing tool must be *recorded* and skipped, not fatal. The reasoning is written out in the header comment of `macos-initial-setup/v1_stay_fresh.sh` ("-e is intentionally omitted"). |
| `set -uo pipefail` | `run-tests.sh`, `test-env/*/run.sh` | Aggregators that must keep going after a failing child and report a summary. |

## Bash 3.2 compatibility

`git/`, `macos-initial-setup/` and `linux/` must run under the Bash 3.2 that
ships as `/bin/bash` on macOS. No `mapfile`/`readarray`, no `declare -A` or
`local -A`, no `${x,,}`/`${x^^}`, no `coproc`, no `&>>`. Build lists with a
`while IFS= read -r` loop - `git/git_recent_branches.sh` has a worked example
under the comment "Build the list without mapfile so this script runs on Bash
3.2".

The rule is **directory-scoped, not repository-wide**. `windows/git-bash/`
targets Git Bash, which ships Bash 5, and legitimately uses `local -A` and
`shopt -s globstar`; `.github/workflows/ci.yml` uses `mapfile` on Ubuntu. Do
not "fix" either - the static suite scopes its check to those three directories
for this reason.

## Help and argument parsing

Define `usage()` **before** the argument loop, and handle `-h|--help`
**before any preflight check**. That ordering is what lets a macOS-only script
answer `--help` on a Linux CI runner, and it is asserted for every discovered
CLI.

- `-h|--help` - `usage; exit 0`. Always zero.
- Unknown flag - message to stderr, then `usage`, then `exit 3`.
- Support both `--flag VALUE` and `--flag=VALUE`.

The help body is a heredoc with these sections in this order - see `usage()`
in `git/gacp.sh`:

```text
<name> - one-line summary

Usage:
  ...

Options:
  ...

Exit codes: 0 success, 2 not a git repo, 3 usage, ...
```

`usage()` in `macos-initial-setup/brewfile.sh` uses an `awk` filter over the
script's own header instead of duplicating it. Either is fine; the comment
above it explains the trade-off.

## The duplicated value guard

Copy this verbatim. The canonical copy is `require_value()` in
`git/git_sync_default.sh`:

```bash
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}
```

A script that already has an `err()` helper may report through it instead of
the inline `printf`. What must not vary is the guard condition and `exit 3`.

## Dry runs

`--dry-run` is an **integer** flag: `DRY_RUN=0` in the variable block, set to
`1` by the flag, tested as `(( DRY_RUN == 1 ))` or `(( DRY_RUN ))`. Never a
string, never `[[ ]]`.

Four sanctioned mechanisms:

| Mechanism | Reference | Use when |
| --- | --- | --- |
| Bare `run()` wrapper | `run()` in `git/git_sync_default.sh` | Arguments have no spaces. |
| `run()` with `printf %q` quoting | `quote_arg()`, `print_cmd()` and `run()` in `git/gacp.sh` | Arguments may contain spaces (commit messages). |
| Labelled `run_cmd "label" cmd...` | `run_cmd()` in `macos-initial-setup/stay_fresh.sh` | The script also writes a log file. `run_cmd_tty()` is its sibling for anything needing a terminal (sudo, cask prompts). |
| Inline per-branch | the `if (( DRY_RUN == 1 ))` block in `git/git_amend_last.sh` | The "command" is not a single exec. |

### Two output grammars - pick by package, never mix

`git/` prints:

```text
dry-run: would run: git fetch origin main
dry-run complete; no changes written
```

`macos-initial-setup/` prints a dimmed, two-space-indented form with no
terminal summary line (`run_cmd()` and the per-step previews in
`stay_fresh.sh`):

```text
  (dry-run) brew upgrade [homebrew upgrade]
  (dry-run) would remove contents of /Users/x/Library/Caches/foo
```

Match the package you are in. A new top-level package picks one in its README
and sticks to it.

### The promise is about the filesystem

`test-env/static/check_conventions.sh` runs every `--dry-run`-capable CLI
against a scratch `HOME` and `TMPDIR` and fails on any change - creation,
removal or a changed mtime. A preview that prints "no changes written" while
creating a file is a failing build, and that is exactly the regression the
check was written after.

Two consequences worth internalising:

- A preview should complete and exit 0 even on a machine that could not do the
  real work. Reaching a preflight and exiting 2 makes the check meaningless on
  every host lacking that dependency, and `linux/systemd/stay_fresh_timer.sh`
  did precisely that while writing two unit files on a host that had systemd.
- A script driven by a subcommand needs an entry in `dry_run_args()` in that
  same file, or bare `--dry-run` exits 3 at argument parsing and "wrote
  nothing" is true and meaningless. The check now fails on exit 3 for this
  reason, so an unlisted subcommand-driven script fails loudly instead of
  quietly passing.

## Output

Colour constants live under a TTY guard with an empty-string `else` branch, and
every script honours `NO_COLOR`:

```bash
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
else
  C_RESET=''; C_RED=''; C_GREEN=''
fi
```

Level helpers use six-character padded labels so columns line up (the block
above `usage()` in `macos-initial-setup/brewfile.sh`):

```bash
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
```

`info`, `ok` and `warn` go to stdout; **only `err` goes to stderr**, and the
static suite fails any `err()` that forgets the redirect - a script that gets
this wrong is invisible to a `cmd 2>/dev/null` caller. Prefer `printf` over
`echo`. Which colours the block defines may vary; the level-helper grammar may
not.

## Log files

Only heavyweight install and maintenance scripts write logs; `git/*.sh` write
none. The pattern (`macos-initial-setup/stay_fresh.sh`):

```bash
LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/stay_fresh-$(date +%Y%m%d-%H%M%S).log"
```

Print the path inside `usage()` and again at the end, and have `--verbose`
switch from `>>"$LOG_FILE" 2>&1` to `2>&1 | tee -a "$LOG_FILE"` with
`rc="${PIPESTATUS[0]}"` so the real exit status survives the pipe.

**Guard the whole thing behind the dry-run flag.** The log is not an exception
to promise 2 - five scripts once created a timestamped file on every preview,
leaving orphans in `TMPDIR`:

```bash
if (( DRY_RUN == 1 )); then
  info "dry-run: would write log: $LOG_FILE"
else
  : > "$LOG_FILE"
  printf 'stay_fresh.sh log - %s\n' "$(date)" >> "$LOG_FILE"
  info "log file: $LOG_FILE"
fi
```

## Before you consider it done

- `shellcheck -x --severity=error` on the file, and `bash -n` for syntax.
- `./test-env/static/run.sh` - it discovers the script automatically, so it
  covers a new file the moment the file is tracked and executable.
- Mode `755` with a shebang; a sourced file (`*.zsh`, `*.aliases`) has no
  shebang and is mode `644`. Both are asserted.
- Idempotence: running it twice is safe and produces the same result. The pull
  request template asks about this directly.

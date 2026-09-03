# Contributing

These conventions are not aspirations — they were extracted from the scripts
already in this repository, with the file that establishes each one.
New code conforms to them; it does not invent new patterns.

If you find a rule here that the existing scripts do not actually follow, the
rule is wrong. Fix it or delete it.

The same conventions also exist as task-scoped skills under `.claude/skills/`
on a local checkout, for an automated agent that would rather load the rules
for the file it is editing than read this document end to end. That directory
is gitignored and is not on GitHub. They are derived from this file and from
the checks that enforce it; this document stays the published reference.

## Contents

- [The one architectural rule](#the-one-architectural-rule)
- [Bash scripts](#bash-scripts)
- [Help and argument parsing](#help-and-argument-parsing)
- [Dry runs](#dry-runs)
- [Output](#output)
- [Exit codes](#exit-codes)
- [Log files](#log-files)
- [PowerShell scripts](#powershell-scripts)
- [RouterOS scripts](#routeros-scripts)
- [Python helpers](#python-helpers)
- [Tests](#tests)
- [Adding a script](#adding-a-script)
- [File modes and line endings](#file-modes-and-line-endings)
- [Repository settings](#repository-settings)

## The one architectural rule

**A script must still work when copied on its own into `~/bin`.**

That is the distribution model this repository is built around. The README tells
you to `cp windows/git-bash/.bashrc "$HOME/"`; the Git helpers are meant to be
dropped into a `PATH` directory; the MikroTik scripts are pasted into a router's
*Source* field one at a time. A script that begins with
`source "$SCRIPT_DIR/../lib/common.sh"` breaks all three.

So: **duplication across scripts is deliberate, not technical debt.**
`require_value()` is copied across the Bash packages — git, linux,
macos-initial-setup, k8s-toolbox, windows and mikrotik — and
`Format-Size` across the PowerShell scripts that print sizes. Leave
them that way and copy the canonical block from
[`templates/`](templates/) when writing a new script. Do not count the
copies here: the number moves the moment a script is added, and a stale
count is how this paragraph already went wrong once.

What is asserted about the copies is their **contract**, not byte-identity:
the same guard condition, `exit 3`, and a message on stderr. They already
differ in defensible ways — `git/set_git_profile.sh` reports through its own
`err()` helper rather than an inline `printf`, because it has one — and a check
demanding identical bytes would only push people to make the copies worse.

Shared code is permitted in exactly one shape: **a substantial program with its
own tests, invoked as a subprocess by absolute path.**
[`macos-initial-setup/lib/workspace_scan.py`](macos-initial-setup/lib/workspace_scan.py)
is the only thing that clears that bar today — classification logic
called via `/usr/bin/python3`, unit-tested on its own. Note what it cost:
`macos-initial-setup/stay_fresh.sh` carries a symlink-resolving preamble
whose sole job is finding it. That price is worth paying once for a real program, never for
a seven-line validator.

Divergence between copies is a *test* problem, not a factoring problem. The
static suite asserts the **contract** of every `require_value()` copy (same
guard, exit 3, message on stderr), so you get the safety of a shared library
with none of the coupling.

## Bash scripts

Line 1 is `#!/usr/bin/env bash`. Line 2 is a `#` comment saying what the script
is for. Then a blank line, then the `set` line.

Three `set` dialects, chosen by role — do not mix them:

| Dialect | Used by | Why |
| --- | --- | --- |
| `set -euo pipefail` | `git/*.sh` | Short, single-purpose scripts. Any failure should stop everything. Two predate the rule and are left alone: `git/set_git_profile.sh` splits it across three lines, and `git/git_whoami.sh` omits `-e` because it reports on a repository rather than changing one. |
| `set -u` then `set -o pipefail` on separate lines, no `-e` | `macos-initial-setup/*.sh`, `linux/*.sh` | Long maintenance runs where a missing tool must be *recorded* and skipped, not fatal. `macos-initial-setup/stay_fresh.sh` and `linux/stay_fresh.sh` are the reference. The header comment of `macos-initial-setup/v1_stay_fresh.sh` explains why `-e` is omitted — that script itself predates the convention and sets only `-o pipefail`, so read it for the reasoning, not as the pattern. |
| `set -uo pipefail` | `run-tests.sh`, `test-env/*/run.sh` | Aggregators that must keep going after a failing child and report a summary. |

### Bash 3.2 compatibility

`git/`, `macos-initial-setup/` and `linux/` must run under the Bash 3.2 that
ships as `/bin/bash` on macOS. No `mapfile`/`readarray`, no `declare -A` or
`local -A`, no `${x,,}`/`${x^^}`, no `coproc`, no `&>>`. Build lists with a
`while IFS= read -r` loop instead — there is a worked example and an explanatory
comment above the `branches=()` loop in `git/git_recent_branches.sh`.

**This rule is directory-scoped, not repository-wide.** `windows/git-bash/`
targets Git Bash, which ships Bash 5 — `windows/git-bash/.bashrc` uses `local -A`
and `shopt -s globstar` legitimately. `.github/workflows/ci.yml` uses `mapfile`
and runs on Ubuntu. Do not "fix" either.

### Duplicated blocks

Copy these verbatim rather than inventing a variant. The canonical copy of
`require_value()` is in `git/git_sync_default.sh`:

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

## Help and argument parsing

Every command-line script defines a `usage()` function **before** the argument
loop, and handles `-h|--help` **before any preflight check**. That ordering is
not cosmetic: it is what lets `./install_apps.sh --help` work on Linux for a
macOS-only script, and it is asserted by the test suites.

- `-h|--help` → `usage; exit 0`. Always zero.
- Unknown flag → message to stderr, then `usage`, then `exit 3`.
- Support both `--flag VALUE` and `--flag=VALUE`.

The help body is a heredoc with these sections in this order — see
`usage()` in `git/gacp.sh` for the canonical example:

```text
<name> - one-line summary

Usage:
  ...

Options:
  ...

Exit codes: 0 success, 2 not a git repo, 3 usage, ...
```

`macos-initial-setup/brewfile.sh` uses a different implementation — an
`awk` filter that reflects the script's own header comment instead of
duplicating it. Either is fine; the comment above it explains the trade-off.

## Dry runs

`--dry-run` is an **integer** flag: `DRY_RUN=0` in the variable block, set to `1`
by the flag, tested in arithmetic context as `(( DRY_RUN == 1 ))` or
`(( DRY_RUN ))`. Never a string, never `[[ ]]`.

Pick one of four sanctioned mechanisms:

| Mechanism | Reference | Use when |
| --- | --- | --- |
| Bare `run()` wrapper | `run()` in `git/git_sync_default.sh` | Arguments have no spaces. |
| `run()` with `printf %q` quoting | `run()` in `git/gacp.sh` | Arguments may contain spaces (commit messages). |
| Labelled `run_cmd "label" cmd…` | `run_cmd()` in `macos-initial-setup/stay_fresh.sh` | The script also writes a log file. `run_cmd_tty()` is its sibling for anything that must keep a terminal (sudo, cask prompts). |
| Inline per-branch | `git/git_amend_last.sh` | The "command" is not a single exec. |

### There are three output grammars — pick by package, do not mix

The `git/` package prints:

```text
dry-run: would run: git fetch origin main
dry-run complete; no changes written
```

The `macos-initial-setup/` package prints a dimmed, two-space-indented form with
no terminal summary line — `run_cmd()` prints the first shape and `clear_dir()`
the second, both in `macos-initial-setup/stay_fresh.sh`:

```text
  (dry-run) brew upgrade [homebrew upgrade]
  (dry-run) would remove contents of /Users/x/Library/Caches/foo
```

The `linux/` package closes with `git/`'s summary line while previewing actions
in the indented form, for example from `run_cmd()` in `linux/stay_fresh.sh`:

```text
  (dry-run) pip3 cache purge [pip cache purge]
dry-run complete; no changes written
```

All eight `linux/` scripts that take `--dry-run` print that closing line, and
seven of the eight produce the indented `(dry-run)` preview above it. So the
shape above is the package norm, not one script's habit. What varies is only
how a script gets there, and `config_backup.sh` is the single script that does
not produce it at all:

- The indented prefix is emitted three ways, all rendering the same: `run_cmd()`
  in `linux/stay_fresh.sh` and `linux/install_devtools.sh`, `run_root()` in
  `linux/disk_cleanup.sh`, and bare `printf` in `linux/install_aliases.sh`,
  `linux/packages.sh`, `linux/sysctl_defaults.sh` and
  `linux/systemd/stay_fresh_timer.sh`. Reach for `run_cmd()` when a preview
  wraps a real command; a `printf` is fine when it does not.
- `config_backup.sh` previews with `info "would create …"` — unindented, no
  `(dry-run)` prefix — and prints its summary through `info` too, so the line
  arrives as `[info] dry-run complete; no changes written`.
- `packages.sh` mixes three forms in one preview path, including `git/`'s
  `dry-run: would run:` that this section tells you not to mix. Its `printf`
  there also omits the trailing newline, so the summary line is appended to it
  on the same line. That is a defect, not a fourth grammar.

Nothing enforces the closing line generically: the four assertions in
`linux/tests/test_linux_scripts.sh` name `install_devtools.sh`,
`disk_cleanup.sh` and `config_backup.sh` individually, and the repository-wide
dry-run check compares filesystem state rather than output. A new `linux/`
script that omitted the line would pass CI, so this is a convention you keep by
reading, not one the suite keeps for you.

Match the package you are writing in. A new top-level package picks one in its
README and sticks to it.

Whichever you use, the contract is absolute: **a dry run writes nothing.** The
test suites assert this by snapshotting state before and after.

## Output

Colours are `C_<COLOUR>` constants defined under a TTY guard with an
empty-string `else` branch. Every Bash script honours `NO_COLOR`; copy this
form:

```bash
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
else
  C_RESET=''; C_RED=''; C_GREEN=''
fi
```

Level helpers use six-character padded labels so output columns line up
(`info`/`ok`/`warn`/`err` in `macos-initial-setup/brewfile.sh`):

```bash
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
```

`info`, `ok` and `warn` go to stdout; **only `err` goes to stderr**. Prefer
`printf` over `echo`. The colour block itself is allowed to vary in which
colours it defines — the level-helper grammar is not.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, including every `--help`. |
| `1` | Generic failure — the work ran and some of it did not succeed. |
| `2` | Wrong environment — not a git repo, not macOS, no `git` on `PATH`. |
| `3` | Invalid usage — unknown flag, missing flag value, failed validation. |
| `4` | Domain no-op — nothing to commit, no base branch, dirty tree, index out of range. |
| `5` | Reserved to `gacp.sh` (push from detached HEAD). Do not reuse. |

A script may implement a subset. The `macos-initial-setup/` package narrows `1`
to "one or more installs failed" and `2` to "preflight checks failed", and
documents that in each file's header — do the same if you narrow a meaning.

## Log files

Only heavyweight install and maintenance scripts write logs; `git/*.sh` write
none. The pattern (`LOG_FILE` in `macos-initial-setup/stay_fresh.sh`):

```bash
LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/stay_fresh-$(date +%Y%m%d-%H%M%S).log"
```

Truncate and write a header line at startup, print the path inside `usage()` and
again at the end, and have `--verbose` switch from `>>"$LOG_FILE" 2>&1` to
`2>&1 | tee -a "$LOG_FILE"` with `rc="${PIPESTATUS[0]}"` to keep the real exit
status.

**Guard all of that behind `(( DRY_RUN == 1 ))`.** A dry run writes nothing, and
the log is not an exception — this sentence used to say "truncate at startup"
with no qualifier, and five scripts duly created a timestamped file on every
preview, leaving orphans in `TMPDIR` and contradicting the first promise in
`README.md`. Under a dry run, print the path you *would* have written instead:

```bash
if (( DRY_RUN == 1 )); then
  info "dry-run: would write log: $LOG_FILE"
else
  : > "$LOG_FILE"
  printf 'stay_fresh.sh log - %s\n' "$(date)" >> "$LOG_FILE"
  info "log file: $LOG_FILE"
fi
```

`test-env/static/check_conventions.sh` asserts this by running every
`--dry-run`-capable CLI against a scratch `HOME` and `TMPDIR` and failing on any
filesystem change, so a regression here is caught by CI rather than by someone
noticing stray files months later.

## PowerShell scripts

Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`), then
`[CmdletBinding()]`, then `param()`, then `$ErrorActionPreference`.

Use a hand-rolled `[switch]$DryRun` — **not** `-WhatIf`/`SupportsShouldProcess`.
This is a deliberate divergence from PowerShell convention so the Windows
scripts read the same as the Bash ones, and because the dry-run modes here
accumulate and report a total (bytes that *would* be freed) which
`ShouldProcess` cannot express. This section is the rule; the Windows README
points here.

Output is `Write-Host -ForegroundColor`, one line per item, opening with a
fixed-width verb and a padded label. `templates/new_script.ps1` is the shape to
copy:

```powershell
Write-Host ('WOULD {0,-38} {1,10}' -f $Label, (Format-Size $bytes)) -ForegroundColor Cyan
Write-Host ('CLEAN {0,-38} {1,10}' -f $Label, (Format-Size $bytes)) -ForegroundColor Green
Write-Host ('SKIP  {0,-38} {1,10}' -f $Label, '(not found)') -ForegroundColor DarkGray
Write-Host ('FAIL  {0,-38} {1}' -f $Label, $_.Exception.Message) -ForegroundColor Red
```

What is actually fixed is the verb column: five characters, so `SKIP` and
`FAIL` carry a trailing space and every label starts in the same place. The
`{1,10}` field holds a size where there is one and a right-aligned reason where
there is not.

Do not read more uniformity into it than exists. The verb set is open — the
template adds `FAIL`, and `windows/wsl/wsl_manage.ps1` uses `KEEP` and `PRUNE`
for a retention report. Widths follow the content: `wsl_manage.ps1` pads its
label to 44 because distro names are longer, and several lines in
`clean_disk_c.ps1` drop the size field or spell the reason inline rather than
in the 10-wide column. Match the file you are editing; when writing a new one,
start from the template.

`PSScriptAnalyzerSettings.psd1` excludes exactly one rule:
`PSAvoidUsingWriteHost`, because these are interactive operator scripts whose
output is a colour-coded human report. Everything else PSScriptAnalyzer reports
at `Warning` or above is a real finding — fix it.

`PSUseShouldProcessForStateChangingFunctions` is deliberately **not** excluded.
It does not fire on the current helpers, because they declare a bare `param()`
rather than `CmdletBinding` on the function itself. Leave it enabled so it
catches a future function that takes `CmdletBinding` without a dry-run story.
A document that claimed it was excluded would have someone widen the settings
file instead of writing the dry run.

For a genuine one-off exception use
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]` at the site, with a
non-empty `Justification` string. Repository-wide policy belongs in the settings
file instead, where it gets explained once.

## RouterOS scripts

The `.lua` extension is for editor highlighting only — these are RouterOS
scripting language, not Lua.

- **Secrets never appear in a script body.** Read them from `:global` variables
  set once at boot, the way `mikrotik/tg_send.lua` reads `TG_BOT_TOKEN`
  and `TG_CHAT_ID`.
- Send notifications through `tg_send`, wrapped so a missing helper degrades to
  a log line instead of an error (`mikrotik/backup.lua`).
- **Alert on transitions, not on every run.** Keep the previous state in a
  `:global` and compare — `wan_failover_notify.lua` is the reference. A script
  that alerts every five minutes gets muted, which makes it worse than nothing.
- First run establishes a baseline silently.
- Always `:log` as well as notifying; the router log is the source of truth.
- **Fail safe when unconfigured.** `mac_allowlist_dhcp.lua` refuses to act on an
  empty allowlist rather than blocking every client. Any script that deletes or
  blocks needs an equivalent floor, and that floor should be its first test.

## Python helpers

Standard library only, and they must run under the Python 3.9 that
`/usr/bin/python3` provides on macOS — that is what CI pins. Ruff enforces
`E,F,I,B,UP,SIM` with `UP031`/`UP032` ignored, so percent-formatting is fine.

Diagnostic tools are **read-only**: they explain and print the command that
fixes the problem, they never edit config or touch an agent
(`git/git_ssh_doctor.py`).

Structure them so the interesting logic is pure and takes its input as a
string — parsers get unit tests with fixture data, and anything that shells out
stays untested by design. Inject anything ambient (a `PATH` string, a
directory, the current time) as a parameter so tests do not depend on the host
or rot with the calendar.

## Tests

Every package has a `tests/run.sh` that takes no required arguments, is
executable, and exits non-zero on failure. `run-tests.sh` is the single
entry point and CI calls it, so a green run locally and a green run in CI mean
the same thing.

The Docker suites mount the repository **read-only** at `/repo`, so all scratch
state goes under `/tmp` via `mktemp -d`. Test bodies are hand-rolled harnesses —
`failures=0`, `ok()`/`err()`, `assert_contains`/`assert_eq`, `# --- section ---`
comments — see `git/tests/test_git_scripts.sh`. No framework.

Because `set -e` is on in test bodies, assert exit codes with the sandwich:

```bash
set +e
out="$("$SCRIPT" --bad-flag 2>&1)"; rc=$?
set -e
```

Do not add a new hardcoded list of scripts to a test. The static suite discovers
command-line scripts by role, so a new script is covered by the commit that
creates it.

## Adding a script

The rules above are per-topic. This is the order to do them in, and the two
documentation entries a script is not finished without.

1. **Copy a template.** `templates/new_script.sh`, `new_script.ps1` or
   `new_helper.py` are working no-ops, not sketches. Put the copy in the
   package it belongs to; the repository root is not a package.
2. **Fix the dialect the template cannot guess.** `new_script.sh` ships
   `set -euo pipefail` and the `git/` dry-run grammar. Outside `git/` both are
   wrong: take the `set` line for your package from the table under
   [Bash scripts](#bash-scripts) and the output grammar from
   [Dry runs](#dry-runs). Nothing in CI checks either, so this is the step
   worth being deliberate about.
3. **`chmod +x` and `git add` it.** Both matter, and the second is the one
   people miss. The static suite discovers its subjects from the git index
   (`git ls-files -s`, mode `100755`, a shebang on line 1), so an unstaged
   script is not checked at all and the suite passes green without having seen
   it.
4. **Run `./run-tests.sh static`.** It checks `--help` before preflight, the
   unknown-flag exit, the shebang, the file mode, `.gitattributes` coverage,
   Bash 3.2 constructs where they apply, and that a dry run writes nothing
   under `HOME` or `TMPDIR`.
5. **Write the package README section.** A level-two heading naming the script,
   with its flags and its exit codes. This one is enforced:
   `test-env/static/test_doc_citations.sh` fails if a shipped script has no
   mention in the README beside it, and fails the other way if a heading names
   a script that is not there.
6. **Add the root README "at a glance" row.** One line in the section for that
   package. Nothing enforces this one — the citation check excludes the
   repository root, because holding an index of packages to "name every script
   beside you" would mean naming every script in the tree. It is still half of
   what the pull request template means by "the folder README and the root
   README were updated".
7. **Add a `CHANGELOG.md` entry** under `[Unreleased]`, in the voice the
   entries around it use: what changed and why it mattered, not a commit
   subject.

A script that touches a machine also needs `--dry-run` before it needs
anything else. That is the promise this repository makes, and it is the one
thing a reviewer will check by hand.

## File modes and line endings

- Executable scripts are mode `755`; sourced files (`*.zsh`, `*.aliases`) and
  documentation are `644`. A sourced file has no shebang and must not be
  executable.
- Every text file type is pinned to LF in `.gitattributes`. If you add a new
  file extension, add a rule. The patterns are path-anchored — a pattern
  matching `windows/git-bash/.bashrc` does **not** match a nested copy under
  `windows/git-bash/default-git-bash/`.

Both are asserted by the static suite.

## Repository settings

A few things live in GitHub's settings rather than in the tree, so no pull
request can fix them and no test can catch them missing. This is the owner's
checklist — a contributor cannot do any of it, but can point at this section in
an issue.

- [ ] **Description.** The one line under the repository name is what shows up
      in search results and on a profile. Something concrete, for example:
      "Helper scripts for macOS, Linux, Windows and MikroTik RouterOS — every
      script has `--help`, a documented exit code, and a dry run that writes
      nothing."
- [ ] **Topics.** These are how the repository is found at all; without them it
      is reachable only by name. Suggested set: `bash`, `shell-scripts`,
      `powershell`, `macos`, `linux`, `windows`, `routeros`, `mikrotik`,
      `devops`, `dotfiles`, `shellcheck`, `automation`.
- [ ] **Website field.** Leave it empty rather than pointing it at the
      repository itself.
- [ ] **Discussions.** Enable them (*Settings → General → Features*). Issues here
      are for a specific bug or a specific script request — the two templates in
      [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/) say so — and "how do
      you handle X on your machines" has nowhere else to go today.
- [ ] **Releases.** The sidebar shows a Releases panel only once a tag exists,
      and a repository with no releases reads as unmaintained regardless of how
      recent the commits are. [`CHANGELOG.md`](CHANGELOG.md) is the groundwork:
      cut the first tag from its `[Unreleased]` section and paste that section
      in as the release notes.
- [ ] **Branch protection on `master`.** Require the CI checks that already run,
      so the gates in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) are
      binding rather than advisory. Note the constraint recorded there: jobs are
      never skipped at the job level, precisely so a required check always
      reports.
- [ ] **Workflow pull requests.** Enable *Settings → Actions → General →
      Workflow permissions → Allow GitHub Actions to create and approve pull
      requests*. The twice-weekly RouterOS version workflow needs this to open
      its tested `chore/routeros-VERSION` bump PR; it still cannot bypass branch
      protection or write directly to `master`.
- [ ] **Labels.** At minimum `good first issue` and `help wanted` — GitHub
      surfaces both in its own contributor-facing views.

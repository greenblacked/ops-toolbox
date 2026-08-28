---
name: running-tests
description: How testing works here - run-tests.sh as the single entry point, the eight suites and which need Docker, how to drive suites directly on a host without it, the hand-rolled harness style with no framework, the set +e sandwich for asserting exit codes, and the hard-won rules about what makes a test worth having. Use this whenever you run, add, fix or debug a test in this repository, when deciding what coverage a change needs, or when reporting which suites you ran.
---

# Testing in this repository

`./run-tests.sh` is the single entry point, and CI calls the same script, so
"it passed locally" and "it passed in CI" mean the same thing. It selects,
sequences and reports; each suite lives in its own `tests/run.sh`.

```bash
./run-tests.sh                          # the fast default
./run-tests.sh all                      # adds the RouterOS CHR suite
./run-tests.sh git macos                # an explicit subset
./run-tests.sh --list                   # machine-readable inventory
./run-tests.sh --summary-file out.json linux
./run-tests.sh mikrotik -- -k version_matches   # trailing args go to the suite
```

## The suites

| Suite | What it proves | Docker |
| --- | --- | --- |
| `git` | Git helpers against throwaway repos and bare remotes | yes |
| `macos` | macOS scripts, including `stay_fresh.sh` run for real | yes |
| `linux` | Scripts run inside pinned Debian, Fedora and Arch containers | yes |
| `k8s` | Script contracts only; the image build is opt-in | no |
| `python` | ruff plus stdlib `unittest` for the helpers | no |
| `static` | Repository-wide conventions, self-discovering | no |
| `windows` | PowerShell contracts; skips itself silently without `pwsh` | no |
| `mikrotik` | Real RouterOS CHR under QEMU - minutes, not in the default set | yes |

The Docker preflight only runs when a suite that needs one is selected, so
`./run-tests.sh python static` works on a host with no Docker at all. Two more
suites can be driven directly where Docker is missing:

```bash
REPO_ROOT="$PWD" EXPECT_PKG_MGR=apt bash linux/tests/test_linux_scripts.sh
pwsh -NoProfile -File windows/tests/contract.ps1
```

`run-tests.sh` does **not** cover the Lint job - see the `pre-push-gates` skill
before pushing.

## Writing a test here

Test bodies are hand-rolled harnesses. No framework: `failures=0`, `ok()` and
`err()`, `assert_contains`/`assert_eq`, `# --- section ---` comments. Read
`git/tests/test_git_scripts.sh` before writing a new one.

The Docker suites mount the repository **read-only** at `/repo`, so all scratch
state goes under `/tmp` via `mktemp -d`.

Because `set -e` is on in test bodies, assert exit codes with the sandwich:

```bash
set +e
out="$("$SCRIPT" --bad-flag 2>&1)"; rc=$?
set -e
```

**Do not add a hardcoded list of scripts to a test.** The static suite
discovers command-line scripts by role - tracked, mode 755, has a shebang, not
under `tests/` or `test-env/` - so a new script is covered by the commit that
creates it. Hardcoded lists are what rotted first here: the macOS suite quietly
stopped covering `brewfile.sh` and `launchd/stay_fresh_agent.sh`, which is the
drift `test-env/lib/discover_clis.sh` exists to prevent. If a new script needs
extra arguments to reach its main path, add it to the `dry_run_args()` table in
`test-env/static/check_conventions.sh` instead - that table fails loudly when a
discovered script is missing from it.

## What makes a test worth having

The recurring defect here is not a missing test - it is a test that asserts the
shape its author had in mind. Every one of these reached `master`:

- `--coredump-dir /` was covered; `//`, `/.` and `/../` reach the same
  directory and were not, and each reached a recursive delete.
- `--dry-run` was covered; `install --dry-run` was not, and it wrote two
  systemd units and started a timer.
- A PowerShell `install -DryRun` was covered on Linux, where the platform guard
  fires first; on Windows it called `choco list` to work out what was missing
  and created two directories doing it.
- `--list` was covered with its exit status discarded, so it could have
  regressed to exit 3 and still passed.
- The `linux` suite asserted the string `dry-run complete; no changes written`
  and passed for months while five scripts created a log file on every preview.
- A release-feed title was matched against one channel name; the feed lists
  every channel a release sits in, and the first multi-channel release took the
  whole workflow down.

So, concretely: test the other spellings of the same input; drive subcommands
through their real entry points; assert exit codes rather than discarding them;
and **check the filesystem rather than the script's own claim about it**. When
fixing a bug, first confirm the new test fails against the unfixed code - if it
passes before your fix, it is testing something else.

## Reporting what you ran

Say plainly which suites actually ran, and on which platform. A `windows` run
on Linux stops at each `$IsWindows` guard and proves nothing about the dry-run
promise; a suite skipped for a missing `pwsh` or Docker daemon is a gap, not a
pass. A pull request that admits a gap is worth more than one that claims a
suite it could not execute.

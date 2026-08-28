---
name: ops-toolbox-conventions
description: The load-bearing rules of this repository - the three promises every script makes (--help before preflight, a dry run writes nothing, every script stands alone), the shared exit-code table, the package map, and which sibling skill covers the file you are about to touch. Use this whenever you are about to read, change, add or review anything in this repository, including a one-line edit, and whenever you are asked what the conventions here are or whether a change fits them.
---

# Working in ops-toolbox

This repository is a collection of **standalone** operator scripts for macOS,
Linux, Windows, MikroTik RouterOS and Kubernetes. It is not an application, and
almost every instinct that serves an application badly serves this repository
worse. Read this before touching anything, then open the sibling skill for the
language you are working in.

## The three promises

They are stated at the top of `README.md` and asserted by the test suites, not
by prose. Breaking one is a failing build, not a style disagreement.

1. **`--help` works before anything else** - including on a machine the script
   refuses to run on. `./macos-initial-setup/install_apps.sh --help` exits 0 on
   Linux. An unrecognised flag exits `3`.
2. **A dry run writes nothing.** Anything that changes a machine takes
   `--dry-run` (or `-DryRun` on PowerShell), and anything destructive sits
   behind an explicit opt-in flag. This is checked against the filesystem, not
   against the script's own claim about itself.
3. **Every script stands alone.** One file copied into `~/bin`, or one RouterOS
   script pasted into a router, has to work with nothing else brought along.

## The architectural rule that surprises people

**Duplication across scripts is deliberate.** `require_value()` appears in
seven scripts; `Format-Size` in two `.ps1` files. Do not factor them into a
shared library - `source "$SCRIPT_DIR/../lib/common.sh"` breaks the entire
distribution model, which is promise 3 above.

What is asserted about the copies is their **contract**, not byte-identity:
the same guard condition, `exit 3`, and a message on stderr. Copies differ
defensibly already (`git/set_git_profile.sh` reports through its own `err()`
because it has one). See the "duplicated blocks keep their contract" section of
`test-env/static/check_conventions.sh` for what is actually checked.

Shared code is permitted in exactly one shape: a substantial program with its
own tests, invoked as a subprocess by absolute path.
`macos-initial-setup/lib/workspace_scan.py` is the only thing that clears that
bar, and `macos-initial-setup/stay_fresh.sh:44-50` pays a seven-line
symlink-resolving preamble for the privilege. Worth it once for a real program;
never for a seven-line validator.

If you catch yourself proposing a refactor that consolidates duplication here,
you have found the one change this repository will always reject. Propose a
better *test* of the copies instead - that is where divergence belongs.

## Exit codes, repository-wide

| Code | Meaning |
| --- | --- |
| `0` | Success, including every `--help`. |
| `1` | Generic failure - the work ran and some of it did not succeed. |
| `2` | Wrong environment - not a git repo, not macOS, no `git` on `PATH`. |
| `3` | Invalid usage - unknown flag, missing flag value, failed validation. |
| `4` | Domain no-op - nothing to commit, no base branch, dirty tree, index out of range. |
| `5` | Reserved to `gacp.sh` (push from detached HEAD). Do not reuse. |

A script may implement a subset, and may narrow a meaning if it documents that
in its own header - `macos-initial-setup/` narrows `1` to "one or more installs
failed" and `2` to "preflight checks failed". Python helpers using `argparse`
exit `2` on a usage error, which is argparse's convention; the static suite
exempts `*.py` from the unknown-flag check for exactly that reason.

## The package map

| Path | What lives there | Notes that bite |
| --- | --- | --- |
| `git/` | Git helper scripts, `bash` | `set -euo pipefail`; Bash 3.2; no log files |
| `macos-initial-setup/` | Workstation bootstrap and maintenance | `set -u` + `set -o pipefail`, no `-e`; Bash 3.2; writes logs |
| `linux/` | Server and workstation scripts, multi-distro | Same `set` dialect as macOS; Bash 3.2; apt/dnf/pacman detection |
| `windows/` | PowerShell plus Git Bash dotfiles | `.ps1` is pure ASCII, no BOM; `windows/git-bash/` is Bash 5, not 3.2 |
| `mikrotik/` | RouterOS scripting language (`.lua` is for highlighting only) | Secrets via `:global`; alert on transitions |
| `k8s-toolbox/` | Pinned container toolbox plus driver scripts | Versions live in `versions.env`; the suite never builds the image |
| `templates/` | Working no-op starting points | Tracked, so CI holds them to every contract |
| `test-env/` | Test infrastructure - never a shipped CLI | Discovery excludes this wholesale, on purpose |

## Which skill to open next

- Writing or editing a `.sh` file - `bash-script-conventions`
- Writing or editing a `.ps1` file - `powershell-script-conventions`
- Writing or editing a `.lua` (RouterOS) file - `routeros-script-conventions`
- Writing or editing a `.py` helper - `python-helper-conventions`
- Adding a brand-new script of any language - `adding-a-script`, which is the
  end-to-end checklist and sends you to the language skill for the body
- Running or adding tests - `running-tests`
- About to push, or wondering why CI is red when local was green - `pre-push-gates`
- Touching a README or `CHANGELOG.md` - `docs-and-changelog`
- Committing, branching or opening a pull request - `commits-and-prs`

## Where the prose lives

`CONTRIBUTING.md` is the full convention document and cites the file and line
that establishes each rule. `AGENTS.md` covers what an automated agent gets
wrong here by default. These skills condense both; when they disagree with the
scripts, **the scripts win** - and then the rule was wrong and should be fixed
or deleted, which `CONTRIBUTING.md` says in its own opening.

## The failure mode to watch for in yourself

The recurring defect in this repository is not missing work, it is confident
work that was never exercised: a test that asserts the shape its author had in
mind, a `--dry-run` check that reads the script's output instead of the
filesystem, a suite claimed in a pull request that could not run on that
machine. Say plainly which suites you actually ran. A pull request that admits
a gap is worth more than one that papers over it.

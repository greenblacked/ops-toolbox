# Git scripts

[Ops Toolbox](../README.md) / **Git scripts**

Small Bash helpers for everyday Git configuration, quick commits, and repository housekeeping. They are written for portability: POSIX-minded patterns where possible, and **compatible with the Bash 3.2** that ships on macOS (no `mapfile` or other Bash 4-only features in these scripts).

Writing one? These scripts use `set -euo pipefail` — except `git_whoami.sh`, which omits `-e`, and `set_git_profile.sh`, which splits the same three options across three lines — the `git/` dry-run output grammar (`dry-run: would run: ...`, then `dry-run complete; no changes written`), and no log file at all. The grammar is not universal either: the branch-deleting scripts close with `dry-run complete; no branches deleted`, and `git_undo_last_commit.sh` and `git_amend_last.sh` print the `would run:` line with no closing line at all. [`CONTRIBUTING.md`](../CONTRIBUTING.md) collects that with the rest of the shell rules.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Scripts overview](#scripts-overview)
- [Exit codes (conventions)](#exit-codes-conventions)
- [Aliases](#aliases)
- [`gacp.sh`](#gacpsh)
- [`set_git_profile.sh`](#set_git_profilesh)
- [`git_whoami.sh`](#git_whoamish)
- [`git_status_summary.sh`](#git_status_summarysh)
- [`git_repos_status.sh`](#git_repos_statussh)
- [`git_unpushed.sh`](#git_unpushedsh)
- [`git_sync_default.sh`](#git_sync_defaultsh)
- [`git_cleanup_merged.sh`](#git_cleanup_mergedsh)
- [`git_prune_gone.sh`](#git_prune_gonesh)
- [`git_stale_branches.sh`](#git_stale_branchessh)
- [`git_size_report.sh`](#git_size_reportsh)
- [`git_recent_branches.sh`](#git_recent_branchessh)
- [`git_repo_root.sh`](#git_repo_rootsh)
- [`git_diff_branch.sh`](#git_diff_branchsh)
- [`git_merge_check.sh`](#git_merge_checksh)
- [`git_undo_last_commit.sh`](#git_undo_last_commitsh)
- [`git_amend_last.sh`](#git_amend_lastsh)
- [`git_hooks_install.sh`](#git_hooks_installsh)
- [`git_commitlint.sh`](#git_commitlintsh)
- [`git_release_notes.sh`](#git_release_notessh)
- [`clone-repos.sh`](#clone-repossh)
- [`git_bundle_backup.sh`](#git_bundle_backupsh)
- [`git_ssh_doctor.py`](#git_ssh_doctorpy)
- [`git_signing_doctor.py`](#git_signing_doctorpy)
- [`git_remote_doctor.py`](#git_remote_doctorpy)
- [`git_ignore_doctor.py`](#git_ignore_doctorpy)
- [`git_health_doctor.py`](#git_health_doctorpy)
- [`git_secrets_doctor.py`](#git_secrets_doctorpy)
- [`git_hooks_doctor.py`](#git_hooks_doctorpy)
- [`git_submodule_doctor.py`](#git_submodule_doctorpy)
- [`git_fleet_doctor.py`](#git_fleet_doctorpy)
- [Tests](#tests)
- [Quick reference (copy-paste)](#quick-reference-copy-paste)

## Requirements

| Requirement | Notes |
| --- | --- |
| **Bash** | 3.2 or newer (`/bin/bash` on macOS is enough). |
| **Git** | Recent Git 2.x (scripts use `git switch`, `for-each-ref` formats, etc.). `git_merge_check.sh` needs Git 2.38 or newer for `git merge-tree --write-tree`, and exits `2` on anything older. |
| **zsh** | Optional; only needed if you `source git_aliases.zsh`. Bash users source `git_aliases.sh` instead. |
| **Python 3.9+** | Optional; only for the `*_doctor.py` diagnostics. Standard library only — the macOS system interpreter is enough. |
| **Docker** | Optional; only for running the test suite (`git/tests/run.sh`). |

## Quick start

There is nothing to install. Every script here is self-contained and runs
straight out of a clone, except that `git_aliases.sh` defines an alias only for
scripts found next to it or on `PATH`. From the repository root:

```bash
./git/git_whoami.sh                      # the name and email this repo would commit as
./git/git_status_summary.sh              # branch, upstream, ahead/behind, dirty counts
./git/gacp.sh --dry-run -m "a message"   # what add + commit + push would run; changes nothing
```

Start with `git_whoami.sh`. It answers the question that costs the most to get
wrong — the identity Git will actually use *here*, after every global setting
and repository-local override has been applied — and it writes nothing.
`--expect-email` turns the same report into a check that fails instead of
merely printing, which is what makes it usable in a hook or in CI.

Everything that would change a repository accepts `--dry-run` and prints the
exact commands it would run first. When the scripts have earned their place,
the [aliases](#aliases) give each one a short name.

## Scripts overview

| File | Purpose |
| --- | --- |
| `gacp.sh` | Stage all changes, commit with a message, and push; `--staged-only` keeps unrelated work out. |
| `git_aliases.zsh` | zsh aliases for every helper here, each guarded on the script being installed. |
| `git_aliases.sh` | The same aliases for bash. Sourced, not run. |
| `set_git_profile.sh` | Set Git identity globally or per repository, save named profiles, apply them later. |
| `git_whoami.sh` | Show the effective identity and optionally enforce an expected email. |
| `git_status_summary.sh` | Compact status with optional stable `--porcelain` output. |
| `git_repos_status.sh` | One-screen status of every checkout under a directory; `--strict` fails while work exists only locally. |
| `git_unpushed.sh` | Everything in one repository that exists only on this machine: commits, upstream-less branches, stashes, edits, tags. |
| `git_sync_default.sh` | Fast-forward the default branch and optionally restore the starting branch. |
| `git_cleanup_merged.sh` | Delete merged local branches, with include/exclude filters and dry-run. |
| `git_hooks_install.sh` | Install staged-content guards; token scanning, Conventional Commits and a protected-branch pre-push guard are opt-in. |
| `git_commitlint.sh` | Lint every commit message a branch adds, in CI, against the commit-msg hook's rules. |
| `git_release_notes.sh` | Release notes grouped by Conventional Commit type since the last tag, and the next semver version. |
| `clone-repos.sh` | Clone every repository in a list file into one parent directory; skips what is already there, or fast-forwards it with `--update`, and `repos.txt.example` shows the format. |
| `git_bundle_backup.sh` | Write a verified, timestamped bundle of every ref, with opt-in retention of older bundles. |
| `git_prune_gone.sh` | Delete branches with deleted upstreams, with include/exclude filters. |
| `git_stale_branches.sh` | Report old branches and optionally filter by gone/merged/unmerged state. |
| `git_size_report.sh` | Report repository size across all history or selected refs. |
| `git_recent_branches.sh` | List/switch recent branches; `--names-only` is script-friendly. |
| `git_repo_root.sh` | Print the worktree root or absolute Git metadata directory. |
| `git_diff_branch.sh` | Diff committed branch work or include the current index/worktree; `--name-only`, `--path` and `--require-changes` answer "did anything under X change?" in CI. |
| `git_merge_check.sh` | Forecast whether branches merge cleanly into a base, with no checkout (Git 2.38+). |
| `git_undo_last_commit.sh` | Reset local HEAD or create a history-preserving revert commit. |
| `git_amend_last.sh` | Amend content and optionally replace the last commit message. |
| `git_ssh_doctor.py` | Diagnose SSH auth; `--quiet` exposes only the verdict exit code. |
| `git_signing_doctor.py` | Diagnose signing backends; `--quiet` supports CI probes. |
| `git_remote_doctor.py` | Diagnose remote URLs/rewrites/credentials; `--quiet` supports CI probes. |
| `git_ignore_doctor.py` | Explain why a path is ignored or is not; with no argument, find tracked files a rule claims. |
| `git_health_doctor.py` | Stale locks, a gc.log blocking automatic gc, object bloat, maintenance and clone shape; `--fsck` is opt-in. |
| `git_secrets_doctor.py` | Committed credentials: credential-shaped names, key and token formats in content, and with `--history` files deleted but still in history. |
| `git_hooks_doctor.py` | Why a hook does not run: `core.hooksPath`, exec bit, CRLF shebang, misnamed hooks, hook managers committed but not activated. |
| `git_submodule_doctor.py` | Submodule mapping, initialisation, URLs that only work on one machine, and `.git/config` drift. |
| `git_fleet_doctor.py` | Run every doctor across the repositories under one or more roots and print one table of verdicts. |
| `tests/` | Docker-based checks (Shellcheck, `bash -n`, integration scenarios). |

## Exit codes (conventions)

Across these scripts, exit statuses are used consistently where it helps automation:

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Generic failure (e.g. `git_cleanup_merged.sh` if one or more `git branch -d` calls failed after others succeeded). |
| `2` | Wrong environment (not in a Git repo, `git` missing, etc.). |
| `3` | Invalid usage or validation error (bad flags, missing values). |
| `4` | Domain / no-op conditions (`set_git_profile.sh`: missing profile; `gacp.sh`: nothing to commit). |
| `5` | `gacp.sh` only: push requested from a detached HEAD. |

Scripts that do not need the full table may use a smaller subset (for example `git_whoami.sh` only cares about `2` for missing `git`).

**Doctor output for scripts.** Every `*_doctor.py` except
`git_fleet_doctor.py` (which drives the others) takes `--json` and prints one
JSON object instead of the report, with the same exit code as a text run.
For `git_ignore_doctor.py secrets.txt`, with the other events left out:

```json
{"events": [{"level": "fail", "message": "not ignored — the file is tracked, so ignore rules do not apply", "section": "secrets.txt"}], "exit_code": 1, "problems": 1, "schema": 1, "tool": "git_ignore_doctor.py"}
```

Each event is one line of the report: `level` is `ok`, `warn`, `fail`, `info`
or `detail` (a table row or list entry), `section` is the heading it sat
under, and `problems` counts the `fail` events. Every line is recorded after
the doctor's own redaction, so the JSON never holds more than the text did.
The shape is `schema` 1: keys and levels may be added, none is renamed.
`--json` and `--quiet` together are a usage error (exit `3`).

---

## Aliases

Two files, the same names in both:

```bash
# zsh
echo 'source /path/to/ops-toolbox/git/git_aliases.zsh' >> ~/.zshrc

# bash
echo '. /path/to/ops-toolbox/git/git_aliases.sh' >> ~/.bashrc
```

| Alias | Script | Alias | Script |
| --- | --- | --- | --- |
| `gacp` | `gacp.sh` | `gsync` | `git_sync_default.sh` |
| `gamend` | `git_amend_last.sh` | `gmerged` | `git_cleanup_merged.sh` |
| `gundo` | `git_undo_last_commit.sh` | `ggone` | `git_prune_gone.sh` |
| `gsum` | `git_status_summary.sh` | `gstale` | `git_stale_branches.sh` |
| `gdiffb` | `git_diff_branch.sh` | `gsize` | `git_size_report.sh` |
| `grecent` | `git_recent_branches.sh` | `ghooks` | `git_hooks_install.sh` |
| `groot` | `git_repo_root.sh` | `gprofile` | `set_git_profile.sh` |
| `gwho` | `git_whoami.sh` | `gssh` | `git_ssh_doctor.py` |
| `grepos` | `git_repos_status.sh` | `gsign` | `git_signing_doctor.py` |
| `gunpushed` | `git_unpushed.sh` | `gremote` | `git_remote_doctor.py` |
| `gmcheck` | `git_merge_check.sh` | `gignore` | `git_ignore_doctor.py` |
| `glint` | `git_commitlint.sh` | `gnotes` | `git_release_notes.sh` |
| | | `gbundle` | `git_bundle_backup.sh` |

Each alias is defined only if its script is actually there: next to the alias file, or failing that under that name on `PATH`, for anyone who copied the scripts into `~/bin`. An alias pointing at a script that is not installed is worse than no alias — it fails at use time, in the middle of something else, with a message about a missing file rather than about the alias.

The names avoid the two-letter Git aliases in [`linux/bash_aliases.sh`](../linux/bash_aliases.sh) (`gs`, `gd`, `gl`, `gp`, `gb`), so a bash user can source both files.

Both are **sourced, not executed**. `git_aliases.sh` carries a `.sh` extension rather than being a dotfile so it is covered by the repository's `bash -n` and ShellCheck passes; running it directly prints the line to add to `~/.bashrc` and exits `3`.

---

## `gacp.sh`

Stages everything (`git add --all`), commits with `-m`, and pushes. If there is no upstream, it runs `git push -u <remote> <branch>` (defaults: remote `origin`, branch = current).

**Examples**

```bash
./git/gacp.sh "update git scripts"
./git/gacp.sh --dry-run -m "preview commit"
./git/gacp.sh --no-push -m "local only"
git add path/to/intended-file
./git/gacp.sh --staged-only -m "commit only the index"
```

`--staged-only` skips `git add --all`. It exits `4` when the index is empty,
even if the working tree contains other changes; those changes are left alone.

**Exit codes**

- `4` — working tree clean (nothing to commit).
- `5` — detached HEAD and push not disabled (use `--no-push` or check out a branch).

**Alias:** `gacp "update git scripts"` — see [Aliases](#aliases).

---

## `set_git_profile.sh`

Manages **global** `user.name` and `user.email` and optional **named profiles** stored in a Git config file (not the global `~/.gitconfig`).

**State file**

```text
${XDG_CONFIG_HOME:-$HOME/.config}/ops-toolbox/git-profiles.conf
```

Profiles are stored as `profile.<name>.name` and `profile.<name>.email`. Override the path with `--state-file`.

This repository used to be called `pretty-useful-scripts`, and profiles saved
before the rename live under a directory of that name. They are still found:
if the path above does not exist and the old one does, the old one is used and
`--show` prints the `mv` that migrates it. Once the new path exists it always
wins, so a migrated machine is never pulled back to the stale file.

**Examples**

```bash
./git/set_git_profile.sh --name "Sergey" --email "your@email.com"
./git/set_git_profile.sh --save personal --name "Sergey" --email "your@email.com"
./git/set_git_profile.sh --profile personal
./git/set_git_profile.sh --local --profile work
./git/set_git_profile.sh --save-current work
./git/set_git_profile.sh --list
./git/set_git_profile.sh --show
./git/set_git_profile.sh --dry-run --profile personal
```

**Short positional form** (name and email only, no flags):

```bash
./git/set_git_profile.sh "Sergey" "your@email.com"
```

**Behavior**

- Exactly one “action” per run (direct set, `--save`, `--profile`, `--save-current`, `--list`, or `--show`).
- `--dry-run` prints what would run without writing local/global config or the state file.
- `--local` is valid with direct set or `--profile`. It writes the checkout's
  `.git/config` and leaves the global identity untouched. Saved profiles remain
  in the same state file; the flag controls where an identity is applied, not
  where it is stored.

**Exit codes**

- `4` — saved profile missing or incomplete; global identity incomplete when using `--save-current`.

---

## `git_whoami.sh`

Prints the effective `user.name` / `user.email` for the current directory (respecting repo config), and shows global values when they differ.

```bash
./git/git_whoami.sh
./git/git_whoami.sh --expect-email release-bot@example.com
./git/git_whoami.sh --expect-email work@example.com --expect-email personal@example.com
```

`--expect-email` is repeatable and exits `1` unless the effective email matches
one of the allowed values. The normal identity report is still printed, so a CI
failure explains which repository-local override won.

---

## `git_status_summary.sh`

One-screen summary: branch (or detached), short `HEAD`, upstream, ahead/behind counts, and counts of changed / staged / unstaged / untracked paths.

```bash
./git/git_status_summary.sh
./git/git_status_summary.sh --porcelain
```

`--porcelain` prints stable tab-separated `key<TAB>value` lines in this order:
`branch`, `head`, `upstream`, `ahead`, `behind`, `changed`, `staged`,
`unstaged`, `untracked`. It omits headings and presentation placeholders; an
absent upstream has an empty value.

---

## `git_repos_status.sh`

The read side of `clone-repos.sh`: one line per checkout under a directory,
so "which of my thirty clones has uncommitted work, unpushed commits or a
stash, and which are behind?" is one command instead of a `cd` loop. Run it
before re-imaging a laptop, after a context switch, or as a morning catch-up.

```bash
./git/git_repos_status.sh --dir ~/src
./git/git_repos_status.sh --dir ~/src --dir ~/work --depth 3
./git/git_repos_status.sh --dir ~/src --only unpushed
./git/git_repos_status.sh --dir ~/src --fetch            # refresh refs first (network)
./git/git_repos_status.sh --dir ~/src --strict           # gate: exit 1 while anything is at risk
./git/git_repos_status.sh --dir ~/src --porcelain
```

| Option | Meaning |
| --- | --- |
| `--dir DIR` | Where to look; repeatable, default the current directory. A `DIR` that is itself a checkout is reported alone. |
| `--depth N` | How many directory levels below `DIR` to search (default `2`). A checkout is never descended into, so its own subdirectories and submodules are not reported separately. |
| `--only STATE` | Keep only rows that are `dirty`, `ahead`, `behind`, have `unpushed` commits, or have a `stash`. Rows that could not be checked are kept under every filter, so a filter cannot hide them from `--strict`: a failed git status, fetch, stash list or upstream walk and an `unreadable` checkout. The summary and `--strict` describe the filtered set. |
| `--fetch` | Run `git fetch --prune --quiet <remote>` for every remote of each checkout that has one, with terminal prompts off. It writes remote-tracking refs and nothing else; every remote is fetched by name (so `remote.<name>.skipFetchAll` cannot hide one), not only the default, and `--prune` drops refs for branches deleted on any of them, so commits that were pushed to a since-deleted branch count as unpushed. A failure on any remote is noted as `fetch-failed`, counts as work at risk (so `--strict` exits `1`) and the sweep goes on. |
| `--dry-run` | Print the fetch each checkout with a remote would get, report from the refs already on disk, and close with `dry-run complete; no changes written`. With `--porcelain` those lines go to stderr, so stdout carries only the rows. |
| `--strict` | Exit `1` when any reported checkout has work at risk. A checkout whose `git status` fails (for example a corrupt index) is noted `status-failed` and counts as at risk; so does a checkout whose history walk fails (a missing or unreadable object), noted `walk-failed`, because its unpushed count cannot be trusted; and so does one whose `git stash list` fails (a damaged `refs/stash`), noted `stash-failed`, because it cannot be shown to hold no stash. |
| `--porcelain` | Tab-separated rows, no header or colour: `path branch upstream ahead behind changed stash unpushed notes`. `path` is the checkout as found under `--dir`; an absent upstream is an empty field. |

The table columns are `REPO` (relative to the `--dir` it was found under),
`BRANCH` (`detached@<sha>` for a detached `HEAD`), `SYNC` (`=`, `+2`, `-1`,
`+2/-1`, or `-` with no upstream), `CHANGED` (tracked and untracked paths from
`git status`; ignored files do not count), `STASH`, `UNPUSHED` (commits on
local branches, or on a detached `HEAD`, that no remote-tracking ref contains)
and `NOTES`: `dirty`, `ahead`, `behind`, `diverged`, `detached`,
`no-upstream`, `no-remote`, `stash`, `status-failed`, `walk-failed`, `stash-failed`, `fetch-failed`, `unreadable`.

**Work at risk** is anything that exists only on this machine: changed or
untracked files, commits ahead of the upstream, unpushed commits, a stash, a
`--fetch` that failed, a `git status` that failed (`status-failed`) or a
history walk that failed (`walk-failed`) or a `git stash list` that failed
(`stash-failed`).
In a checkout with no remote every commit is unpushed, which is the truth. A
checkout git cannot read at all is counted as at risk too, because it could not
be proven otherwise. Being behind is reported but is not at risk.

Read-only apart from the opt-in `--fetch`. It never pulls, merges, checks out,
stashes or cleans, and `git status` runs with `--no-optional-locks`, so it does
not even refresh an index in a checkout an editor has open. Without `--fetch`
remote-tracking refs are as fresh as the last fetch in each checkout.

Exit codes: `0` success (a plain run exits `0` even when checkouts need
attention), `1` `--strict` found work at risk, `2` git missing or a `--dir` is
not a readable directory, `3` usage, `4` no repository found.

---

## `git_unpushed.sh`

What would you lose if this clone disappeared? Before reinstalling a laptop,
destroying a CI worker or a dev VM, or deleting a checkout, Git keeps the answer
in five different places, and this reports all five for the current
repository. `git_repos_status.sh` is the same question across many checkouts,
one line each; this is the detailed answer for one.

```bash
./git/git_unpushed.sh
./git/git_unpushed.sh --limit 20
./git/git_unpushed.sh --remote origin --tags   # also tags origin does not have
./git/git_unpushed.sh --strict                  # gate a decommission script
./git/git_unpushed.sh --porcelain
```

Each section is printed only when it has something in it:

| Section | What counts |
| --- | --- |
| commits on no remote | Commits on a local branch that no remote-tracking ref contains, with the newest subjects (`--limit`, default 5). On a detached `HEAD`, commits no branch holds either. |
| branches with no upstream | Local branches with no upstream configured, listed even when their commits are already on a remote, because the branch itself exists only here. |
| stashes | The stash count and the newest entry's subject. |
| uncommitted | Changed tracked files and untracked files. Ignored files are not counted. |
| tags missing or different on REMOTE | With `--tags` only: local tags the remote does not have, or has under the same name at a different object (a tag moved or re-annotated locally after it was pushed). |

`--remote NAME` counts a commit as pushed only when it is on that remote; the
default is any remote-tracking ref. An unknown name exits `4` rather than
quietly counting every commit. `--tags` asks `--remote NAME`, or the only remote
when there is exactly one, with `git ls-remote --tags`; with several remotes and
no `--remote` it exits `3`. A remote that cannot be reached is reported as
`cannot reach NAME` and exits `1`, because the question could not be answered. When `git status` fails or `--tags` cannot query the remote, the
result is `incomplete: could not check ...` on stdout instead of `nothing
exists only on this machine`, since a check that did not run is not a clean
answer.

A repository with no remotes at all prints `no remotes configured` once and
reports every commit as unpushed, which is the truth. The closing block prints
the command that deals with each kind of finding (`git push -u`,
`git stash branch`, `git switch -c`); nothing is ever run.

`--porcelain` prints `kind<TAB>name<TAB>count<TAB>detail` rows and no
headings, in this order: `commits` (name is the branch, or `HEAD` for a
detached one; detail is the newest subject), `no-upstream` (count is the
branch's commits on no remote), `stash` (detail is the newest subject),
`uncommitted` (name `tracked` or `untracked`) and `tag` (detail is the remote).

Read-only. It never fetches, so remote-tracking refs are as fresh as the last
fetch; `--tags` is the only network call, and `ls-remote` writes nothing.

Exit codes: `0` success, whether or not anything was found; `1` `--strict`
found something or could not read `git status` (reported on stderr), or
`--tags` could not reach the remote; `2` not a Git repository; `3` usage;
`4` no commits yet, or `--remote` names no remote. A plain run exits `0`
even when `git status` cannot be read.

---

## `git_sync_default.sh`

Requires a **clean** working tree. Fetches from `origin` (or `--remote`), checks out the target branch if needed, and fast-forwards with `git merge --ff-only`.

The default branch is resolved in order: `refs/remotes/<remote>/HEAD`, then `main`, then `master`; or pass `--branch`.

```bash
./git/git_sync_default.sh --dry-run
./git/git_sync_default.sh
./git/git_sync_default.sh --restore
```

By default the synchronized branch remains checked out, preserving the old
behavior. `--restore` returns to the branch that was active before the sync (or
to the original detached commit), including when the fetch or fast-forward
fails after the helper has switched branches.

---

## `git_cleanup_merged.sh`

Deletes **local** branches that are already merged into `--base` (default: current branch). Skips the base branch, the branch you are on, and names that look like protected branches (`main`, `master`, `develop`, …) unless you pass **`--force`**.

**Resilience**

- For each candidate branch, runs `git branch -d`. If one deletion fails, the script continues with the rest, prints a warning per failure, and exits `1` if any deletion failed (after reporting how many succeeded).

```bash
./git/git_cleanup_merged.sh --dry-run --base main
./git/git_cleanup_merged.sh --base main
./git/git_cleanup_merged.sh --dry-run --base main \
  --include 'feature/*' --exclude 'feature/keep-*'
```

`--include GLOB` and `--exclude GLOB` are repeatable shell-pattern filters.
When at least one include exists, a branch must match one; any matching exclude
then wins. Quote patterns so the current shell does not expand them as files.

---

## `git_prune_gone.sh`

Fetches the selected remote with `git fetch --prune`, then considers only local
branches whose configured upstream belongs to that remote and is `[gone]`.
`--remote NAME` defaults to `origin`; this restriction also applies with
`--no-fetch`, which uses the remote-tracking refs already on disk.

Tips not reachable from `HEAD` are skipped unless you pass `--allow-unmerged`.
Review them first: a deleted upstream cannot distinguish squash/rebase merges
from abandoned work. `--force` only overrides protected names and does not grant
consent for unmerged tips. Current branches, branches checked out in any linked
worktree, and symbolic branch aliases are always skipped. Pruning pauses entirely
while any worktree has an active rebase or bisect, including detached HEADs and
branches reserved by rebase updates. The repeatable
`--include GLOB` / `--exclude GLOB` filters match the contract of
`git_cleanup_merged.sh`: any exclude wins.

```bash
./git/git_prune_gone.sh --dry-run
./git/git_prune_gone.sh --remote origin --no-fetch --include 'feature/*' --exclude '*keep*'
# After reviewing work that is not reachable from HEAD:
./git/git_prune_gone.sh --no-fetch --allow-unmerged --include 'feature/reviewed'
```

Dry-run never fetches or rewrites refs, recovery state, or lock files. It previews
the current snapshot and names the fetch it would perform. Run
`git fetch --prune origin` first when you need a fresh preview.

Before **any** deletion, all eligible tips are saved atomically as direct refs
under `refs/ops-toolbox/prune-gone/<branch-name-hash>/<full-tip-SHA>`. A failed
recovery transaction leaves every candidate branch intact. Each deletion prints
the full SHA, recovery ref, and a quoted `git branch -- NAME SHA` restore command.
These refs keep commits reachable through reflog expiry and garbage collection;
deleting a branch removes its own reflog, so that reflog is not a recovery plan.
Deletion compares the full saved SHA and refuses a tip that changed in the
meantime. Branch configuration is retained for restoration (including its
upstream), rather than removed as with `git branch -D`.

Recovery storage is bounded to **1,000 refs per repository**, shared by linked
worktrees. Saving the same branch and tip reuses its ref. The cap counts refs,
not bytes of reachable history; even one retained tip may keep substantial
history. A run that would exceed the cap fails before any deletion. Recovery
refs have **no automatic expiration**, because expiring the only remaining copy
would silently discard work. List them and explicitly delete individual refs
only after restoring or verifying that you no longer need those commits:

```bash
git for-each-ref --format='%(refname) %(objectname)' refs/ops-toolbox/prune-gone/
# Replace RECOVERY_REF and FULL_SHA with one reviewed row above:
git branch -- recovered-work FULL_SHA
git update-ref --no-deref -d RECOVERY_REF FULL_SHA
```

Removing a recovery ref may make its history eligible for garbage collection.
Do not edit recovery refs or concurrently check out candidate branches while
pruning. An atomic lock directory in the common Git directory serializes helper
runs, including their capacity checks. A crashed run leaves the lock in place
and later runs fail closed. After confirming no prune helper is running, remove
only that empty directory and retry:

```bash
rmdir "$(git rev-parse --git-common-dir)/ops-toolbox-prune-gone.lock"
```

Exit codes: `0` success (including no eligible branches), `1` recovery, lock,
reachability, worktree inspection, or deletion failed, `2` not a repository,
`3` invalid usage, `4` remote not found.

---

## `git_stale_branches.sh`

Read-only. Lists branches whose last commit is older than `--days` (default 90), oldest first, with the last author and a label saying what can act on each one:

| Label | Meaning | What removes it |
| --- | --- | --- |
| `gone` | The upstream was deleted on the remote. | `git_prune_gone.sh` |
| `merged` | Reachable from `HEAD`. | `git_cleanup_merged.sh` |
| `unmerged` | Neither — squash-merged and forgotten, or abandoned. | Read it first: `git log --oneline main..<branch>` |

```bash
./git/git_stale_branches.sh
./git/git_stale_branches.sh --days 30
./git/git_stale_branches.sh --days 30 --state unmerged
./git/git_stale_branches.sh --remote          # every remote as well
./git/git_stale_branches.sh --remote upstream # just that one
```

Age is the last commit date of the branch tip, because that is the only date Git keeps: a branch created yesterday from a year-old commit reads as a year old.

It does not fetch. Remote-tracking refs are therefore only as fresh as your last `git fetch --prune`, which the closing notes say out loud — a read-only report that quietly rewrites refs is not read-only.

**Exit code `4`** when nothing is older than the threshold, so a scheduled check can act on the code rather than parse the output.

`--state gone|merged|unmerged` applies the label as a report filter. Counts and
exit `4` describe the filtered result, which makes scheduled checks such as
"alert only on old unmerged branches" deterministic.

---

## `git_size_report.sh`

Reports Git's on-disk totals and the largest historical blobs grouped by path.
The default walks `--all`, preserving the whole-repository view. Repeat
`--ref REF` to restrict the object walk to one or more branches or tags:

```bash
./git/git_size_report.sh --fast
./git/git_size_report.sh --threshold 1048576 --top 30
./git/git_size_report.sh --ref main --ref release/v2 --threshold 1048576
```

Objects reachable from several selected refs are counted once by `git rev-list`.
A missing ref exits `4`. `--ref` and `--fast` are deliberately
incompatible because fast mode skips history entirely and would otherwise
silently ignore the scope.

---

## `git_recent_branches.sh`

Lists local branches by last commit date (newest first), with relative time and subject. With `--switch N`, checks out the *N*th line in that listing.

```bash
./git/git_recent_branches.sh
./git/git_recent_branches.sh --limit 20
./git/git_recent_branches.sh --limit 20 --names-only
./git/git_recent_branches.sh --switch 2
```

`--names-only` prints one branch per line with no header, relative date, or
subject, so shell completion and fuzzy-finder pipelines do not have to scrape
the aligned human table.

Uses a Bash 3–safe loop (no `mapfile`), so it behaves the same on macOS stock Bash and on Linux.

---

## `git_repo_root.sh`

Prints one line: the absolute path to the repository root. Handy for scripts and jumping to the repo top level.

```bash
cd "$(./git/git_repo_root.sh)"
./git/git_repo_root.sh
./git/git_repo_root.sh --git-dir
```

`--git-dir` prints Git's absolute metadata directory. Unlike appending `/.git`
to the worktree root, it works for linked worktrees and submodules where `.git`
is a pointer file.

---

## `git_diff_branch.sh`

Shows what changed on your current branch since it diverged from a base branch (default: local `main`, else `master`). Uses `merge-base(base, HEAD)..HEAD`, so you do not see unrelated commits that landed on `main` after you branched.

```bash
./git/git_diff_branch.sh --stat
./git/git_diff_branch.sh --patch --base main
./git/git_diff_branch.sh --working-tree --stat --base main
./git/git_diff_branch.sh --base origin/main --name-only
./git/git_diff_branch.sh --base origin/main --name-status --path k8s/ --path ':(glob)**/*.yaml'
./git/git_diff_branch.sh --base origin/main --path docs/ --require-changes && echo "docs changed"
```

The default remains committed branch work (`merge-base..HEAD`).
`--working-tree` compares the merge base directly with the current index and
working tree, adding staged and unstaged tracked changes. Git cannot include
untracked files in a diff until they are staged.

`--name-only` prints the changed paths one per line and `--name-status` the
status letter (`A`, `M`, `D`, `R`...) and path, tab-separated; both are the
stable forms for a script, so nothing has to scrape the diffstat. The last mode
flag given wins, as between `--stat` and `--patch`.

`--path PATHSPEC` limits every mode, `--stat` and `--patch` included, to that
pathspec, and is repeatable: a directory such as `k8s/`, a file, or git's own
pathspec forms such as `':(glob)**/*.yaml'`. Pathspecs are passed after `--`,
so none of them can be read as an option.

`--require-changes` is the CI switch for "build or deploy only if something
under this path changed": with nothing to show it prints `no changes in RANGE`
on stderr, nothing on stdout, and exits `4`. Without it an empty diff still
exits `0`, as it always has.

`--base` takes a local branch first and, failing that, a remote-tracking one,
so `--base origin/main` works in a fresh CI checkout that has no local `main`.
The inferred default is still local `main`, else `master`.

**Exit code `4`** if the base branch cannot be inferred, if `--base` is neither
a local nor a remote-tracking branch, or with `--require-changes` when nothing
changed.

---

## `git_merge_check.sh`

Will these branches still merge? Release and merge-queue work keeps asking
whether `hotfix/x` still merges into `release/1.4`, or which open branches have
rotted against `main`. The usual answer is to check out the target, run
`git merge`, read the conflict and `git merge --abort`, which needs a clean
tree and rewrites the worktree twice. This asks `git merge-tree --write-tree`
instead, which computes the real three-way merge in memory.

```bash
./git/git_merge_check.sh                              # HEAD into the default branch
./git/git_merge_check.sh --into release/1.4 hotfix/x
./git/git_merge_check.sh --all-local                  # every local branch into main
./git/git_merge_check.sh --into origin/main --porcelain feature/a feature/b
```

One line per branch:

```text
clean     feature/a
conflict  feature/b  2 file(s): src/app.c, README.md
merged    feature/c  already in main
ff        feature/d  fast-forward
error     feature/e  fatal: refusing to merge unrelated histories
```

`merged` means the branch is already contained in the base, `ff` that the base
is an ancestor of it, and `error` that git could not merge the two at all. The
base defaults to the branch `refs/remotes/origin/HEAD` points at, else `main`,
else `master`, resolved like `git_sync_default.sh`; the local branch is used
when it exists, and `origin/NAME` otherwise, so a fresh CI checkout still has
one. `--into` takes any branch or remote-tracking ref. With no branch named and
no `--all-local`, `HEAD` is checked. `--porcelain` prints
`status<TAB>branch<TAB>base<TAB>path`, one row per conflicting path, with
`path` empty for every other status. Paths with unusual bytes appear C-quoted,
the way git prints them.

It does not touch `HEAD`, the index, the working tree or any ref, so it works
with a dirty tree, in the middle of a rebase and in a bare repository. It is
honest rather than write-free: `merge-tree` stores the merge result's trees and
blobs in the object database, unreachable from any ref, where `git gc` collects
them. It needs **Git 2.38 or newer** and checks before the first branch: an
older git exits `2` rather than reporting every branch as an error.

Exit codes: `0` every branch is clean, merged or a fast-forward; `1` at least
one conflict or error; `2` not a Git repository or Git older than 2.38; `3`
usage; `4` the base or a branch was not found, or `HEAD` has no commits.

---

## `git_undo_last_commit.sh`

Undoes the latest commit. Default is **`--soft`**: the commit disappears but its changes stay **staged**. Use **`--mixed`** to keep files in the working tree unstaged, or **`--hard --force`** to discard those changes entirely (destructive).

```bash
./git/git_undo_last_commit.sh --dry-run
./git/git_undo_last_commit.sh
./git/git_undo_last_commit.sh --mixed
./git/git_undo_last_commit.sh --hard --force
./git/git_undo_last_commit.sh --revert
```

Use `--revert` after a commit may have been pushed: it requires a clean tree and
runs `git revert --no-edit HEAD`, adding a new inverse commit instead of moving
HEAD. It cannot be combined with reset modes or `--force`.

**Exit code `4`** when there is no parent commit (for example right after the first commit on a new repo).

---

## `git_amend_last.sh`

Runs **`git commit --amend --no-edit`**: fold staged changes into the previous commit without opening an editor. With **`--add-all`**, stages everything first (useful when you forgot files in the last commit).

```bash
./git/git_amend_last.sh --dry-run --add-all
./git/git_amend_last.sh --add-all
./git/git_amend_last.sh --message "fix(git): clearer subject"
```

`--message TEXT` replaces the subject/body and works even when no content is
staged. Combine it with `--add-all` to update both content and message in one
amend; without it the original `--no-edit` behavior remains the default.

**Exit code `4`** if nothing is staged and neither `--add-all` nor `--message`
provides something to amend.

---

## `git_hooks_install.sh`

Writes hooks into `.git/hooks` of the current repository. Each body is embedded in this script rather than copied from a directory, so a hook keeps working after the script is deleted, moved, or was never checked out beside the repository it installed into.

```bash
./git/git_hooks_install.sh install                 # pre-commit only
./git/git_hooks_install.sh install --commit-msg    # and the message hook
./git/git_hooks_install.sh install --pre-push      # and the push guard
./git/git_hooks_install.sh install --pre-push --protect main --protect release
./git/git_hooks_install.sh install --token-scan    # opt-in access-token patterns
./git/git_hooks_install.sh install --max-size 4096
./git/git_hooks_install.sh status
./git/git_hooks_install.sh uninstall
```

**`pre-commit`** (always) refuses a commit with a staged file over `--max-size` (default 1024 KB), a leftover conflict marker, or a PEM private key. Every check reads the *staged blob*, never the working tree: `git add -p` stages one hunk of a dirty file, and it is the staged content that is about to become a commit.

With **`--token-scan`**, the pre-commit hook also rejects high-confidence GitHub
classic/fine-grained and GitLab `glpat-` tokens. AWS access-key IDs are
deliberately excluded because they are identifiers, not secrets. This is
opt-in to avoid surprising existing installations and is kept intentionally
narrow: it is a last local guard, not a replacement for a full secret scanner
in CI. Reinstall without the flag to disable it.

**`commit-msg`** (only with `--commit-msg`) refuses a subject that is not a Conventional Commit — `type(optional scope): subject`, with an optional `!` for a breaking change:

```text
feat(git): add a stale branch report
fix!: stop pushing tags by default
```

Types are `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`. Messages git writes itself — merges, reverts, and `fixup!`/`squash!` — are exempt, because rejecting those breaks a rebase rather than improving a changelog. The subject is the first line that is neither blank nor a comment, so a message written under `commit.verbose` or from a template is judged on the line you wrote.

It is off by default deliberately: a message convention is a team decision, and a hook that imposes one on a repository that has not agreed to it gets bypassed on its first use and then never runs again.

**`pre-push`** (only with `--pre-push`) guards what is pushed rather than what is committed, because the expensive mistakes happen at push time. It refuses:

- **any push to a protected branch** — `main` and `master` by default; repeat `--protect NAME` to replace that set. A deletion (`git push origin :main`) and a non-fast-forward (`git push --force`) are named as such. When the old remote tip is not in this clone, the push cannot be proven to be a fast-forward and is refused as one that may not be.
- **unfinished commits** on any branch: a subject starting `fixup!`, `squash!` or `amend!`, or a subject that starts with `WIP` or `wip` as a word, that is the prefix not followed by a letter (`WIP`, `WIP: spike`, `wip tidy`, `WIP-spike`, `WIP/test`; not `WIPE` or `Wip`). Only the commits the push adds are read: those after the remote's old tip, or for a new branch those the remote does not already advertise (asked with `git ls-remote`, never taken from possibly stale remote-tracking refs). If the remote cannot be listed, the newest 200 commits of the pushed history are read instead.

Bypass one push deliberately with `git push --no-verify`, or with `GIT_ALLOW_PROTECTED_PUSH=1 git push ...` where a tool runs the push for you. It is opt-in for the same reason as `commit-msg`: whether a branch takes direct pushes is a team decision, and a repository that merges through pull requests is the one that wants it. `--protect` without `--pre-push` exits `3`, and so does a name with anything but letters, digits, `.`, `_`, `/` and `-`, because the names are written into the hook as plain words.

An existing hook this script did not write — any of the three — is backed up rather than clobbered, and only with `--force`; `uninstall` restores it. Hook versions are tracked per hook, so `status` can tell an out-of-date hook from a current one.

**Exit codes:** `1` refused to act (a foreign hook is in the way), `4` nothing to uninstall.

---

## `git_commitlint.sh`

The `commit-msg` hook above is local and `git commit --no-verify` skips it, so a
team that wants the convention still needs the check where nobody can skip it:
in CI, on the range a pull request adds. This lints every commit in a range
against the same rules, plus the ones a hook cannot see.

```bash
./git/git_commitlint.sh                               # merge-base(main, HEAD)..HEAD
./git/git_commitlint.sh --base origin/main
./git/git_commitlint.sh --range "$BASE_SHA..$HEAD_SHA"
./git/git_commitlint.sh --max-subject 50 --types feat,fix,docs
./git/git_commitlint.sh --forbid 'WIP' --forbid '^Signed-off-by:'
```

| Problem | When |
| --- | --- |
| `not-conventional` | The subject is not `type(optional scope): subject`, with an optional `!`. The pattern and the default types are the hook's: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`; `--types` replaces them with a comma-separated list of lowercase words. Subjects starting with `Merge` or `Revert` and a space are exempt, as in the hook, even on a plain commit such as a squash merge. |
| `too-long` | The subject is longer than `--max-subject` characters (default `72`). |
| `no-blank-line` | The second line of the message is not blank, so git folds the body into the subject. |
| `fixup` | A `fixup!`, `squash!` or `amend!` commit that was never squashed. The hook lets these through on purpose, mid-rebase; a merge is where they must be gone. `--allow-fixup` turns this off. |
| `forbidden` | The whole message matches a `--forbid` extended regex, ignoring case (repeatable). |

Every problem of every commit is reported, not the first one. Merge commits are
never linted. Each offending commit prints one line, short SHA, problems,
subject (cut at 60 characters), and then `N of M commit(s) have problems`; a
clean range prints `M commit(s) checked, all fine`. `--porcelain` prints
`sha<TAB>problem<TAB>subject`, one row per problem.

The range is `--range` used as given, or `merge-base(--base, HEAD)..HEAD`. With
neither, the base is local `main`, else `master`, else the branch
`refs/remotes/origin/HEAD` points at. A GitHub Actions step:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # the whole range has to be in the clone
- run: ./git/git_commitlint.sh --range "${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}"
```

A shallow clone that lacks the base exits `3` (bad range) or `4`, never a
false pass. An empty range exits `4`; a pipeline that wants an empty range to
pass can write `./git/git_commitlint.sh --range "$R" || [ $? -eq 4 ]`.

Read-only: `rev-list`, `merge-base` and `log`. `--forbid` patterns are matched
with `grep -E` against commit text and are never evaluated by the shell.

Exit codes: `0` every commit is fine, `1` problems found, `2` not a Git
repository, `3` usage, a bad range or a bad type, `4` an empty range or no base
branch could be inferred.

---

## `git_release_notes.sh`

Release notes without scrolling `git log` between two tags. The commits since
the last tag are grouped by Conventional Commit type, breaking changes first,
and printed as text or markdown ready to paste into a release, a deploy note
or a change ticket. It reads the convention `git_hooks_install.sh --commit-msg`
and `git_commitlint.sh` enforce, in the other direction.

```bash
./git/git_release_notes.sh                          # since the last v* tag
./git/git_release_notes.sh --format markdown > notes.md
./git/git_release_notes.sh --to v1.4.0              # the notes for that release
./git/git_release_notes.sh --from v1.2.0 --to v1.3.0
./git/git_release_notes.sh --match 'release-*'
./git/git_release_notes.sh --next-version           # e.g. 1.5.0
```

Sections, in order, each only when it has commits: **Breaking changes** (a `!`
after the type, or a body line starting `BREAKING CHANGE:`), **Features**
(`feat`), **Fixes** (`fix`), **Performance** (`perf`), **Documentation**
(`docs`), **Build and CI** (`build`, `ci`) and **Other** (`chore`, `refactor`,
`style`, `test`, `revert`, any other type, and every subject that is not a
Conventional Commit, so nothing is dropped silently). A scope is one or more of
`a-z A-Z 0-9 . _ / -`, the commit-msg hook's rule, so `feat(): x` is Other and
does not bump the version. Each entry is
`- scope: description (shortsha)`, or `- description (shortsha)` without a
scope. Merge commits are left out.

`--from` defaults to the nearest tag matching `--match` (default `v[0-9]*`)
reachable from `--to` (default `HEAD`). A tag on `--to` itself is the release
being described, so `--to v1.4.0` runs from the tag before it. With no matching
tag the whole history is used and a note on stderr says so. `--format markdown`
opens with `## FROM..TO`, or `## TAG (DATE)` when `--to` is a tag, and uses
`###` section headings.

`--next-version` prints only the version the commits imply after the `--from`
tag, which must be `MAJOR.MINOR.PATCH` with or without a leading `v`: major for
any breaking change, else minor for any feature, else patch. It is the plain
semver rule; a 0.x project that bumps the minor for breaking changes should
read it as a suggestion.

Read-only: it creates no tag and writes no file. A shallow clone may lack the
tag; run `git fetch --tags --unshallow` first, and a missing ref exits `3`
rather than printing an empty success.

Exit codes: `0` success, `2` not a Git repository, `3` usage, a bad ref, a
`--from` that is not an ancestor of `--to` (unrelated or rewritten history), or
a `--from` that is not a tag, or a tag that is not semver, for
`--next-version`, `4` no commits between `FROM` and `TO`.

---

## `clone-repos.sh`

Clones every repository listed in a text file, one URL or local path per
line, into a parent directory. A destination that is already a git checkout
is skipped, one that holds anything else is reported and left alone, and a
failure on one line never stops the rest. The point is a workstation set up
from a list rather than from memory: keep the list in your dotfiles, run the
script once on a new machine, run it again whenever the list grows.

```bash
./git/clone-repos.sh --dry-run repos.txt              # preview; writes nothing
./git/clone-repos.sh --dir ~/src repos.txt            # clone into ~/src
./git/clone-repos.sh -n -d ~/src git/repos.txt.example  # the shipped example
./git/clone-repos.sh --update --dir ~/src repos.txt   # and bring existing checkouts up to date
./git/clone-repos.sh -u -n --dir ~/src repos.txt      # preview the fetches and fast-forwards
```

The list format, shown in `repos.txt.example`: one URL per line; an
optional second field is the destination, relative to `--dir` unless it is
absolute, and without it the repository name from the URL is used; blank
lines and lines starting with `#` are ignored. `--verbose` prints each line
as it is read and each decision made. The default list file is `repos.txt`
in the current directory.

Exit `0` when every entry was cloned or already present; `1` when at least
one entry failed, with the line number in the message; `2` when the list is
unreadable, git is missing or `--dir` is unusable; `3` on a bad flag; `4`
when the list has no entries. A clone that fails part-way is reported with
its path, and the directory is left for you to inspect rather than removed.

**`--update`** (`-u`) is the mirror of a second run: instead of
`already cloned`, each checkout that is already there is fetched and
fast-forwarded on the branch it has checked out, so the whole list is brought
up to date without a loop of `git pull`. A checkout is **held** — reported
with a `held (...)` line and left exactly as it is — when its `HEAD` is
detached, its branch has no upstream (or its upstream branch was deleted
on the remote), tracked files are modified (or `git status`
cannot be read, for example with a corrupt index), or the branch
has diverged from its upstream. It never switches branches, stashes, or makes a
merge commit; a fast-forward that cannot apply (an untracked file in the way)
is reported as failed. A checkout that is ahead but not behind is reported as
up to date with its unpushed count.

| Line | Meaning |
| --- | --- |
| `updated (+N commit(s)): PATH` | Fetched and fast-forwarded. |
| `up to date: PATH` | Nothing new upstream (`(N unpushed commit(s))` when it is ahead). |
| `held (detached HEAD)`, `held (no upstream)`, `held (upstream gone)`, `held (uncommitted changes)`, `held (cannot read git status)`, `held (diverged, +A/-B)` | Left alone; reconcile it yourself. `upstream gone` means the branch's upstream no longer exists on the remote (its remote-tracking ref was pruned, or was already gone before the run). |
| `fetch failed: PATH`, `fast-forward failed: PATH` | Counted as failed. |

The summary becomes `cloned N, updated U, up to date C, held H, failed F`.
Held checkouts do not fail the run; a failed fetch or fast-forward exits `1`
like a failed clone. Under `--dry-run` the local checks still run and print
their `held` lines, and every other checkout prints
`dry-run: would run: git -C PATH fetch --prune --quiet` and
`dry-run: would run: git -C PATH merge --ff-only --quiet @{upstream}`; nothing is
fetched, so whether it is behind cannot be known yet. `--update` writes into
the existing checkouts, so preview it first.

Once they are cloned, `./git/git_fleet_doctor.py ~/src` checks them all at
once.

---

## `git_bundle_backup.sh`

One file that holds every ref of the repository, proven restorable. Run it
before a risky operation — a history rewrite, a host migration, deleting a
clone that holds the only copy of some branches — or on a schedule for a
repository with no remote. `git bundle create --all` does the core of it; this
adds the four steps people forget: the timestamp, the verify, the atomic write
and the cleanup of old bundles.

```bash
./git/git_bundle_backup.sh --dry-run                     # what it would run
./git/git_bundle_backup.sh                               # ~/git-bundles/<repo>-<stamp>.bundle
./git/git_bundle_backup.sh --out /mnt/backup --name api
./git/git_bundle_backup.sh --ref main --ref release/1.4  # only these refs
./git/git_bundle_backup.sh --keep 7                      # list bundles beyond the newest 7
./git/git_bundle_backup.sh --keep 7 --yes                # and delete them
```

The file is `OUT/NAME-YYYYMMDDTHHMMSSZ.bundle`, with the stamp in UTC from
`date -u`, so names sort in time order on any system. `--out` defaults to
`~/git-bundles`; `--name` defaults to the repository directory's name and takes
letters, digits, `.`, `_` and `-` only. Without `--ref` the bundle holds every
ref: branches, tags, remote-tracking refs, the newest stash entry and the
recovery refs `git_prune_gone.sh` keeps. `--ref` (repeatable) bundles only the
named refs, each checked to exist first.

The bundle is written to a hidden `.NAME-<stamp>.bundle.partial`, checked with
`git bundle verify`, and only then renamed into place; within one directory the
rename is atomic, so the final name only ever holds a verified bundle. A
failure removes the partial file and exits `1`, and an existing file with the
same name is never overwritten. The output prints the size, the number of refs
and the restore commands:

```bash
git bundle verify ~/git-bundles/api-20261021T120000Z.bundle
git clone ~/git-bundles/api-20261021T120000Z.bundle api-restored
```

A clone of a bundle has its branches as `origin/<branch>` remote-tracking refs,
as a clone of any remote does; `git switch <branch>` makes a local one.

**Retention.** `--keep N` (1 or more) considers only files in `OUT` named
`NAME-<8 digits>T<6 digits>Z.bundle` — the glob and then the exact shape again
— sorted by name, and keeps the newest `N`, the one just written included.
Without `--yes` it lists the rest as `would prune (pass --yes to delete): FILE`
and deletes nothing; with `--yes` it deletes them and prints `pruned: FILE`.
Another repository's bundles and any other file in `OUT` are never listed.
`--yes` without `--keep` exits `3`.

`--dry-run` prints the `mkdir`, `git bundle create`, `git bundle verify`, `mv`
and `rm` it would run, creates nothing — not even `OUT` — and closes with
`dry-run complete; no changes written`.

It never changes the repository: `bundle create`, `verify` and `list-heads`
only read it. A bundle contains the full history it covers, including any
secret that was ever committed, so keep it as carefully as the repository
itself. Nothing is uploaded anywhere.

Exit codes: `0` success; `1` the bundle could not be created or verified, or
the file already exists; `2` not a Git repository, or `OUT` exists and is not a
directory or cannot be created; `3` usage; `4` nothing to back up (no refs yet)
or a `--ref` not found.

---

## `git_ssh_doctor.py`

Answers the question `Permission denied (publickey)` refuses to: *which* of the things involved actually went wrong.

```bash
./git/git_ssh_doctor.py                  # check this repo's SSH remotes
./git/git_ssh_doctor.py --host github.com
./git/git_ssh_doctor.py --test-auth      # connect: try ssh, then every key, report which works
./git/git_ssh_doctor.py --quiet --host github.com
./git/git_ssh_doctor.py --require-known-host --host github.com   # CI preflight
```

The effective configuration comes from **`ssh -G`** — OpenSSH resolving its own config, rather than a second implementation that can disagree with it. On top of that it reports what `ssh -G` cannot explain:

- **`Include` globs that match only directories.** ssh does not descend into a directory and prints no error, so every config file inside is silently ignored. This is why a `Host` block you wrote may never be read.
- **`Include` globs that match nothing.**
- **Keys with permissions ssh will refuse** (group- or world-readable).
- **An empty agent**, and which configured identity files do not exist on disk.
- **Whether the host key is already trusted.** The number-one "works on my
  laptop, fails in the pipeline" error is `Host key verification failed`: a
  headless run cannot answer the yes/no prompt. Before any authentication
  attempt, the doctor asks `ssh-keygen -F` whether the key for the host and
  port ssh will dial is in the `UserKnownHostsFile` and `GlobalKnownHostsFile`
  that `ssh -G` reports, honouring a non-22 port (`[host]:2222`; an explicit
  port in an `ssh://` remote URL is the one used for this check and the
  probe), a `HostKeyAlias` and hashed entries. Only the file name is printed,
  never the entry. An unknown key is a warning with the `ssh-keyscan` and
  `ssh-keygen -lf` steps that pin it after checking the fingerprint against
  the one the provider publishes; `StrictHostKeyChecking no` is a warning of
  its own. With `--require-known-host` an unknown key fails the host instead,
  also where `StrictHostKeyChecking accept-new` or `no` would trust it on
  first use, and authentication is not attempted, since it would record the
  key. Without `ssh-keygen` the requirement fails closed (`cannot check:
  ssh-keygen not found`). An effective `KnownHostsCommand` is reported as
  `host key source: KnownHostsCommand (not checked)` and never run, so an
  absent file entry does not fail the requirement. With the requirement set
  every authentication attempt runs with `StrictHostKeyChecking=yes` (never
  `accept-new`), `UpdateHostKeys=no` and `CheckHostIP=no`, so none of a key a
  `KnownHostsCommand` does not supply, an extra key for a known host or an IP
  address entry for a known hostname is written to known_hosts. A *changed*
  host key can only be seen by connecting; `git_remote_doctor.py --probe`
  names that one.

**Offline by default.** Without `--test-auth` the doctor never opens a connection: it reports the effective configuration, the keys, the agent and the known_hosts state, then says authentication was not attempted. A host with no existing key and an empty agent still fails.

With **`--test-auth`** it authenticates the way git would, as the first user that applies: a `-l` or `-o User=` in the effective ssh command (the first one wins, as in ssh, and the user is the one `ssh -G` reports for those options), then the user from the remote URL such as `ssh://deploy@host` or `deploy@host:path` or from `--host deploy@host`, then a `User` that ssh config sets for the host, then `git`. Where `ssh -G` supplies the user from ssh config, one equal to the local account counts as not configured, because `ssh -G` always reports a user. If that authentication fails, it tries each discovered private key against the host and prints the `Host` block or `ssh-add` command that fixes the failure. Authentication attempts use `StrictHostKeyChecking=accept-new`, so they record a host key that was not there yet; the known_hosts check above runs first for that reason. With `--require-known-host` they instead use `StrictHostKeyChecking=yes`, `UpdateHostKeys=no` and `CheckHostIP=no` and write nothing.

**`GIT_SSH_COMMAND` and `core.sshCommand`.** For a repository's remotes the doctor follows git's precedence (`GIT_SSH_COMMAND`, then the repository-effective `core.sshCommand`, then `GIT_SSH`). When the command is `ssh` it keeps the `-i`, `-F`, `-p`, `-o` and `-l` options (and plain flags such as `-4`) and applies them to `ssh -G` and to the `--test-auth` attempt; the host key policy the doctor sets is not loosened by a `-o` in the command. Any other program, or an option it cannot interpret, is reported as `custom SSH command, not inspected` rather than guessed at, and the run then exits `1` (a recorded failure under `--require-known-host`) because nothing was verified. `--host` names a host directly, so it ignores these.

Read-only throughout: it never edits a config file, loads anything into the agent, or writes a key. Requires `python3` (any 3.9+; the macOS system interpreter is fine) and no third-party packages.

**Exit code `1`** if any checked host has no usable key or (with `--test-auth`) fails to authenticate, or with `--require-known-host` has a host key that is not in known_hosts, or when the repository's `GIT_SSH_COMMAND`, `core.sshCommand` or `GIT_SSH` is a custom (non-`ssh`) command, or an `ssh` command with options the doctor cannot read (for example `-J`), that was not inspected.

`--quiet` suppresses the report but preserves the verdict exit code. It does
not imply `--test-auth`, and no authentication happens without it, so a quiet
CI probe makes no connection unless that test was explicitly requested too. `--json` prints the same report as
one JSON object (see [Exit codes](#exit-codes-conventions)); it does not imply
`--test-auth` either.

---

## `git_signing_doctor.py`

Diagnoses effective signing configuration and the selected OpenPGP, SSH, or
x509 backend. `--test-sign` remains opt-in because it asks the configured
backend to produce one real signature in a temporary directory.

```bash
./git/git_signing_doctor.py
./git/git_signing_doctor.py --test-sign
./git/git_signing_doctor.py --quiet
./git/git_signing_doctor.py --verify-recent 50   # git's verdict on your last 50 commits
```

**Signing key.** `gpg.format` decides how `user.signingkey` is read. With
`openpgp` (or unset) any string is a valid GnuPG selector: a key id, a
fingerprint, a `<fingerprint>!` forced subkey, an email address or a user-id
fragment, so only a literal SSH public key (`ssh-ed25519 AAAA...`) is
flagged there. With `ssh` the value is a key path or a `key::` literal, and
a GPG key id is the mismatch that gets reported.

**`--verify-recent N`** answers the question people actually ask: why do my
recent commits show Unverified? It reads git's own verdict (`%G?`) for the
last `N` commits and prints one line of counts (`last 50 commits (yours): 47
good, 2 unsigned, 1 expired key`), then names every commit with a bad
signature, a revoked or expired key or signature, or one git cannot check
(missing public key, no `gpg.ssh.allowedSignersFile`, no gpg or ssh-keygen).
Unsigned commits fail only when `commit.gpgsign` is on. A good signature
whose signer address differs from the committer address is a warning,
because that mismatch is the usual reason a forge shows Unverified. Only your
own commits (author email equal to `user.email`) are judged unless you pass
`--all-authors`. `N` above 5000 is capped. Verification is local: git runs
gpg or ssh-keygen against public keys, nothing is written, and nothing is
fetched unless your `gpg.conf` turns on `auto-key-retrieve`.

`--quiet` prints nothing and preserves exit `0`/`1`, making the diagnostic safe
to use as a preflight check without parsing colored text. It does not turn on
`--test-sign`. `--json` keeps the findings as well as the exit code, one JSON
object per run.

---

## `git_remote_doctor.py`

The third read-only diagnostic, and the layer the other two step over: the URL git actually dials, and how it finds a password when that URL is HTTP.

```bash
./git/git_remote_doctor.py                 # this repository's remotes
./git/git_remote_doctor.py --remote origin
./git/git_remote_doctor.py --url https://github.com/owner/repo.git
./git/git_remote_doctor.py --quiet --remote origin
./git/git_remote_doctor.py --probe         # also try one ls-remote per remote
```

Three things decide both, and none of them is visible in `git remote -v`:

- **The URL.** A fetch URL over ssh with a push URL over https is why a pull is silent and a push prompts. `git://` is unauthenticated and read-only, so a push over it can never work. And in scp-like syntax the part after the colon is a *path*, not a port — `git@host:2222/owner/repo.git` asks for a repository called `2222/owner/repo.git`, and the error says it does not exist, which is true.
- **`insteadOf` rewrites.** `git remote -v` prints what is in the config file, not what git dials. A `url.<base>.insteadOf` can send every fetch to a mirror, and `pushInsteadOf` can send pushes somewhere else again with no `remote.pushurl` set anywhere. Longest match wins, and git applies one rewrite rather than a chain — a rewrite whose result matches another pattern looks like a chain and behaves like a dead end, so it is reported.
- **Credential helpers.** `credential.helper` is multi-valued and *accumulates* across scopes, unlike almost every other key, and an empty value discards everything configured before it — the documented way to ignore a system-wide helper, and the undocumented way to lose your keychain by pasting a config snippet. Helpers are resolved against git's exec path as well as `PATH`, because `git-credential-store` lives in `/usr/lib/git-core` and reporting it missing would be a false alarm on almost every machine. A URL-scoped `credential.<url>.helper` counts toward every HTTP remote under its `<url>` (scheme, host, port, user and path prefix, as git matches them), so a helper configured for one host only is not reported as missing, while an HTTP remote that matches no helper at all is.

Anything it prints is redacted first: `https://x-access-token:TOKEN@github.com/` is a normal thing to find in a rewrite base, and a diagnostic whose output gets pasted into an issue must not be what leaks it.

**`--probe`** answers the question the static report cannot: does a fetch
actually work from here, with the credentials this machine has? It runs one
`git ls-remote --heads` per remote (or per `--remote`) and per `--url`, and
when one fails it names the cause from git's and ssh's own message — `dns`,
`network`, `timeout`, `ssh-auth`, `hostkey-unknown`, `hostkey-changed`,
`http-auth`, `not-found`, `tls` or `proxy` — with the next command to run or
the sibling doctor to ask (`git_ssh_doctor.py --host HOST` for a refused key).
It is a CI preflight as much as a diagnosis. Nothing can prompt: stdin is
`/dev/null`, terminal prompts and askpass are off and ssh gets no terminal, so
a key that needs a typed passphrase is reported as `ssh-auth` unless the agent
holds it. The remote is dialled exactly as `git fetch` would dial it, with
`insteadOf` and `core.sshCommand` applied, and git's error lines are redacted
before they are printed. Each probe stops after `--probe-timeout` seconds
(default 20). Only the fetch side is tested; `git push --dry-run <remote>`
exercises the push side. Opt-in because it contacts the remote, which can
count against rate limits or trip an IP allow-list; `--quiet` does not imply
it.

**Exit codes:** `1` problems found (with `--probe`, each unreachable remote is one), `2` `git config` unavailable, `3` bad usage (`--probe-timeout` not a positive whole number), `4` no remotes here and no `--url` given (nothing is probed).

`--quiet` suppresses all diagnostic text while keeping those exit codes. URL
redaction is still applied internally before any report is produced; quiet
mode never exposes embedded credentials. `--json` records each line after that
redaction, so a token in a URL or a password in a shell credential helper is
no more visible in the JSON than in the text.

---

## `git_ignore_doctor.py`

The fourth read-only diagnostic. `git check-ignore -v` answers one question — which rule matched — and says nothing about why the rule you wrote is not the one in the answer.

```bash
./git/git_ignore_doctor.py                       # tracked files an ignore rule claims
./git/git_ignore_doctor.py .env
./git/git_ignore_doctor.py build/keep/note.txt
./git/git_ignore_doctor.py --quiet .env
```

Run with no path it does the sweep worth doing on any repository you inherited: every **tracked file that matches an ignore rule**. Ignore rules apply to untracked paths only, so a `.env` committed once before the rule existed keeps turning up in every diff, and `git check-ignore` agrees with your despair — it skips tracked files by default and reports no match at all. The script asks twice, with the index and with `--no-index`, and the difference is the diagnosis.

Given a path it explains that path:

- **The file is tracked**, so the rule that should ignore it is inert. It names the rule that would have matched and prints the `git rm --cached` that makes it live.
- **A negation under an excluded directory is dead.** Git does not descend into an excluded directory, so `!build/keep/note.txt` beneath `build/` is never reached. The repair is not one line: `build/*` alone still leaves the file ignored, because git skips `build/keep` on the way down. The script prints the whole ladder — `build/*`, `!build/keep/`, `!build/keep/note.txt` — anchored to the ignore file that holds the exclusion.
- **Which ignore file is in effect.** Every `.gitignore` on the way down to the path, `.git/info/exclude`, and whatever `core.excludesFile` points at, with the config file that set it. A `core.excludesFile` naming a path that does not exist is reported: git reads no global ignore file at all and never mentions it.
- **What the pattern actually means.** A slash inside a pattern anchors it to the directory of the file it is written in; a trailing space is dropped before matching; a trailing slash restricts it to directories.

A negation is a match like any other to `check-ignore`, so a path whose deciding rule is a `!` is reported as *re-included*, not as ignored.

Read-only: it never edits an ignore file, the index, or config. Requires `python3` (any 3.9+; the macOS system interpreter is fine) and no third-party packages.

**Exit codes:** `1` problems found, `2` not inside a Git repository, `3` a path outside the repository, `4` n/a: a bare
repository has no work tree to check.

A git that cannot answer is a problem, not a clean result. `check-ignore` exits `1` when nothing matched, which is an answer; anything else is reported with git's own message and exits `1`, because an empty result and "no rule matches this path" are the same value and a diagnostic must not confuse them. The no-argument scan raises its timeout with the size of the repository for the same reason — the call most likely to expire is the one whose empty result would read as an all-clear.

`--quiet` suppresses the report and preserves the verdict exit code. `--json`
prints it as one JSON object instead; the claimed paths are `detail` events.

---

## `git_health_doctor.py`

For the incidents that arrive as "`index.lock` exists", "git got slow" or
"the disk keeps filling up", on a laptop clone or a build agent's cache. It
looks at the repository itself rather than at what it connects to.

```bash
./git/git_health_doctor.py                  # this repository
./git/git_health_doctor.py --lock-age 30    # call a lock stale after 30 minutes
./git/git_health_doctor.py --fsck           # also check object connectivity
./git/git_health_doctor.py --quiet          # verdict through the exit code only
```

- **Locks.** `rm .git/index.lock` is the usual advice and the wrong one while
  a git process still holds the lock. A `*.lock` in the git directory (or
  under `refs/`) is called stale only when it is older than `--lock-age`
  minutes (default 10) **and** no `git` process is running in this
  repository or one of its worktrees; the `rm` is printed, never run. On
  Linux the working directory of each `git` process (and its `GIT_DIR`, where
  readable, and the `--git-dir` and `--work-tree` options on its command
  line) says which repository it is in (the live working directory already
  reflects any `-C`), so an unrelated git elsewhere on the machine does not
  hide a stale lock. Where only `ps` can be read, or a
  process cannot be placed, the verdict drops to a warning that says a git
  process is running somewhere and cannot be tied to the lock; if neither
  `ps` nor `/proc` can be read it drops to a warning instead of guessing.
- **A failed automatic gc.** When `git gc --auto` fails it leaves `gc.log`
  behind, and while that file is there automatic gc does not run again until
  it is older than `gc.logExpiry` (a day by default; `N.days`, `N.weeks`,
  `N.hours`, `now` and `never` are understood, anything else is treated as
  never), so loose objects pile up with nothing said after the first
  warning. A log older than that is noted, not failed. The doctor quotes the
  first lines of the log. `gc.auto=0`
  (automatic gc disabled) is reported as a warning.
- **Objects.** Loose objects above `gc.auto` (6700 by default), packs above
  `gc.autoPackLimit` (50), and garbage an interrupted gc or fetch left in
  `objects/pack`, from `git count-objects -v`. A repository over 500 MiB
  packed is pointed at `git_size_report.sh`.
- **Maintenance.** Above 100 MiB packed, whether the repository is registered
  for `git maintenance start` and has a commit-graph; `maintenance.auto=false`
  is reported because it stops git tidying up after commands.
- **Clone shape.** Shallow and partial (promisor) clones, which change what
  `git log` and `git blame` can see.

`--fsck` adds `git fsck --connectivity-only`, opt-in because it reads every
object; it writes nothing and stops after ten minutes. Linked worktrees,
submodules and bare mirrors work: every path is asked of git rather than
assumed to be `.git/`.

Read-only: it stats files, reads at most three lines of `gc.log`, and never
removes a lock or runs gc, prune or repack; it prints those commands with the
condition that makes each one safe.

**Exit codes:** `0` no fail-level finding, `1` a stale lock, a `gc.log`, an
fsck failure or a git command that could not answer, `2` not inside a Git
repository, `3` bad usage (`--lock-age` not a positive whole number). Warnings
never change the exit code. `--quiet` prints nothing and keeps the code;
`--json` prints the report as one JSON object.

---

## `git_secrets_doctor.py`

`git_hooks_install.sh --token-scan` guards the next commit and
`git_ignore_doctor.py` finds tracked files an ignore rule claims. This answers
the question an inherited repository raises: is anything in here that should
never have been committed, and was something committed once and then deleted?

```bash
./git/git_secrets_doctor.py                        # names and content at HEAD
./git/git_secrets_doctor.py --history              # also every path ever added
./git/git_secrets_doctor.py --allow 'tests/fixtures/*'
./git/git_secrets_doctor.py --no-content --quiet   # names only, verdict only
```

- **Tracked names.** `.env` (and `.env.production`), `id_rsa`/`id_ed25519`,
  `*.pem`, `*.key`, `*.p12`, `terraform.tfstate`, `.git-credentials`,
  `.netrc`, `.aws/credentials`, `.docker/config.json`, kubeconfig files and
  `.htpasswd` fail; `.npmrc`, `.pypirc`, `terraform.tfvars`,
  `credentials.json`, `service-account*.json` and `secrets.yml` warn, because
  they often but not always carry a secret. A name ending in `.example`,
  `.sample`, `.template`, `.dist`, `.tpl` or `.tmpl` is a placeholder and
  passes, so `.env.example` is fine.
  Names are read from HEAD and from the index, so a file taken out with
  `git rm --cached` is still reported until that removal is committed.
- **Content at HEAD.** Private key blocks and GitHub, GitLab, Slack and Stripe
  live tokens fail; an AWS access key id warns, since the id alone is not the
  secret. The search is `git grep -l`, which returns file names only, so a
  matched secret never reaches this report, a log, the JSON or an issue
  someone pastes it into. `--no-content` skips it on a huge monorepo.
- **History** (`--history`). The name rules over every path added on any ref
  in the last `--history-limit` commits (default 20000). A file that is gone
  from the tree but still in history is still in every clone, which is the
  case where deleting it did not end the exposure.

`--allow GLOB` (repeatable) leaves out a documented fixture; the glob is
matched against the repository-relative path and `*` crosses directories.

The advice stops at what is safe to print: rotate the credential first, then
`git rm --cached -- <path>` and an ignore rule (`git_ignore_doctor.py <path>`
checks it works). Removing a file does not remove it from history, and
rewriting history is a separate, deliberate decision this tool never makes.

Read-only: it opens no file in the working tree and works through
`git ls-files`, `git grep`, `git log` and `git ls-tree`, from the repository
root whatever directory it is started in.

**Exit codes:** `0` nothing at fail level, `1` a fail-level finding or a git
command that could not answer, `2` not inside a Git repository, `3` bad usage
(`--history-limit` not a positive whole number), `4` n/a: a bare repository
has no work tree, so nothing is scanned, not even `--history` (run it from a
clone). Warnings never change the exit code. `--quiet` and `--json` work as in the other doctors.

---

## `git_hooks_doctor.py`

Hooks fail silently. `git_hooks_install.sh` installs one guard and reports on
it; this diagnoses any repository's hook setup.

```bash
./git/git_hooks_doctor.py
./git/git_hooks_doctor.py --quiet
```

- **`core.hooksPath`.** Which directory hooks actually run from, and where
  the setting came from. One pointing at a directory that does not exist
  fails: git then runs no hooks at all and says nothing. A global or system
  `core.hooksPath` that shadows hooks in this repository's own `.git/hooks`
  is a warning that names them. A relative path is read against the work
  tree root for client hooks, but against `$GIT_DIR` for the hooks a push
  runs (`pre-receive`, `update`, `post-receive`, `post-update`,
  `push-to-checkout`, `proc-receive`, `reference-transaction`), as git
  does. The report names both locations and checks the exec bit and shebang
  of the receive-side hooks under `$GIT_DIR`. A push to the main
  repository's path runs them with the common git dir as `$GIT_DIR`; a push
  to a linked worktree's path runs them with that worktree's private
  `.git/worktrees/<name>` directory instead, so in a linked worktree both
  receive-side locations are named, each labelled with the push target it
  applies to. A missing `$GIT_DIR` directory is information only, since
  most work trees never receive pushes.
- **Each hook.** One without the exec bit fails (git skips it). The first
  line is checked: a carriage return at its end (a CRLF checkout, where the
  kernel looks for an interpreter called `sh` plus a carriage return) fails
  with a repair that keeps a `.bak`, as does an interpreter that is not
  there, absolute or through `env`; no shebang at all is a warning. An
  `env` shebang with more than one word after it and no `-S` (or
  `--split-string`) fails too: Linux hands everything after `env` over as
  one word, so `#!/usr/bin/env python3 -u` looks for a program called
  `python3 -u`. The repair is the same line with `-S`. A direct interpreter
  given more than one argument (`#!/usr/bin/python3 -u -B`) is a warning for
  the same reason: Linux passes the arguments as one word, so the
  interpreter sees the single option `-u -B`. Use one option, or
  `#!/usr/bin/env -S python3 -u -B`. Every repair command
  the doctor prints (`chmod +x`, the `.bak` rewrite, `mkdir -p`) quotes the
  path for the shell, so it can be pasted as it is even when the path holds
  a space.
- **Names.** `pre-commit.sh`, `precommit` or `pre_commit` never run; the
  doctor says which hook each was probably meant to be. A `.bak`,
  `.disabled` or `.orig` copy is noted as deliberately disabled.
- **Hook managers committed but not activated**, which is every fresh clone
  and every CI runner: `.pre-commit-config.yaml` without the framework
  installed (and the note that `pre-commit install` refuses while
  `core.hooksPath` is set), `.husky/` without `core.hooksPath` pointing at
  it, `.githooks/` with `core.hooksPath` unset, and a lefthook config without
  `lefthook install`.

Read-only: it reads at most the first line of each hook (and the start of an
active one, to recognise the manager that wrote it), so a secret inside a hook
is never printed, and it never chmods, rewrites line endings, edits
`core.hooksPath` or runs a hook. Locations are asked of git, so linked
worktrees, submodules and bare repositories work.

**Exit codes:** `0` no fail-level finding, `1` a fail-level finding, `2` not
inside a Git repository, `3` bad usage, `4` nothing to diagnose (only sample
hooks, no hook manager, no `core.hooksPath`). `--quiet` and `--json` work as
in the other doctors.

---

## `git_submodule_doctor.py`

Submodule breakage is the most opaque checkout failure in CI. This explains
each kind and prints the repair.

```bash
./git/git_submodule_doctor.py
./git/git_submodule_doctor.py --quiet
```

- **Mapping.** A gitlink in the index with no `.gitmodules` entry fails:
  `git submodule update` stops with "no submodule mapping found". A
  `.gitmodules` entry with no gitlink is stale and warns.
- **State**, from `git submodule status`: a submodule not initialised (a clone
  made without `--recurse-submodules`), one checked out at a different commit
  than the superproject records (the everyday `modified: lib (new commits)`
  after a pull), and a merge conflict in the pointer, which fails.
- **URLs.** A local path or `file://` URL only works on the machine that
  wrote it, and `git://` is unauthenticated and read-only; both fail.
  `http://` warns. An ssh URL is noted, because every machine that clones it
  needs a key (a CI runner needs a deploy key, or an `insteadOf` to https). A
  relative URL with no remote at all (the branch's remote, then `origin`)
  resolves against the repository's own directory, which works on this
  machine only, and warns.
- **Drift.** A URL changed in `.gitmodules` while `.git/config` still dials
  the old one, until `git submodule sync --recursive`. A relative URL
  (`../new.git`) is first resolved the way git does, against the URL of the
  branch's remote (else `origin`; with no remote, the repository's own path;
  the remote URL is read raw, before any `insteadOf`), and compared with
  `.git/config`. When it cannot be resolved the doctor says it did not
  compare, rather than reporting nothing.

Read-only: it runs `git ls-files`, `git config` reads (including the raw
`remote.<r>.url`, before any `insteadOf` rewrite) and `git submodule status`,
which neither fetches nor recurses, from the repository root whatever
directory it is started in, and never runs `git submodule update`, `sync`
or `init`. URLs are printed with any password blanked, because a
CI-written `.gitmodules` sometimes carries a token.

**Exit codes:** `0` no fail-level finding, `1` a fail-level finding or a git
command that could not answer, `2` not inside a Git repository, `3` bad
usage, `4` no submodules and no `.gitmodules`, or a bare repository (n/a: no work
tree). `--quiet` and `--json` work as
in the other doctors.

---

## `git_fleet_doctor.py`

The doctors answer one repository at a time. With forty clones (from
`clone-repos.sh`, a build agent's workspace, a mirror farm) the question is
which of them have a problem, on one screen, as a CI step or a weekly sweep.

```bash
./git/git_fleet_doctor.py ~/src                          # every repository under ~/src
./git/git_fleet_doctor.py --only ignore --only secrets ~/src
./git/git_fleet_doctor.py --details --exclude 'archive/*' ~/src /srv/mirrors
```

```text
repo  health  hooks  ignore  remote  secrets  signing  submodule
api   ok      n/a    ok      ok      FAIL     ok       n/a
cli   ok      ok     ok      ok      ok       ok       n/a
web   ok      ok     FAIL    ok      ok       ok       n/a
3 repo(s): 1 clean, 2 with findings, 0 errors
```

It finds every directory holding a `.git` entry (a directory, or a file for
a worktree or submodule) up to `--depth` levels below each root (default 3),
without descending into a repository it found, into `node_modules`, or
through a symlinked directory. `--exclude GLOB` (repeatable) skips paths
relative to the root. It then runs each `git_*_doctor.py` beside it in
`--quiet` mode in each repository, `--jobs` repositories at a time (default 4,
at most 16), each doctor bounded by `--timeout` seconds (default 60).
`--only NAME` (repeatable) picks doctors by short name. A cell reads `ok`,
`FAIL`, `n/a` (the doctor's exit `4`, nothing to check; the secrets,
submodule and ignore doctors answer it in a bare repository, which has no
work tree), `ERR` (the doctor
itself did not run: exit `2`, `3` or a crash, so a usage bug is never read
as a finding) or `TIME`. `--details` re-runs each `FAIL` or `ERR` cell
without `--quiet` and prints its report under the row.

Offline and read-only: every doctor it drives is read-only, it passes them
nothing but `--quiet` (never `--probe`, `--test-auth`, `--test-sign` or
`--fsck`), and their stdin is `/dev/null`. `git_ssh_doctor.py` is left out
unless `--only ssh` names it, because its default run attempts
authentication. Doctors are found beside the script, so one added later is
picked up with no change here; copied into `~/bin`, it needs the doctors
copied beside it (it falls back to finding them on `PATH`).

**Exit codes:** `0` every cell `ok` or `n/a`, `1` at least one `FAIL`, `2`
a doctor could not run or timed out, or no doctor was found, `3` bad usage
(no root, an unknown `--only`, `--jobs` outside 1 to 16), `4` no repository
found. `--quiet` prints nothing and keeps the code.

---

## Tests

From the **repository root** (so the repo mounts into the container as `/repo`):

```bash
./git/tests/run.sh
```

This builds a small Debian image, runs **Shellcheck** (severity error), **`bash -n`**, `--help` on each script, and integration tests for profiles, `gacp`, status, cleanup/prune filters, stale/size report scoping, recent branches, sync/restore, repo paths, branch diff, undo/revert, amend, hooks, quiet and JSON doctor verdicts, and the two portable templates. Python 3 is present only to execute the standard-library doctor/template smoke tests.

**Prerequisites:** Docker and Docker Compose v2 (`docker compose`).

---

## Quick reference (copy-paste)

All paths below assume the repo root is your current directory.

```bash
./git/gacp.sh "commit message"
./git/gacp.sh --staged-only --no-push -m "only what I staged"
./git/set_git_profile.sh --show
./git/set_git_profile.sh --local --profile work
./git/git_whoami.sh
./git/git_status_summary.sh --porcelain
./git/git_repos_status.sh --dir ~/src --strict
./git/git_unpushed.sh --tags --strict
./git/git_sync_default.sh --dry-run --restore
./git/git_cleanup_merged.sh --dry-run --base main --include 'feature/*'
./git/git_prune_gone.sh --dry-run --exclude '*keep*'
./git/git_recent_branches.sh --names-only
./git/git_stale_branches.sh --days 120 --state unmerged
./git/git_size_report.sh --ref main --threshold 1048576
cd "$(./git/git_repo_root.sh)"
./git/git_diff_branch.sh --working-tree --stat
./git/git_diff_branch.sh --base origin/main --name-only --path k8s/ --require-changes
./git/git_merge_check.sh --all-local --into main
./git/git_undo_last_commit.sh --dry-run
./git/git_undo_last_commit.sh --revert
./git/git_amend_last.sh --add-all --message "fix: update the last commit"
./git/git_hooks_install.sh install --commit-msg --token-scan
./git/git_hooks_install.sh install --pre-push --protect main
./git/git_commitlint.sh --base origin/main
./git/git_release_notes.sh --format markdown
./git/clone-repos.sh --dry-run --dir ~/src repos.txt
./git/clone-repos.sh --update --dir ~/src repos.txt
./git/git_bundle_backup.sh --keep 7 --dry-run
./git/git_remote_doctor.py --quiet
./git/git_remote_doctor.py --probe --probe-timeout 10
./git/git_ignore_doctor.py --json
./git/git_health_doctor.py --lock-age 30
./git/git_secrets_doctor.py --history
./git/git_hooks_doctor.py
./git/git_submodule_doctor.py
./git/git_fleet_doctor.py --details ~/src
source ./git/git_aliases.zsh   # or: . ./git/git_aliases.sh
```

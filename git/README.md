# Git Scripts

Small Bash helpers for everyday Git configuration, quick commits, and repository housekeeping. They are written for portability: POSIX-minded patterns where possible, and **compatible with the Bash 3.2** that ships on macOS (no `mapfile` or other Bash 4-only features in these scripts).

Writing one? These scripts use `set -euo pipefail`, the `git/` dry-run output grammar (`dry-run: would run: ...`, then `dry-run complete; no changes written`), and no log file at all. [`CONTRIBUTING.md`](../CONTRIBUTING.md) collects that with the rest of the shell rules.

## Contents

- [Requirements](#requirements)
- [Scripts overview](#scripts-overview)
- [Exit codes (conventions)](#exit-codes-conventions)
- [Aliases](#aliases)
- [`gacp.sh`](#gacpsh)
- [`set_git_profile.sh`](#set_git_profilesh)
- [`git_whoami.sh`](#git_whoamish)
- [`git_status_summary.sh`](#git_status_summarysh)
- [`git_sync_default.sh`](#git_sync_defaultsh)
- [`git_cleanup_merged.sh`](#git_cleanup_mergedsh)
- [`git_prune_gone.sh`](#git_prune_gonesh)
- [`git_stale_branches.sh`](#git_stale_branchessh)
- [`git_size_report.sh`](#git_size_reportsh)
- [`git_recent_branches.sh`](#git_recent_branchessh)
- [`git_repo_root.sh`](#git_repo_rootsh)
- [`git_diff_branch.sh`](#git_diff_branchsh)
- [`git_undo_last_commit.sh`](#git_undo_last_commitsh)
- [`git_amend_last.sh`](#git_amend_lastsh)
- [`git_hooks_install.sh`](#git_hooks_installsh)
- [`git_ssh_doctor.py`](#git_ssh_doctorpy)
- [`git_signing_doctor.py`](#git_signing_doctorpy)
- [`git_remote_doctor.py`](#git_remote_doctorpy)
- [Tests](#tests)
- [Quick reference (copy-paste)](#quick-reference-copy-paste)

## Requirements

| Requirement | Notes |
| --- | --- |
| **Bash** | 3.2 or newer (`/bin/bash` on macOS is enough). |
| **Git** | Recent Git 2.x (scripts use `git switch`, `for-each-ref` formats, etc.). |
| **zsh** | Optional; only needed if you `source git_aliases.zsh`. Bash users source `git_aliases.sh` instead. |
| **Python 3.9+** | Optional; only for the three `*_doctor.py` diagnostics. Standard library only — the macOS system interpreter is enough. |
| **Docker** | Optional; only for running the test suite (`git/tests/run.sh`). |

## Scripts overview

| File | Purpose |
| --- | --- |
| `gacp.sh` | Stage all changes, commit with a message, and push; `--staged-only` keeps unrelated work out. |
| `git_aliases.zsh` | zsh aliases for every helper here, each guarded on the script being installed. |
| `git_aliases.sh` | The same aliases for bash. Sourced, not run. |
| `set_git_profile.sh` | Set Git identity globally or per repository, save named profiles, apply them later. |
| `git_whoami.sh` | Show the effective identity and optionally enforce an expected email. |
| `git_status_summary.sh` | Compact status with optional stable `--porcelain` output. |
| `git_sync_default.sh` | Fast-forward the default branch and optionally restore the starting branch. |
| `git_cleanup_merged.sh` | Delete merged local branches, with include/exclude filters and dry-run. |
| `git_hooks_install.sh` | Install staged-content guards; token scanning and Conventional Commits are opt-in. |
| `git_prune_gone.sh` | Delete branches with deleted upstreams, with include/exclude filters. |
| `git_stale_branches.sh` | Report old branches and optionally filter by gone/merged/unmerged state. |
| `git_size_report.sh` | Report repository size across all history or selected refs. |
| `git_recent_branches.sh` | List/switch recent branches; `--names-only` is script-friendly. |
| `git_repo_root.sh` | Print the worktree root or absolute Git metadata directory. |
| `git_diff_branch.sh` | Diff committed branch work or include the current index/worktree. |
| `git_undo_last_commit.sh` | Reset local HEAD or create a history-preserving revert commit. |
| `git_amend_last.sh` | Amend content and optionally replace the last commit message. |
| `git_ssh_doctor.py` | Diagnose SSH auth; `--quiet` exposes only the verdict exit code. |
| `git_signing_doctor.py` | Diagnose signing backends; `--quiet` supports CI probes. |
| `git_remote_doctor.py` | Diagnose remote URLs/rewrites/credentials; `--quiet` supports CI probes. |
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
| | | `gsign` | `git_signing_doctor.py` |
| | | `gremote` | `git_remote_doctor.py` |

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

Fetches with `--prune`, then deletes local branches whose configured upstream
is reported as `[gone]`. This covers squash/rebase merges that are not ancestors
of the default branch. Every real deletion prints the old SHA and a restore
command; `--no-fetch` uses the refs already on disk.

```bash
./git/git_prune_gone.sh --dry-run
./git/git_prune_gone.sh --no-fetch --include 'feature/*' --exclude '*keep*'
```

Dry-run never fetches or rewrites remote-tracking refs; it previews the current
snapshot and names the fetch it would perform. Run `git fetch --prune` first
when you need a fresh preview without allowing this helper to mutate refs.

It uses the same repeatable `--include` / `--exclude` contract as
`git_cleanup_merged.sh`. Current and protected-looking branches remain guarded
after filtering; `--force` is still required to remove a protected name.

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
```

The default remains committed branch work (`merge-base..HEAD`).
`--working-tree` compares the merge base directly with the current index and
working tree, adding staged and unstaged tracked changes. Git cannot include
untracked files in a diff until they are staged.

**Exit code `4`** if the base branch cannot be inferred or the local base ref is missing.

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

An existing hook this script did not write is backed up rather than clobbered, and only with `--force`; `uninstall` restores it. Hook versions are tracked per hook, so `status` can tell an out-of-date hook from a current one.

**Exit codes:** `1` refused to act (a foreign hook is in the way), `4` nothing to uninstall.

---

## `git_ssh_doctor.py`

Answers the question `Permission denied (publickey)` refuses to: *which* of the things involved actually went wrong.

```bash
./git/git_ssh_doctor.py                  # check this repo's SSH remotes
./git/git_ssh_doctor.py --host github.com
./git/git_ssh_doctor.py --test-auth      # try every key, report which one works
./git/git_ssh_doctor.py --quiet --host github.com
```

The effective configuration comes from **`ssh -G`** — OpenSSH resolving its own config, rather than a second implementation that can disagree with it. On top of that it reports what `ssh -G` cannot explain:

- **`Include` globs that match only directories.** ssh does not descend into a directory and prints no error, so every config file inside is silently ignored. This is why a `Host` block you wrote may never be read.
- **`Include` globs that match nothing.**
- **Keys with permissions ssh will refuse** (group- or world-readable).
- **An empty agent**, and which configured identity files do not exist on disk.

With **`--test-auth`** it tries each discovered private key against the host and prints the `Host` block or `ssh-add` command that fixes the failure.

Read-only throughout: it never edits a config file, loads anything into the agent, or writes a key. Requires `python3` (any 3.9+; the macOS system interpreter is fine) and no third-party packages.

**Exit code `1`** if any checked host fails to authenticate.

`--quiet` suppresses the report but preserves the verdict exit code. It does
not imply `--test-auth`, so a quiet CI probe remains offline unless that
network test was explicitly requested too.

---

## `git_signing_doctor.py`

Diagnoses effective signing configuration and the selected OpenPGP, SSH, or
x509 backend. `--test-sign` remains opt-in because it asks the configured
backend to produce one real signature in a temporary directory.

```bash
./git/git_signing_doctor.py
./git/git_signing_doctor.py --test-sign
./git/git_signing_doctor.py --quiet
```

`--quiet` prints nothing and preserves exit `0`/`1`, making the diagnostic safe
to use as a preflight check without parsing colored text. It does not turn on
`--test-sign`.

---

## `git_remote_doctor.py`

The third read-only diagnostic, and the layer the other two step over: the URL git actually dials, and how it finds a password when that URL is HTTP.

```bash
./git/git_remote_doctor.py                 # this repository's remotes
./git/git_remote_doctor.py --remote origin
./git/git_remote_doctor.py --url https://github.com/owner/repo.git
./git/git_remote_doctor.py --quiet --remote origin
```

Three things decide both, and none of them is visible in `git remote -v`:

- **The URL.** A fetch URL over ssh with a push URL over https is why a pull is silent and a push prompts. `git://` is unauthenticated and read-only, so a push over it can never work. And in scp-like syntax the part after the colon is a *path*, not a port — `git@host:2222/owner/repo.git` asks for a repository called `2222/owner/repo.git`, and the error says it does not exist, which is true.
- **`insteadOf` rewrites.** `git remote -v` prints what is in the config file, not what git dials. A `url.<base>.insteadOf` can send every fetch to a mirror, and `pushInsteadOf` can send pushes somewhere else again with no `remote.pushurl` set anywhere. Longest match wins, and git applies one rewrite rather than a chain — a rewrite whose result matches another pattern looks like a chain and behaves like a dead end, so it is reported.
- **Credential helpers.** `credential.helper` is multi-valued and *accumulates* across scopes, unlike almost every other key, and an empty value discards everything configured before it — the documented way to ignore a system-wide helper, and the undocumented way to lose your keychain by pasting a config snippet. Helpers are resolved against git's exec path as well as `PATH`, because `git-credential-store` lives in `/usr/lib/git-core` and reporting it missing would be a false alarm on almost every machine.

Anything it prints is redacted first: `https://x-access-token:TOKEN@github.com/` is a normal thing to find in a rewrite base, and a diagnostic whose output gets pasted into an issue must not be what leaks it.

**Exit codes:** `1` problems found, `2` `git config` unavailable, `4` no remotes here and no `--url` given.

`--quiet` suppresses all diagnostic text while keeping those exit codes. URL
redaction is still applied internally before any report is produced; quiet
mode never exposes embedded credentials.

---

## Tests

From the **repository root** (so the repo mounts into the container as `/repo`):

```bash
./git/tests/run.sh
```

This builds a small Debian image, runs **Shellcheck** (severity error), **`bash -n`**, `--help` on each script, and integration tests for profiles, `gacp`, status, cleanup/prune filters, stale/size report scoping, recent branches, sync/restore, repo paths, branch diff, undo/revert, amend, hooks, quiet doctor verdicts, and the two portable templates. Python 3 is present only to execute the standard-library doctor/template smoke tests.

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
./git/git_sync_default.sh --dry-run --restore
./git/git_cleanup_merged.sh --dry-run --base main --include 'feature/*'
./git/git_prune_gone.sh --dry-run --exclude '*keep*'
./git/git_recent_branches.sh --names-only
./git/git_stale_branches.sh --days 120 --state unmerged
./git/git_size_report.sh --ref main --threshold 1048576
cd "$(./git/git_repo_root.sh)"
./git/git_diff_branch.sh --working-tree --stat
./git/git_undo_last_commit.sh --dry-run
./git/git_undo_last_commit.sh --revert
./git/git_amend_last.sh --add-all --message "fix: update the last commit"
./git/git_hooks_install.sh install --commit-msg --token-scan
./git/git_remote_doctor.py --quiet
source ./git/git_aliases.zsh   # or: . ./git/git_aliases.sh
```

# Git Scripts

Small Bash helpers for everyday Git configuration, quick commits, and repository housekeeping. They are written for portability: POSIX-minded patterns where possible, and **compatible with the Bash 3.2** that ships on macOS (no `mapfile` or other Bash 4-only features in these scripts).

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
| `gacp.sh` | Stage all changes, commit with a message, and push. |
| `git_aliases.zsh` | zsh aliases for every helper here, each guarded on the script being installed. |
| `git_aliases.sh` | The same aliases for bash. Sourced, not run. |
| `set_git_profile.sh` | Set global `user.name` / `user.email`, save named profiles, apply them later. |
| `git_whoami.sh` | Show the Git identity that applies in the current directory (effective vs global). |
| `git_status_summary.sh` | Compact status: branch, upstream, ahead/behind, changed-file counts. |
| `git_sync_default.sh` | Fetch and fast-forward the default branch (`--dry-run` supported). |
| `git_cleanup_merged.sh` | Delete local branches already merged into a base branch (`--dry-run`, `--force`). |
| `git_hooks_install.sh` | Install a pre-commit hook that blocks large files, conflict markers and private keys; `--commit-msg` adds a Conventional Commits hook. |
| `git_prune_gone.sh` | Delete local branches whose upstream was deleted on the remote — the squash-merge case `git_cleanup_merged.sh` cannot see. |
| `git_stale_branches.sh` | Read-only: branches nobody has touched in a while, with their last author and what can remove them. |
| `git_size_report.sh` | Read-only: what is making the repository big, by path across all history. |
| `git_recent_branches.sh` | List recently updated local branches, or switch to one by index. |
| `git_repo_root.sh` | Print the repository root path (`rev-parse --show-toplevel`). |
| `git_diff_branch.sh` | Diff or diffstat of your branch since diverging from `main` or `master`. |
| `git_undo_last_commit.sh` | Undo the last commit (`reset --soft` by default; `--hard` needs `--force`). |
| `git_amend_last.sh` | Amend the last commit with `--no-edit`, optionally after `git add --all`. |
| `git_ssh_doctor.py` | Diagnose `Permission denied (publickey)` and print the fix. Read-only. |
| `git_signing_doctor.py` | Diagnose commit-signing failures across the gpg, ssh and x509 backends. Read-only. |
| `git_remote_doctor.py` | Diagnose remote URLs, `insteadOf` rewrites and credential helpers. Read-only. |
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
```

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
- `--dry-run` prints what would run without writing global config or the state file.

**Exit codes**

- `4` — saved profile missing or incomplete; global identity incomplete when using `--save-current`.

---

## `git_whoami.sh`

Prints the effective `user.name` / `user.email` for the current directory (respecting repo config), and shows global values when they differ.

```bash
./git/git_whoami.sh
```

---

## `git_status_summary.sh`

One-screen summary: branch (or detached), short `HEAD`, upstream, ahead/behind counts, and counts of changed / staged / unstaged / untracked paths.

```bash
./git/git_status_summary.sh
```

---

## `git_sync_default.sh`

Requires a **clean** working tree. Fetches from `origin` (or `--remote`), checks out the target branch if needed, and fast-forwards with `git merge --ff-only`.

The default branch is resolved in order: `refs/remotes/<remote>/HEAD`, then `main`, then `master`; or pass `--branch`.

```bash
./git/git_sync_default.sh --dry-run
./git/git_sync_default.sh
```

---

## `git_cleanup_merged.sh`

Deletes **local** branches that are already merged into `--base` (default: current branch). Skips the base branch, the branch you are on, and names that look like protected branches (`main`, `master`, `develop`, …) unless you pass **`--force`**.

**Resilience**

- For each candidate branch, runs `git branch -d`. If one deletion fails, the script continues with the rest, prints a warning per failure, and exits `1` if any deletion failed (after reporting how many succeeded).

```bash
./git/git_cleanup_merged.sh --dry-run --base main
./git/git_cleanup_merged.sh --base main
```

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
./git/git_stale_branches.sh --remote          # every remote as well
./git/git_stale_branches.sh --remote upstream # just that one
```

Age is the last commit date of the branch tip, because that is the only date Git keeps: a branch created yesterday from a year-old commit reads as a year old.

It does not fetch. Remote-tracking refs are therefore only as fresh as your last `git fetch --prune`, which the closing notes say out loud — a read-only report that quietly rewrites refs is not read-only.

**Exit code `4`** when nothing is older than the threshold, so a scheduled check can act on the code rather than parse the output.

---

## `git_recent_branches.sh`

Lists local branches by last commit date (newest first), with relative time and subject. With `--switch N`, checks out the *N*th line in that listing.

```bash
./git/git_recent_branches.sh
./git/git_recent_branches.sh --limit 20
./git/git_recent_branches.sh --switch 2
```

Uses a Bash 3–safe loop (no `mapfile`), so it behaves the same on macOS stock Bash and on Linux.

---

## `git_repo_root.sh`

Prints one line: the absolute path to the repository root. Handy for scripts and jumping to the repo top level.

```bash
cd "$(./git/git_repo_root.sh)"
./git/git_repo_root.sh
```

---

## `git_diff_branch.sh`

Shows what changed on your current branch since it diverged from a base branch (default: local `main`, else `master`). Uses `merge-base(base, HEAD)..HEAD`, so you do not see unrelated commits that landed on `main` after you branched.

```bash
./git/git_diff_branch.sh --stat
./git/git_diff_branch.sh --patch --base main
```

**Exit code `4`** if the base branch cannot be inferred or the local base ref is missing.

---

## `git_undo_last_commit.sh`

Undoes the latest commit. Default is **`--soft`**: the commit disappears but its changes stay **staged**. Use **`--mixed`** to keep files in the working tree unstaged, or **`--hard --force`** to discard those changes entirely (destructive).

```bash
./git/git_undo_last_commit.sh --dry-run
./git/git_undo_last_commit.sh
./git/git_undo_last_commit.sh --mixed
./git/git_undo_last_commit.sh --hard --force
```

**Exit code `4`** when there is no parent commit (for example right after the first commit on a new repo).

---

## `git_amend_last.sh`

Runs **`git commit --amend --no-edit`**: fold staged changes into the previous commit without opening an editor. With **`--add-all`**, stages everything first (useful when you forgot files in the last commit).

```bash
./git/git_amend_last.sh --dry-run --add-all
./git/git_amend_last.sh --add-all
```

**Exit code `4`** if nothing is staged (and you did not use `--add-all`, or there were no changes to stage).

---

## `git_hooks_install.sh`

Writes hooks into `.git/hooks` of the current repository. Each body is embedded in this script rather than copied from a directory, so a hook keeps working after the script is deleted, moved, or was never checked out beside the repository it installed into.

```bash
./git/git_hooks_install.sh install                 # pre-commit only
./git/git_hooks_install.sh install --commit-msg    # and the message hook
./git/git_hooks_install.sh install --max-size 4096
./git/git_hooks_install.sh status
./git/git_hooks_install.sh uninstall
```

**`pre-commit`** (always) refuses a commit with a staged file over `--max-size` (default 1024 KB), a leftover conflict marker, or a PEM private key. Every check reads the *staged blob*, never the working tree: `git add -p` stages one hunk of a dirty file, and it is the staged content that is about to become a commit.

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
```

The effective configuration comes from **`ssh -G`** — OpenSSH resolving its own config, rather than a second implementation that can disagree with it. On top of that it reports what `ssh -G` cannot explain:

- **`Include` globs that match only directories.** ssh does not descend into a directory and prints no error, so every config file inside is silently ignored. This is why a `Host` block you wrote may never be read.
- **`Include` globs that match nothing.**
- **Keys with permissions ssh will refuse** (group- or world-readable).
- **An empty agent**, and which configured identity files do not exist on disk.

With **`--test-auth`** it tries each discovered private key against the host and prints the `Host` block or `ssh-add` command that fixes the failure.

Read-only throughout: it never edits a config file, loads anything into the agent, or writes a key. Requires `python3` (any 3.9+; the macOS system interpreter is fine) and no third-party packages.

**Exit code `1`** if any checked host fails to authenticate.

---

## `git_remote_doctor.py`

The third read-only diagnostic, and the layer the other two step over: the URL git actually dials, and how it finds a password when that URL is HTTP.

```bash
./git/git_remote_doctor.py                 # this repository's remotes
./git/git_remote_doctor.py --remote origin
./git/git_remote_doctor.py --url https://github.com/owner/repo.git
```

Three things decide both, and none of them is visible in `git remote -v`:

- **The URL.** A fetch URL over ssh with a push URL over https is why a pull is silent and a push prompts. `git://` is unauthenticated and read-only, so a push over it can never work. And in scp-like syntax the part after the colon is a *path*, not a port — `git@host:2222/owner/repo.git` asks for a repository called `2222/owner/repo.git`, and the error says it does not exist, which is true.
- **`insteadOf` rewrites.** `git remote -v` prints what is in the config file, not what git dials. A `url.<base>.insteadOf` can send every fetch to a mirror, and `pushInsteadOf` can send pushes somewhere else again with no `remote.pushurl` set anywhere. Longest match wins, and git applies one rewrite rather than a chain — a rewrite whose result matches another pattern looks like a chain and behaves like a dead end, so it is reported.
- **Credential helpers.** `credential.helper` is multi-valued and *accumulates* across scopes, unlike almost every other key, and an empty value discards everything configured before it — the documented way to ignore a system-wide helper, and the undocumented way to lose your keychain by pasting a config snippet. Helpers are resolved against git's exec path as well as `PATH`, because `git-credential-store` lives in `/usr/lib/git-core` and reporting it missing would be a false alarm on almost every machine.

Anything it prints is redacted first: `https://x-access-token:TOKEN@github.com/` is a normal thing to find in a rewrite base, and a diagnostic whose output gets pasted into an issue must not be what leaks it.

**Exit codes:** `1` problems found, `2` `git config` unavailable, `4` no remotes here and no `--url` given.

---

## Tests

From the **repository root** (so the repo mounts into the container as `/repo`):

```bash
./git/tests/run.sh
```

This builds a small Debian image, runs **Shellcheck** (severity error), **`bash -n`**, `--help` on each script, and integration tests for profiles, `gacp`, status, cleanup, recent branches, sync, repo root, branch diff, undo, and amend.

**Prerequisites:** Docker and Docker Compose v2 (`docker compose`).

---

## Quick reference (copy-paste)

All paths below assume the repo root is your current directory.

```bash
./git/gacp.sh "commit message"
./git/set_git_profile.sh --show
./git/git_whoami.sh
./git/git_status_summary.sh
./git/git_sync_default.sh --dry-run
./git/git_cleanup_merged.sh --dry-run --base main
./git/git_recent_branches.sh --switch 1
./git/git_stale_branches.sh --days 120
cd "$(./git/git_repo_root.sh)"
./git/git_diff_branch.sh --stat
./git/git_undo_last_commit.sh --dry-run
./git/git_amend_last.sh --add-all
./git/git_hooks_install.sh install --commit-msg
./git/git_remote_doctor.py
source ./git/git_aliases.zsh   # or: . ./git/git_aliases.sh
```

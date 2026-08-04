# Git Scripts

Small Bash helpers for everyday Git configuration, quick commits, and repository housekeeping. They are written for portability: POSIX-minded patterns where possible, and **compatible with the Bash 3.2** that ships on macOS (no `mapfile` or other Bash 4-only features in these scripts).

## Requirements

| Requirement | Notes |
| --- | --- |
| **Bash** | 3.2 or newer (`/bin/bash` on macOS is enough). |
| **Git** | Recent Git 2.x (scripts use `git switch`, `for-each-ref` formats, etc.). |
| **zsh** | Optional; only needed if you `source git_aliases.zsh`. |
| **Docker** | Optional; only for running the test suite (`git/tests/run.sh`). |

## Scripts overview

| File | Purpose |
| --- | --- |
| `gacp.sh` | Stage all changes, commit with a message, and push. |
| `git_aliases.zsh` | zsh aliases for Git helper scripts, including `gacp`. |
| `set_git_profile.sh` | Set global `user.name` / `user.email`, save named profiles, apply them later. |
| `git_whoami.sh` | Show the Git identity that applies in the current directory (effective vs global). |
| `git_status_summary.sh` | Compact status: branch, upstream, ahead/behind, changed-file counts. |
| `git_sync_default.sh` | Fetch and fast-forward the default branch (`--dry-run` supported). |
| `git_cleanup_merged.sh` | Delete local branches already merged into a base branch (`--dry-run`, `--force`). |
| `git_hooks_install.sh` | Install a pre-commit hook that blocks large files, conflict markers and private keys. |
| `git_prune_gone.sh` | Delete local branches whose upstream was deleted on the remote — the squash-merge case `git_cleanup_merged.sh` cannot see. |
| `git_size_report.sh` | Read-only: what is making the repository big, by path across all history. |
| `git_recent_branches.sh` | List recently updated local branches, or switch to one by index. |
| `git_repo_root.sh` | Print the repository root path (`rev-parse --show-toplevel`). |
| `git_diff_branch.sh` | Diff or diffstat of your branch since diverging from `main` or `master`. |
| `git_undo_last_commit.sh` | Undo the last commit (`reset --soft` by default; `--hard` needs `--force`). |
| `git_amend_last.sh` | Amend the last commit with `--no-edit`, optionally after `git add --all`. |
| `git_ssh_doctor.py` | Diagnose `Permission denied (publickey)` and print the fix. Read-only. |
| `git_signing_doctor.py` | Diagnose commit-signing failures across the gpg, ssh and x509 backends. Read-only. |
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

**zsh alias**

```bash
source /path/to/pretty-useful-scripts/git/git_aliases.zsh
gacp "update git scripts"
```

The alias points at the `gacp.sh` next to `git_aliases.zsh` when that file is executable.

---

## `set_git_profile.sh`

Manages **global** `user.name` and `user.email` and optional **named profiles** stored in a Git config file (not the global `~/.gitconfig`).

**State file**

```text
${XDG_CONFIG_HOME:-$HOME/.config}/pretty-useful-scripts/git-profiles.conf
```

Profiles are stored as `profile.<name>.name` and `profile.<name>.email`. Override the path with `--state-file`.

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
cd "$(./git/git_repo_root.sh)"
./git/git_diff_branch.sh --stat
./git/git_undo_last_commit.sh --dry-run
./git/git_amend_last.sh --add-all
source ./git/git_aliases.zsh
```

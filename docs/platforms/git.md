# Git

## What it covers

Git identity and repository reports, commit, sync and branch-cleanup helpers,
repository hooks, and read-only Python diagnostics (the `*_doctor.py` scripts)
for SSH, signing, remotes, ignore rules, repository health and committed
secrets.

## Requirements

- Bash 3.2+ and a recent Git 2.x.
- Python 3.9+ (standard library only) for the `*_doctor.py` tools.
- Docker with Compose v2 only for `git/tests/run.sh`.

## Main scripts

<!-- markdownlint-disable MD033 -->

| Script | Purpose | Preview |
| --- | --- | --- |
| `git_whoami.sh` | Effective Git name and email; `--expect-email` enforces one. | <span class="stage stage-report">read-only</span> |
| `git_status_summary.sh` | Branch, upstream, ahead/behind, dirty count. | <span class="stage stage-report">read-only</span> |
| `git_repo_root.sh` | Worktree root, or git dir with `--git-dir`. | <span class="stage stage-report">read-only</span> |
| `git_diff_branch.sh` | Diff from the merge base to `HEAD`. | <span class="stage stage-report">read-only</span> |
| `git_recent_branches.sh` | Recently used branches; `--switch N` checks one out. | none; `--switch` writes `HEAD` |
| `git_stale_branches.sh` | Old branches with last committer and state. | <span class="stage stage-report">read-only</span> |
| `git_size_report.sh` | Repository size and largest blobs. | <span class="stage stage-report">read-only</span> |
| `gacp.sh` | `git add --all`, commit and push. | `--dry-run` |
| `set_git_profile.sh` | Set or save Git author identity profiles. | `--dry-run` |
| `git_sync_default.sh` | Fetch and fast-forward the default branch. | `--dry-run` |
| `git_cleanup_merged.sh` | Delete local branches merged into a base. | `--dry-run` |
| `git_prune_gone.sh` | Delete local branches whose upstream is gone. | `--dry-run` |
| `git_undo_last_commit.sh` | Move `HEAD` back one commit or revert it. | `--dry-run` |
| `git_amend_last.sh` | Amend the last commit. | `--dry-run` |
| `git_hooks_install.sh` | `install`, `status`, `uninstall` pre-commit guards. | `--dry-run` |
| `clone-repos.sh` | Clone every URL in a list file into one directory. | `--dry-run` |
| `git_ssh_doctor.py` | Diagnose git-over-SSH auth. | <span class="stage stage-report">read-only</span> |
| `git_signing_doctor.py` | Diagnose commit-signing failures. | <span class="stage stage-report">read-only</span> |
| `git_remote_doctor.py` | Diagnose remote URLs and credential helpers. | <span class="stage stage-report">read-only</span> |
| `git_ignore_doctor.py` | Explain why a path is or is not ignored. | <span class="stage stage-report">read-only</span> |
| `git_health_doctor.py` | Stale locks, a blocked automatic gc, object bloat. | <span class="stage stage-report">read-only</span> |
| `git_secrets_doctor.py` | Committed credentials in names, content and history. | <span class="stage stage-report">read-only</span> |
| `git_aliases.sh`, `git_aliases.zsh` | Aliases for the helpers; sourced, not executed. | n/a |

<!-- markdownlint-enable MD033 -->

All paths are under `git/`.

## Examples

=== "Report"

    ```bash
    ./git/git_whoami.sh
    ./git/git_whoami.sh --expect-email work@example.com
    ./git/git_ssh_doctor.py --host github.com
    ./git/git_ignore_doctor.py --json
    ./git/git_hooks_install.sh status
    ```

=== "Preview"

    ```bash
    ./git/gacp.sh --dry-run -m "a message"
    ./git/git_sync_default.sh --dry-run
    ./git/git_cleanup_merged.sh --dry-run --base main
    ./git/git_prune_gone.sh --dry-run
    ./git/git_hooks_install.sh install --dry-run
    ./git/clone-repos.sh --dry-run --dir ~/src repos.txt
    ```

=== "Apply"

    ```bash
    ./git/gacp.sh "update git scripts"
    ./git/gacp.sh --no-push -m "local only"
    ./git/git_undo_last_commit.sh --revert
    ```

## Limitations and caveats

!!! danger "Branch deletion"
    `git_prune_gone.sh` and `git_cleanup_merged.sh` delete local branches.
    `git_prune_gone.sh` fetches first (unless `--no-fetch`), writes recovery
    refs, and refuses unmerged work without `--allow-unmerged`. Run
    `--dry-run` first.

!!! warning "gacp.sh stages and pushes"
    `gacp.sh` runs `git add --all` unless you pass `--staged-only`, and it
    pushes unless you pass `--no-push`.

- `set_git_profile.sh` writes global or local Git config. Preview it.
- `git_recent_branches.sh --switch` changes the checked-out branch and has no
  `--dry-run`. `git_stale_branches.sh` is report-only and has no `--dry-run`.
- The repository README calls the doctors read-only, but
  `git_signing_doctor.py --test-sign` creates one real signature and
  `git_ssh_doctor.py --test-auth` attempts SSH authentication. Those
  attempts use `StrictHostKeyChecking=accept-new` and so record an unknown
  host key; the doctor checks known_hosts before any of them, and
  `--require-known-host` turns an unknown key into a failure.
- `git_signing_doctor.py --verify-recent N` makes git verify the signatures
  of the last `N` existing commits, which runs gpg or ssh-keygen once per
  signed commit; it judges only your own commits unless `--all-authors`.
- `git_remote_doctor.py --probe` contacts each remote with one
  non-interactive `git ls-remote` and names why a failing one is
  unreachable. It never prompts, stops after `--probe-timeout` seconds, and
  tests the fetch side only.
- `git_hooks_install.sh --commit-msg` enforces Conventional Commits and is off
  by default.
- Every `*_doctor.py` takes `--json`: one JSON object with the exit code and
  each finding's level, section and message, redacted like the text report.
  The shape is versioned (`schema` 1); keys may be added, never renamed.

## Repository

- [`git/`](https://github.com/greenblacked/ops-toolbox/tree/master/git)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/git/README.md)

# Undo the last Git commit

<!-- markdownlint-disable MD033 -->

**When to use:** the last commit is wrong and you need to take it back,
choosing the safe way for a commit that is only on your machine and the
safe way for one that has already been pushed.

## Symptoms

- The last commit has the wrong files in it, or misses some.
- Its message is wrong.
- It contains a secret, build output or another file that must not be
  there.
- It was made on the wrong branch.

## Before you start

- A shell inside the repository, with `git`. Outside one, both scripts exit
  `2` with `not inside a Git repository`.
- The scripts. Work from a clone of the toolbox, or copy
  `git/git_undo_last_commit.sh`, `git/git_amend_last.sh` and
  `git/git_status_summary.sh` onto the machine; each works on its own. See [Installation and usage](../getting-started/usage.md).
- Nothing on this page pushes or force-pushes. The toolbox does not rewrite
  history that is already on a remote.
- More on the Git scripts is on the [Git page](../platforms/git.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    These commands only read the repository.

Look at what the last commit holds and what is uncommitted, then find out
whether the commit has left your machine:

```{ .bash .rpt-report title="Report" }
./git/git_status_summary.sh
git log -1 --stat
git status
git fetch
git branch -r --contains HEAD
```

`git_status_summary.sh` prints the branch, `HEAD`, the upstream, how many
commits you are ahead and behind it, and how many files are staged, unstaged
and untracked. The last four lines are plain `git`: `git fetch` refreshes
what you know about the remote, and `git branch -r --contains HEAD` prints
every remote branch that already has the commit. Any output there means it
is pushed.

### Decide

| Situation | Use |
| --- | --- |
| Not pushed; undo the commit and keep its changes staged | `git_undo_last_commit.sh` (the default, `--soft`) |
| Not pushed; keep the files but unstage them | `git_undo_last_commit.sh --mixed` |
| Not pushed; throw the commit's changes and every uncommitted tracked change away (untracked files stay) | `git_undo_last_commit.sh --hard --force` |
| Already pushed, or someone else may have it | `git_undo_last_commit.sh --revert` |
| Not pushed; only add a forgotten file or fix the message | `git_amend_last.sh`, not an undo |

`git_amend_last.sh` rewrites the last commit in place: `--add-all` (`-a`)
stages everything first, `--message TEXT` replaces the message, and
`--dry-run` shows what it would run. It exits `4` when nothing is staged
and no `--message` is given. Amending changes the commit's identity, like a
reset, so it is for commits that are not pushed.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "Nothing is changed"
    `--dry-run` checks the same preconditions as a real run, prints the one
    `git` command it would run, and stops. These two scripts print that
    line with no closing line after it.

```{ .bash .rpt-preview title="Preview" }
./git/git_undo_last_commit.sh --dry-run
./git/git_undo_last_commit.sh --mixed --dry-run
./git/git_undo_last_commit.sh --hard --force --dry-run
./git/git_undo_last_commit.sh --revert --dry-run
```

They print, in order:

```text
dry-run: would run: git reset --soft HEAD~1
dry-run: would run: git reset --mixed HEAD~1
dry-run: would run: git reset --hard HEAD~1
dry-run: would run: git revert --no-edit HEAD
```

`--hard` needs `--force` in the preview too; without it the run stops with
exit `3` before printing anything. For an amend:

```{ .bash .rpt-preview title="Preview an amend" }
./git/git_amend_last.sh --add-all --dry-run
```

## Apply

<span class="stage stage-apply">changes things</span>

Run exactly the form you previewed:

```{ .bash .rpt-apply title="Apply, not pushed" }
./git/git_undo_last_commit.sh
./git/git_undo_last_commit.sh --mixed
```

!!! apply "--hard discards uncommitted work"
    `--hard --force` resets the working tree as well. Every change to a
    tracked file that you had not committed, staged or not, is gone, together
    with the undone commit's changes. Untracked files are not touched: the
    script runs no `git clean`, so they stay in place. Without `--force` it refuses with exit `3`:
    `--hard requires --force (destructive: discards uncommitted work)`.

```{ .bash .rpt-apply title="Apply, discard everything" }
./git/git_undo_last_commit.sh --hard --force
```

For a commit that is already pushed:

```{ .bash .rpt-apply title="Apply, pushed" }
./git/git_undo_last_commit.sh --revert
```

`--revert` runs `git revert --no-edit HEAD`, which adds a new commit that
reverses the last one and leaves history as it was. It needs a clean
working tree: any change, untracked files included, stops it with exit `4`
(`working tree is not clean; commit or stash changes before --revert`).
It cannot be combined with `--soft`, `--mixed`, `--hard` or `--force`
(exit `3`). Push the new commit the usual way afterwards; it needs no force.

Plain `git` behaviour, not a script feature: `git revert` of a merge commit
needs a `-m` parent number, which this script does not pass, so on a merge
commit `git revert` refuses, changes nothing, and the script exits with
`git`'s error status.

| Exit | Meaning |
| --- | --- |
| `0` | Done. |
| `2` | Not inside a Git repository. |
| `3` | Bad arguments: an unknown flag, `--hard` without `--force`, or `--revert` with a reset mode or `--force`. |
| `4` | Nothing to undo: no parent commit (a repository with a single commit), no commit to revert, or a working tree that is not clean for `--revert`. |

## Verify

<span class="stage stage-report">read-only</span>

```{ .bash .rpt-report title="Verify" }
git log -1
git status
./git/git_status_summary.sh
```

After a reset, `git log -1` shows the commit before the one you undid, and
`git status` shows its changes staged (`--soft`), unstaged (`--mixed`), or
no tracked changes at all (`--hard`; untracked files, if any, are still
listed). After `--revert`, `git log -2` shows a new
`Revert "..."` commit on top of the old one, which is still in history.

## Roll back

A reset only moves the branch back. Plain `git` behaviour, not a script
feature: the commit you undid stays reachable from `git reflog` until the
reflog entry expires, so you can bring it back. Find its hash, then reset to
it with the same mode you undid it with:

```{ .bash .rpt-apply title="Bring an undone commit back" }
git reflog
git reset --soft SHA     # after the default --soft undo
git reset --mixed SHA    # after --mixed
```

After `--hard`, `git reset --hard SHA` brings the commit and its files back,
and discards anything you changed in the working tree since. That restores
the commit, not uncommitted work: changes that `--hard` discarded from the
working tree were never in a commit and are **not** in the reflog.

A `--revert` is undone by reverting the revert commit, which is again a new
commit. Never undo it by resetting and force-pushing shared history.

!!! warning "A pushed secret is exposed"
    If the commit you undid or reverted held a password, key or token and was
    ever pushed, treat the secret as leaked and rotate it. A revert leaves it
    in history, and removing it from history does not reach clones and caches
    that already have it. The toolbox does not rewrite pushed history.

## Related

- `git/git_amend_last.sh`: fix the last commit instead of undoing it.
- `git/git_ignore_doctor.py`: when an unwanted file keeps coming back, it
  explains why a path is ignored, or why it stubbornly is not (for example
  because it is already tracked).
- [Git platform page](../platforms/git.md)
- [`git/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/git/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 -->

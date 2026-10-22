- `git/git_merge_check.sh` forecasts whether branches still merge cleanly
  into a base without checking anything out: it runs the real three-way merge
  in memory with `git merge-tree --write-tree` and reports each branch as
  clean, conflicting (with the paths), already merged, a fast-forward, or not
  mergeable at all. It works with a dirty tree and in a bare repository, and
  `--all-local` checks every local branch for rot against `main` in one run.
  It needs Git 2.38 or newer and says so instead of guessing on older Git.

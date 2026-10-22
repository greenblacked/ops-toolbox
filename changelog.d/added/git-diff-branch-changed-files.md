- `git/git_diff_branch.sh` answers "did anything under this path change on
  this branch?" for CI and deploy pipelines. `--name-only` and
  `--name-status` print the changed paths in a form scripts can read instead
  of scraping the diffstat, `--path` limits every mode to a pathspec and is
  repeatable, and `--require-changes` exits 4 when nothing under that filter
  changed. A remote-tracking base such as `origin/main` is now accepted, so
  a fresh CI checkout with no local `main` works.

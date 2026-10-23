- The Runbooks section has a runbook for undoing the last Git commit. A
  decision table picks between the reset modes of `git_undo_last_commit.sh`
  for work that is only local, its `--revert` for work that is already
  pushed, and `git_amend_last.sh` for a commit that only needs a fix. It
  previews each form with `--dry-run`, keeps `--hard` behind its `--force`
  gate, and says what the reflog can and cannot bring back.

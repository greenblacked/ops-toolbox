- `git/git_bundle_backup.sh` writes one timestamped file holding every ref
  of a repository, proves it with `git bundle verify` before moving it into
  place, and prints the restore commands, so a backup before a history
  rewrite, a migration or deleting a clone is a single step that cannot leave
  a half-written file behind. `--keep` lists the older bundles of the same
  name beyond the newest N and deletes them only with `--yes`.

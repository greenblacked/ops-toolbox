- `dotfiles/install_dotfiles.sh` `--backups` and `--restore` now also find
  `NAME.backup-STAMP` files beside a path that no tracked file installs to
  any more, such as a config renamed or deleted after `--force` backed it
  up. They were invisible because both modes started from today's files.
  Only backups that are ours count: the path is a link into the folder or
  belongs to a unit with a tracked file; any other is reported as not ours
  and skipped, so a bare `--restore` never touches another tool's backup.

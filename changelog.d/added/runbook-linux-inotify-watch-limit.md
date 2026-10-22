- The Runbooks section has a runbook for an IDE or file watcher that hits
  the inotify limit. It raises only the inotify group of
  `sysctl_defaults.sh`, previews with `--dry-run`, keeps the backup in a
  named `--backup-file` that survives a reboot, and reverts with
  `--revert --revert-from FILE`. It warns that `--only` rewrites the whole
  drop-in and that `--revert-from` alone does not revert.

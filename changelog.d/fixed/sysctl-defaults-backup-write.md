- `linux/sysctl_defaults.sh --apply` now stops with exit `1` when the backup
  cannot be written, for instance a `--backup-file` under a directory that
  does not exist. Before, the redirection error was printed and ignored, and
  the drop-in and the live values were changed with nothing to revert to.
  The backup is written and checked first, and nothing else is touched
  unless it exists and is not empty.

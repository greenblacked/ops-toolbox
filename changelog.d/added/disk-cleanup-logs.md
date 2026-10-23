- `linux/disk_cleanup.sh --include-logs` removes rotated logs older than
  `--days` under `/var/log`, or the directories `--log-dir` names: a file
  qualifies only when its name proves it was rotated (compressed, numbered,
  `.old` or dated), so an active log, the login records and the journal are
  never touched. `--journal-max-size` caps the journal by size on top of the
  age vacuum of `--include-journal`. Both preview with `--dry-run`.

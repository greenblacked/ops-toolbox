- `linux/schedule_report.sh --failed` answers "which scheduled thing is
  broken?": it warns about each timer whose service failed on its last run,
  with the `journalctl` command to read why, and about each cron job whose
  command path no longer exists or is not executable. A `systemctl` that
  cannot answer is a skip. `--strict` exits `1` when any warning was
  printed, so the report can gate cron or CI, and `--cron-dir` points both
  cron checks at another directory. With none of the new flags the output
  and exit code are unchanged.
  A cron file that cannot be read is a warning and is never counted as
  checked.

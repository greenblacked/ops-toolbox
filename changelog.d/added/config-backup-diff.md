- `linux/config_backup.sh --diff` compares the newest archive, or a named
  one, with the live tree and lists each file as `CHANGED` (with tar's
  reason), `GONE`, `NEW` or `SKIP` (unreadable, or a subtree the new-file
  scan could not enter), then a one-line summary and
  the command that would restore one file, printed and never run. It is
  read-only, like `--list`, and needs no `--yes`. It exits `1` when anything
  differs, so the back-up, edit, compare step of a runbook can also run from
  cron as a drift check.

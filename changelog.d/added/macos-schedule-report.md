- `macos-initial-setup/schedule_report.sh` is the macOS counterpart of
  `linux/schedule_report.sh`: it lists the launchd jobs in
  `~/Library/LaunchAgents`, `/Library/LaunchAgents` and
  `/Library/LaunchDaemons` with their schedules in words (`Mon 10:30`,
  `every 3600s`, `keep-alive`), plus the user crontab and queued `at` jobs.
  It warns when a job's program no longer exists and when a plist or the
  program it runs can be written by other users, and changes nothing:
  removal stays with `stay_fresh.sh`'s explicit opt-in.
  It also warns, naming the directory, when a plist or its program sits
  under a directory that its group or every user can write without the
  sticky bit (and, for a daemon, one a non-root user owns), since the file
  could be swapped before launchd runs it.
  The check follows symlinks both ways: it walks the path as written and
  the path it resolves to, so a symlinked component or program cannot hide
  an unsafe directory.

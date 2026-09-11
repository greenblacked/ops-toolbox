- `linux/systemd/stay_fresh_timer.sh --dry-run` documented a timer it could
  never install. The help said the flag made the timer invoke `stay_fresh.sh`
  with `--dry-run`, and the code built an `ExecStart` for it, but the install
  preview returns before any unit is written, so no unit ever carried it — a
  timer that previewed maintenance forever and did none was never a thing this
  script could produce. The dead branch is gone and the help describes what the
  flag does: preview the install, write nothing.
- `linux/systemd/stay_fresh_timer.sh` checks options against the command they
  follow. Every flag was accepted after every command, so `uninstall --hour 3`
  looked like it had rescheduled something and had not, while
  `uninstall --dry-run` read as a preview and disabled the timer and deleted
  both unit files for real. A command handed an option it cannot act on now
  exits 3, the way `macos-initial-setup/launchd/stay_fresh_agent.sh` already
  did.

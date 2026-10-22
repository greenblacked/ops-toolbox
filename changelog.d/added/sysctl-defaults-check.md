- `linux/sysctl_defaults.sh --check` turns the report into a gate for
  cron, CI image builds and post-provision checks. Each managed key is
  `OK`, `DRIFT` (the live value is wrong), `UNPERSISTED` (set live, and
  no boot-time config sets it), `STALE` (the drop-in holds another
  value), `SHADOWED` (a later drop-in or `/etc/sysctl.conf` overrides
  it, and is named) or `SKIP` (unreadable). It is read-only, needs no
  root, honours `--only`, and exits `1` on anything but `OK` and `SKIP`.
  The drop-in directories follow systemd's precedence: the first
  directory holding a file name wins and a `/dev/null` symlink masks it.
  A config file it cannot read turns the keys that would be `OK` or
  `UNPERSISTED` into `SKIP` naming that file when it is read after the
  file that last sets the key, since it may override them.
  No setting was added.

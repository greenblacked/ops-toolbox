- `linux/sysctl_defaults.sh --check` turns the report into a gate for cron,
  CI image builds and post-provision checks. Each managed key is `OK`,
  `DRIFT` (the live value is wrong), `UNPERSISTED` (set live, lost at
  reboot), `STALE` (the drop-in holds another value), `SHADOWED` (a later
  drop-in or `/etc/sysctl.conf` overrides it, and is named) or `SKIP`
  (unreadable). It is read-only, needs no root, honours `--only`, and exits
  `1` on anything but `OK` and `SKIP`. No setting was added.

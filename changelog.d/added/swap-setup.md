- `linux/swap_setup.sh` reports active swap, the swap lines in fstab,
  `vm.swappiness`, RAM and a suggested size, and with `--create` or
  `--remove` adds or takes away a swapfile and its fstab line. It previews
  every step with `--dry-run`, needs `--yes` and root to change anything,
  never reuses an existing file, creates it exclusively and re-checks it
  before formatting, refuses a directory others can write to and any
  symlink in the path, rejects a `--path` that would not survive
  as an fstab field (whitespace, backslash), or touches a partition, refuses filesystems
  that cannot hold a swapfile, and edits fstab only after a timestamped
  backup and through an atomic rename, removing only the line it added.
  A symlinked `--fstab` keeps its link: the backup and the temporary file
  sit beside the target, which is what gets replaced.
  It is the missing step between the `system_doctor.sh` swap line and
  `sysctl_defaults.sh`.

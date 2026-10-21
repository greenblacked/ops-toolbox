- `linux/swap_setup.sh` reports active swap, the swap lines in fstab,
  `vm.swappiness`, RAM and a suggested size, and with `--create` or
  `--remove` adds or takes away a swapfile and its fstab line. It previews
  every step with `--dry-run`, needs `--yes` and root to change anything,
  never reuses an existing file, rejects a `--path` that would not survive
  as an fstab field (whitespace, backslash), or touches a partition, refuses filesystems
  that cannot hold a swapfile, and edits fstab only after a timestamped
  backup and through an atomic rename, removing only the line it added.
  It is the missing step between the `system_doctor.sh` swap line and
  `sysctl_defaults.sh`.

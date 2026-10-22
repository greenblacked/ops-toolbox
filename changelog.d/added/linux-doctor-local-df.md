- `linux/system_doctor.sh --skip-remote-mounts` now also runs the disk
  section's `df` local-only (`-l`), so a stale NFS, CIFS or sshfs mount
  cannot hang it; remote filesystems are then not checked for being
  full. `linux/ssh_client_doctor.sh` reads the OpenSSH boolean
  aliases `true`, `on`, `false` and `off` like `yes` and `no`, so
  `StrictHostKeyChecking false` is graded like `no`.

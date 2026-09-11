- `linux/status.sh` prints a one-screen verdict for a Linux machine
  (os, disk, packages, reboot, timer, git). `--list-sections` and `--only`
  work before any preflight, including off Linux. It writes nothing.
  `install_aliases.sh` exposes it as `linux-status`.

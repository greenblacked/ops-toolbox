- `windows/wsl/wsl_manage.ps1 doctor` checks each running distro for the
  handful of known reasons a WSL environment turns "weird" and prints the fix
  for each: a distro left on WSL1, where docker and kind cannot run, a default
  user of root after an import, no systemd, a root filesystem at 85 or 95
  percent, a clock that drifted while Windows slept (TLS and cloud API
  signatures fail), DNS that does not resolve behind a VPN, and a `PATH` full
  of `/mnt/c` entries. It only reads, gives every command inside a distro a
  15-second limit so a wedged one cannot hang the report, and starts a stopped
  distro only with `-Force`.

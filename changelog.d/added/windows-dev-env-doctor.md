- `windows/setup/dev_env_doctor.ps1` checks the Windows settings that break
  a developer toolchain while the machine itself looks healthy: long paths
  off in Windows or in git, `core.autocrlf=true` putting CRLF into shell
  scripts that then fail in Linux containers, symbolic links against
  Developer Mode, a missing credential helper, virtualization off in
  firmware, a stopped time service or (with `-CheckTime`) a skewed clock,
  `HOME` differing from `USERPROFILE`, and the current docker context. It is
  read-only and prints the fix for each warning.

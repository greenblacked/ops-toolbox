- `windows/wsl/wsl_manage.ps1` has a `wslconfig` action that audits
  `%USERPROFILE%\.wslconfig`, the usual reason the WSL2 VM eats RAM while
  Docker, k3s or a build runs. WSL starts without complaint when the file is
  missing, has no memory cap, or holds keys it silently ignores: a key in the
  wrong section, `[wsl]` where `[wsl2]` is meant, a misspelt name, single
  backslashes in a `kernel` or `swapFile` path, a true/false key such as
  `sparseVhd` set to `1` or `yes`. The audit names each with its
  line number, compares the cap with the installed RAM and processors, and
  never edits the file. It needs no WSL and no elevation, so it also runs where
  WSL is absent; `-Strict` turns a warning into exit 1, and `-Template` prints
  a commented starter file without writing one.
  It also warns on a `networkingMode` outside nat, mirrored, virtioproxy
  and none (WSL falls back to NAT; the deprecated bridged is only noted),
  and on a timeout or `maxCrashDumpCount` that is not a whole number
  (-1 is allowed for the idle timeouts and the dump count).
  A size too large for 64 bits is reported as not a size.

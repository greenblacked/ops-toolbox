- `wsl_manage.ps1 wslconfig` no longer reports `virtiofs`, `kernelDebugPort`,
  `gpuSupport`, `systemDistro`, `telemetry` and `kernelBootTimeout` as
  unrecognised `[wsl2]` keys, and accepts `networkingMode=consomme` (the
  current name of `virtioproxy`, which stays valid), so `-Strict` passes on
  them. `gpuSupport` is checked as true or false, `kernelDebugPort` and
  `kernelBootTimeout` as whole numbers of 0 or more, and `systemDistro` for
  doubled backslashes like the other path keys; `virtiofs` and `telemetry` are
  recognised without a value check.

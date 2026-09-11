- `windows/cleanup/clean_disk_c.ps1` refuses to delete without `-Yes`, and
  `windows/setup/stay_fresh.ps1` skips the winget upgrades without it. Both
  are changed defaults: a bare `.\clean_disk_c.ps1` used to empty `%TEMP%`,
  the Windows Error Reporting queue and the thumbnail cache on the spot, and a
  bare `.\stay_fresh.ps1` went straight to `winget upgrade --all
  --include-unknown --accept-package-agreements --disable-interactivity`.
  Their Bash counterparts have always asked: `linux/disk_cleanup.sh` refuses
  without `--yes` and `linux/stay_fresh.sh` skips package upgrades without it.
  The README presents the two families as counterparts, which is what made the
  asymmetry dangerous rather than merely inconsistent — the habit learned on
  the Bash side is "just run it, it will tell me what it wants", and on
  Windows that habit upgraded or deleted for real, first time, with no
  preview. `-DryRun` is unaffected and still needs no `-Yes`; on
  `stay_fresh.ps1` every step other than the upgrades still runs, so a bare
  run remains a useful report. The gate is a `-Yes` switch rather than
  `SupportsShouldProcess`, because `CONTRIBUTING.md` rules `-WhatIf`/`-Confirm`
  out for these scripts and the hand-rolled `-DryRun` already covers the
  preview half.
- `windows/setup/stay_fresh.ps1 -Only` takes a comma-separated list of steps.
  It was a single `[string]` behind a `ValidateSet`, so `-Only Winget,Wsl` —
  the obvious thing to type, and what `linux/stay_fresh.sh --only` accepts —
  died during parameter binding with a message about the valid step names,
  which reads as though the names were wrong rather than the type. The list is
  split and validated in the body instead, so both `.\stay_fresh.ps1 -Only
  Winget,Wsl` and the `pwsh -File` form of the same line are accepted; an
  unrecognised step is still rejected by name, now with exit `3`.

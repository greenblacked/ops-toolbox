- `windows/cleanup/clean_disk_c.ps1` has three more opt-in targets.
  `-IncludeCrashDumps` removes `MEMORY.DMP`, minidumps, live kernel reports,
  the WER report archive and per-user crash dumps; `-IncludeLogs` removes
  CBS, DISM and setup logs older than `-Days`; `-IncludeComponentStore` runs
  Windows' own `Dism.exe /Online /Cleanup-Image /StartComponentCleanup`,
  never with the flag that makes installed updates permanent. All three go
  through the existing `-DryRun` preview and `-Yes` gate, skip without
  elevation where they need it, and the preview never starts DISM. A
  failed DISM run makes the script exit 1 after the summary.
  `disk_usage.ps1` now points its crash-dump and log rows at them.

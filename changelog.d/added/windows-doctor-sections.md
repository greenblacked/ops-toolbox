- `windows/setup/workstation_doctor.ps1` takes `-Only` and `-ListSections`
  like `status.ps1`, and has four more sections after the original five,
  which keep their order: `hardware` (physical disk health, free space on
  the other fixed volumes, TPM and Secure Boot), `uptime` (with the reminder
  that Fast Startup means only a restart resets it), `updates` (the age of
  the newest installed update, a disabled Windows Update service) and
  `memory`. `-MaxUptimeDays` and `-MaxPatchAgeDays` set the two new
  thresholds; it is still read-only and warnings still exit `0`.

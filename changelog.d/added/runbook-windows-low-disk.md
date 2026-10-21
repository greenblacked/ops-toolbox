- The Runbooks section has a runbook for a Windows PC low on C: drive space,
  the counterpart of the Linux one. It reports with `status.ps1` and
  `workstation_doctor.ps1`, previews `clean_disk_c.ps1` with `-DryRun`,
  lists what each default target and each opt-in really removes, and warns
  that the exit code does not report a failed target, so the `CLEAN` and
  `SKIP` lines need reading.

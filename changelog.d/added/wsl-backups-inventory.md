- `windows/wsl/wsl_manage.ps1 backups` answers the question a runbook asks
  before a risky change: what WSL backups are there, are they intact, and is
  the newest one recent enough. It lists the dated exports under `-DestDir`
  newest first per distro, with size, age and whether the `.sha256` sidecar
  is present; `-Verify` hashes every tar against its sidecar and reports a
  missing, malformed or mismatched one, so a truncated export is found the
  day it happens rather than at the restore; `-MaxAgeDays` flags a distro
  whose newest backup is too old, and exits 1 for a scheduled check. It only
  reads, needs no WSL, and `verify-backup` and `restore` now share its
  checksum code with unchanged messages.

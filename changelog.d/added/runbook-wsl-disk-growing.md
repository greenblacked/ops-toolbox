- The Runbooks section has a runbook for a WSL2 virtual disk that keeps
  growing. It measures with the `df` action of `wsl_manage.ps1`, then backs
  up, verifies the backup and only then compacts or switches to sparse
  mode. It warns that `compact` shuts down every distro and that neither
  `compact` nor `sparse` has a dry run, and it covers recovery from the
  backup.

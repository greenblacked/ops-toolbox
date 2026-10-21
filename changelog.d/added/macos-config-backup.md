- `macos-initial-setup/config_backup.sh` keeps a dated, verified and rotated
  archive of a Mac's non-secret dotfiles and tool configuration (`.zshrc`,
  `.gitconfig`, `.ssh/config`, `.aws/config`, LaunchAgents and the like) in
  `~/ops-toolbox-backups`, the macOS counterpart of
  `linux/config_backup.sh`. Paths that hold credentials (any non-config,
  non-public-key file under `~/.ssh`, the git credential store,
  `~/.terraform.d/credentials.tfrc.json`, `~/.pypirc`, gcloud's
  application-default credentials, `credentials.db` and `legacy_credentials/`, a
  `~/.terraformrc` with a `credentials` block) are refused unless
  `--include-secrets` and left out of a default run, the archive is private
  to its owner (a `--dest` it creates is `0700`), a dry run
  writes nothing, a real run needs `--yes`, and rotation only removes its
  own older archives.

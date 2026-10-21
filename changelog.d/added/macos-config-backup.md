- `macos-initial-setup/config_backup.sh` keeps a dated, verified and rotated
  archive of a Mac's non-secret dotfiles and tool configuration (`.zshrc`,
  `.gitconfig`, `.ssh/config`, `.aws/config`, LaunchAgents and the like) in
  `~/ops-toolbox-backups`, the macOS counterpart of
  `linux/config_backup.sh`. Paths that hold credentials are refused unless
  `--include-secrets`, the archive is private to its owner, a dry run
  writes nothing, a real run needs `--yes`, and rotation only removes its
  own older archives.

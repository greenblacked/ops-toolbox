- `dotfiles/install_dotfiles.sh --backups` and `--restore` with
  `--only UNIT --installed-only` now accept the unit of a stray backup when
  its tool is on PATH, as `--prune` does for an orphan link, instead of
  exiting 4 with "no selected unit has its tool on PATH".
  The "not ours, skipped" notices for other backups are printed
  once, not again by the `--installed-only` check.

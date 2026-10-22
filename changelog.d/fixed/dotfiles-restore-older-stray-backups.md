- `dotfiles/install_dotfiles.sh --restore` of a deleted unit's newest backup
  no longer strands the older ones: afterwards `--backups --only UNIT` still
  lists them and `--restore --stamp` can bring one back. The installer
  remembers the path in `~/.dotfiles-restored` until the last backup is
  restored.

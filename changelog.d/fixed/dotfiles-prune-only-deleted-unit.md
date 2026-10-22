- `dotfiles/install_dotfiles.sh --prune --only UNIT` accepts the unit of a
  wholly deleted source directory when an orphan link of that unit exists,
  as bare `--prune` already finds it, instead of exiting 3.

- `dotfiles/install_dotfiles.sh --prune --only UNIT --installed-only` no
  longer exits 4 when UNIT's source directory was wholly deleted and its
  tool is on `PATH`; the unit's orphan links now count as selected.

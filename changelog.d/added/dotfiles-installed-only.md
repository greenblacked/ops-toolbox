- `dotfiles/install_dotfiles.sh --installed-only` limits any mode to the
  units whose tool is on `PATH`, so a fresh laptop or a minimal server gets
  the configs it can use without anyone knowing the unit names, `--status`
  stops reporting `MISSING` for tools that are not there, and a later run
  picks up a tool installed since. It looks commands up with `command -v`
  and runs none, composes with `--only` and groups, and exits 4 when nothing
  is left to select.

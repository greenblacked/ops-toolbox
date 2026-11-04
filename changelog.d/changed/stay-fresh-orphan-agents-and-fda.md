- `stay_fresh.sh` removes orphaned launch agents by itself on an interactive
  run instead of ending with "N orphaned launch agent(s) found": user-level
  plists always, system-level ones when sudo is already authenticated (via
  `sudo -n`, never a second prompt). Headless runs and `--reports` still only
  report, the new `--no-prune-orphan-agents` keeps them all, and a program
  under `/Volumes` is never taken as gone, since an unmounted disk looks the same.
- When `~/.Trash` is behind Full Disk Access and Finder is refused too,
  `stay_fresh.sh` opens System Settings at Privacy & Security → Full Disk
  Access and names the app to turn on, instead of only printing "Trash cleanup
  needs Full Disk Access". The permission itself still has to be granted by a
  person; macOS does not let a script do it.

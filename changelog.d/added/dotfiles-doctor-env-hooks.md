- `dotfiles/dotfiles_doctor.sh` checks the exports four configs depend on:
  `RIPGREP_CONFIG_PATH` and `GITLEAKS_CONFIG` must be set and lead to a file,
  and on macOS `XDG_CONFIG_HOME` must name the directory the configs went into
  for k9s and Homebrew to read them. Each is checked only when its tool is on
  `PATH`, and a missing one is reported with the `export` line to add instead
  of rg and gitleaks silently falling back to their defaults. `--platform`
  overrides the detection.

- `macos-initial-setup/stay_fresh.sh` upgrades Homebrew formulae but only
  reports outdated casks in routine runs. Explicit `--brew-casks` upgrades
  casks in a terminal after sudo preflight; `--brew-greedy` then includes
  self-updating casks. Headless, `--no-sudo`, and failed-preflight runs skip
  cask upgrades while preserving formula upgrades and cleanup.

- `macos-initial-setup/stay_fresh.sh` preserves open and changed user logs,
  rechecks paths through directory descriptors, and counts actual unlinks.
  Homebrew locks stay when process inspection fails; upgrade totals compare
  installed versions, and skipped cask upgrades warn during a full cycle.
  `macos-initial-setup/launchd/stay_fresh_agent.sh` now routes its full profile
  through the same age-limited cleanup and update preset as manual maintenance.

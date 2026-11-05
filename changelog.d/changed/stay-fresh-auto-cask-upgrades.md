- `stay_fresh.sh` upgrades outdated casks by itself in an interactive run with
  sudo, instead of ending with "N cask(s) remain outdated; review with brew
  outdated --cask". Casks still outdated after the bulk upgrade are retried
  one at a time, so one failing installer no longer holds the rest back, and
  casks Homebrew has disabled are skipped. Headless runs (the LaunchAgent),
  `--no-sudo` and the new `--no-brew-casks` keep listing them, and the summary
  now says why they were not upgraded.

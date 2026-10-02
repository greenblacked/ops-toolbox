- `macos-initial-setup/stay_fresh.sh` applies command timeouts to Homebrew
  identification, upgrade-capability and repository probes, and reports failed
  post-upgrade cask verification as incomplete. Docker regressions exercise
  hung probes, the full interactive cask cycle, and real open-file detection.
- The macOS user/system log guards accept lsof's normal unmatched-file status
  only with no diagnostics and a valid open-directory witness, allowing closed
  logs to be removed while open files remain protected.

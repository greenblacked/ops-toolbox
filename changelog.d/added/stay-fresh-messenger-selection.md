- `macos-initial-setup/stay_fresh.sh` adds messenger-only cleanup with optional
  app selection and per-app preview totals. Installed-app activity is rechecked
  after sizing before each deletion. Run-lock retirement is reserved before
  acquisition, including recovery from failed metadata publication.
- `macos-initial-setup/launchd/stay_fresh_agent.sh` restores the prior plist and
  loaded job when install/uninstall is interrupted by INT, TERM or HUP before
  commit, and retains recovery material if rollback fails.

- `.claude/hooks/session-start.sh --force` planted `/.dockerenv` on whatever
  machine it was run on, and nothing ever removed it. That file is the guard
  `macos-initial-setup/tests/test_stay_fresh_steps.sh` checks before it agrees
  to clear `/Library/Caches` and `/Library/Logs/DiagnosticReports`, on the
  promise that those paths belong to a disposable container — so `--force` on a
  developer's own Linux box made that promise permanently false. The marker is
  now planted only in a session that is genuinely disposable; the rest of
  `--force` is unchanged.

- `macos-initial-setup/stay_fresh.sh` accepts `--user-log-days` and
  `--npx-cache-days`, validates their bounds before cleanup, and shows the
  effective retention in its plan. Full maintenance retains its Homebrew cycle;
  changing retention does not enable skipped steps or alter system-log policy.

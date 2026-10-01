- `macos-initial-setup/stay_fresh.sh` adds `--old-only` for age-limited user logs,
  guarded rotated system logs and old idle npx entries, with storage and snapshot
  reports. It preserves bulk caches, Trash and installed software even alongside
  `--deep-clean`, rejects broader cleanup options, and names user-log candidates
  in verbose output. The README explains retention rules and System Data scope.

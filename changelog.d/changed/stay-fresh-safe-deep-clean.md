- `macos-initial-setup/stay_fresh.sh` adds a read-only `--cache-report` and
  opt-in `--deep-clean` for validated Conda archive, index, and log caches.
  Cleanup preserves saved application state, unmapped or active application
  caches, and Maven's local artifacts; stopped Docker containers now require
  `--prune-docker-containers`. Shared deletion checks reject unsafe roots,
  symlink redirection, unverified ownership, and mounted filesystems.

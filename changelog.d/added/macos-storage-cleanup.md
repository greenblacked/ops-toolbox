- `macos-initial-setup/stay_fresh.sh` extends its disk report to app group
  containers, local model stores, npm and pnpm data, and readable system cache
  and temporary-data roots. Reported sizes are not promised reclaimable space.
- Optional deep cleanup classifies old default npx cache entries with
  `macos-initial-setup/lib/npx_cache.py`, preserving recent entries, active
  processes, ambiguous configuration and unsafe paths. Downloaded models,
  virtual machines and application databases remain untouched.

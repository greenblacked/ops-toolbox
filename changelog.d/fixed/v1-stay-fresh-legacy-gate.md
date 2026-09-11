- `v1_stay_fresh.sh` no longer runs its fixed cleanup on a bare invocation.
  That path deleted Xcode Archives, emptied `brew --cache` and sent
  `killall Finder` with no dry-run and no skip flags. A bare run now
  prints the deprecation and exits 3. `--legacy-run` is the opt-in that
  keeps the old sequence for the machines that still want it.

- The npx cache tests run on macOS. `safe_root` walks the cache's ancestry with
  `lstat` and refuses a symlinked component, which is the guard that stops a
  redirected ancestor aiming the sweep somewhere else. The fixture handed it a
  `tempfile` directory, and on macOS that sits under `/var/folders` while `/var`
  is a symlink to `/private/var` — so all seven tests raised
  `Unsafe("cache ancestry is not a real directory")` before reaching anything
  they meant to check. The fixture resolves the path now; the guard is
  unchanged, because it was right. Linux has a real `/tmp`, which is why CI
  stayed green while the suite could not run on a Mac at all.

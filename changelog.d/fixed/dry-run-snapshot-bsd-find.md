- The "a dry run writes nothing" assertions passed on macOS having inspected
  nothing. `check_conventions.sh` and `k8s-toolbox/tests/test_k8s_toolbox.sh`
  snapshotted the filesystem with GNU-only `find -printf`, whose error
  `2>/dev/null` swallowed, so the before and the after call both returned the
  empty string and every subject compared `""` to `""`. Both now fall back to
  one batched `ls -ld`, as `test_changelog.sh` and the dotfiles suite already
  did. The static suite covers 32 dry-run-capable scripts, so this was the
  contract's widest blind spot.

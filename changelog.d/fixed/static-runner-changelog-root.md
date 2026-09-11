- `test-env/static/run.sh` let the host environment aim its changelog check.
  `changelog.sh` reads `CHANGELOG_ROOT` as the directory holding `CHANGELOG.md`
  and `changelog.d/`, so a developer with it exported had the static suite
  validate another checkout's fragments and report them green. The runner now
  unsets it, and the host-environment check that exists to catch exactly this
  now covers `test-env/*/run.sh`, which its subject glob had missed.

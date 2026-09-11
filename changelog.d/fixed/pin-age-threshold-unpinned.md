- `test-env/static/run.sh` did not pin `PIN_MAX_AGE_DAYS`, the threshold that
  is the whole of `check_pin_age.sh`. Exported by a developer or a runner it
  silently redefined "too old" while the check still printed `[ ok ]` for every
  file — the same shape as the `CHANGELOG_ROOT` leak beside it. The suite glob
  that should have caught it matched `test_*.sh` and `check_conventions.sh`
  only, so a file named `check_pin_age.sh` was in no subject list; it now
  matches `check_*.sh`.

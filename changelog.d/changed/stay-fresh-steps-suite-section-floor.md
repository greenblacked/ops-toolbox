- `macos-initial-setup/tests/test_stay_fresh_steps.sh` already ran under
  `set -uo pipefail` with no `set +e` sandwiches, but its `section "..."`
  heading was cosmetic — an `echo`, no counter, no floor — in the largest
  suite in the repository, the one that runs `stay_fresh.sh` for real against
  scratch fixture homes. It now uses the same counting `section`/`end_section`
  helper as `linux/tests`, `git/tests` and the macOS native suite, and fails
  a block that closes having asserted nothing. Same 754 assertions, now
  counted and floored, in 38 sections.
- Six invocations judged only by what the fixture home looked like afterward
  — a dry run that must have written no history, a guarded run that must
  have posted no failure banner, a listing that must not have probed the
  backup state, a dry run that must not have listed services, a dry run that
  must have written no log despite a pending warning, and one whose own exit
  status was captured and then overwritten by the next call before it was
  ever read — could not fail: a run that died before doing anything satisfies
  every one of those "nothing happened" assertions just as well as a correct
  run does. Each now asserts its own exit status first. Same 754 real
  assertions plus these 6 new guards.

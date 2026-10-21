- `git/git_fleet_doctor.py` runs every `git_*_doctor.py` beside it across
  the repositories under one or more roots and prints one table of verdicts
  with an overall exit code, for a workspace of many clones or a weekly CI
  sweep. It runs the doctors offline with `--quiet` (the SSH doctor, whose
  default run attempts authentication, only when named with `--only`),
  bounds the work with `--depth`, `--timeout` and `--jobs`, and with
  `--details` prints the report of each failing doctor under its row.
  Bare and mirror repositories are found too.
- In a bare or mirror repository the secrets, submodule and ignore
  doctors exit `4` (nothing to check) instead of `2`, so the fleet
  doctor shows `n/a` rather than `ERR` for them.

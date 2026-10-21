- `git/git_health_doctor.py` diagnoses a repository that is locked, slow or
  growing: a `*.lock` left by a killed command (called stale only when it is
  old and no git process is running, with the `rm` printed rather than run),
  a `gc.log` that has silently stopped automatic gc, loose objects and packs
  above the gc thresholds, garbage in `objects/pack`, missing background
  maintenance or commit-graph on a large repository, and shallow or partial
  clones. `--fsck` adds an opt-in connectivity check. It works in linked
  worktrees and bare mirrors, and exits `1` on a fail-level finding.

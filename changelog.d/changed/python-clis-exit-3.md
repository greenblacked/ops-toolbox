- Every Python CLI now exits `3` on an unrecognised flag, the same as the Bash
  and PowerShell scripts beside it. They used `argparse`'s own convention of
  exiting `2`, and `check_conventions.sh` exempted them from the contract by
  file extension rather than fighting it. That was harmless while `2` meant
  nothing in particular, and stopped being harmless once the diagnostics began
  documenting an exit `2` of their own — `git_ignore_doctor.py` spends it on
  "not inside a Git repository", `git_remote_doctor.py` on "git config
  unavailable" — so a mistyped flag returned the same number as a real finding
  and a caller could not tell a typo from a diagnosis. The exemption is gone
  rather than documented, so the suite now holds all eight to it, the two
  templates included.
- `mikrotik/core/export_config.py` returns `3`, not `2`, when `--stdout`, `--diff`
  and `--commit` are combined or when `--show-sensitive` is passed with
  `--commit`. Its own docstring spends `2` on a failed preflight — ssh missing,
  the router unreachable — and `3` on bad CLI arguments, and both of those are
  bad CLI arguments. A caller that retried on "could not reach it" was retrying
  a flag combination that could never work.

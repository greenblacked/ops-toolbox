- `windows/tests/contract.ps1` counts exit `3` from a dry run as a failure
  instead of a pass. Exit 3 is this repository's usage error, so a run that
  ends in it was rejected during argument parsing and stopped before the code
  that could write was reached — "wrote nothing" is true and meaningless, the
  same reasoning `test-env/static/check_conventions.sh` has always applied on
  the Bash side. It mattered because `Get-DryRunArgument` hardcodes the verb
  each script needs to reach its preview: `import` for `winget_bootstrap.ps1`,
  `install` for `choco_bootstrap.ps1`, `apply` for `winget_configure.ps1`.
  Renaming any of those would have exited 3 at parameter binding and the suite
  would have reported `[ ok ] ... wrote nothing (exit 3)`, retiring that
  script's dry-run coverage without saying so. The failure now names the fix:
  add an entry to `Get-DryRunArgument`. The verdict was lifted out of the loop
  into `Get-DryRunVerdict` so the suite's own judgement is covered by tests
  rather than being the one thing in the file nothing checks.

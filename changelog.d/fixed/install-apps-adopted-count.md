- `install_apps.sh` printed the wrong adopted count in its summary. The colour
  and the number were written as one word, so `%d` consumed the reset escape
  instead of the count and the line rendered `adopted:   00` — two digits for
  zero adoptions, and no colour reset after it. No suite could catch it: the
  summary sits past the `--dry-run` exit, so a dry run never reaches it, and
  `SC2183` is a warning that the error-severity ShellCheck pass lets through.
  Lint now runs a second ShellCheck pass on `SC2183` alone, across the same
  file list, so a `printf` given fewer arguments than its format wants fails
  the build rather than printing the wrong thing on every run.

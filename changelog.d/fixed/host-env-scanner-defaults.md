- The foreign-variable check could not see a variable a script defaults to
  itself. `SYSTEMD_ANALYZE_CMD="${SYSTEMD_ANALYZE_CMD:-systemd-analyze}"` reads
  the host's value whenever the host has one, but `host_env_vars.awk` counted
  the assignment and cancelled the read, so the check reported nothing. That
  hid the worst member of the class: `stay_fresh_timer.sh` executes the binary
  that variable names, so an exported value aimed a suite's `verify` at
  whatever the developer's shell said. `install_devtools.sh` hid two more,
  `CPPFLAGS` and `LDFLAGS`, which it appends to and exports into a `pyenv`
  build. All three are pinned now, in the suites and in the check itself.
  The scanner distinguishes a defaulted read from a plain assignment, and from
  `VAR="$VAROTHER/x"`, which reads a different name that merely starts the
  same; both directions are asserted against a probe, so the check fails rather
  than passes if it stops scanning.

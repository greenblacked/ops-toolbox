- The host-environment convention check now sees the whole repository. It read
  only `.sh` files, so a Python helper reading `os.environ` was invisible; it
  discovered only package `tests/` suites, so the `test-env/static/` ones were
  never asked; and it matched a script by name anywhere in a suite, so a
  suite's own comments counted as running it and a suite's prose about a
  variable counted as pinning it. Extraction moved into a single awk pass
  (`test-env/static/host_env_vars.awk`), which reads each file once and decides
  there: the two-stream comparison it replaces is the shape that made
  `changelog.sh preview` exit 141, and it had already cost this check a third
  of its subjects. Coverage went from 41 pairs to 53.

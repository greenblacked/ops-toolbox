- CI builds its `Test / <suite>` matrix from `run-tests.sh --list`, which now
  prints each suite's package directory as a second column. Adding a suite
  used to take four hand edits to the workflow - a job output, a filter line,
  a matrix entry and a summary row - and the dotfiles suite arrived with the
  summary row missing. The aggregator's table was already the one place to
  add a suite for everything local; it is now the one place for CI too, and
  the contract test checks that every listed package directory exists.

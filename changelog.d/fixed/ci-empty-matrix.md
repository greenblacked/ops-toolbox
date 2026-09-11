- The `Detect changes` job published an empty test matrix and exited 0 when
  `run-tests.sh --list` failed, because a process substitution's exit status
  is invisible to `set -e`. Every required `Test / <suite>` check then went
  missing rather than red, leaving the pull request unmergeable with nothing
  to point at. An empty matrix is now an error.

- Every suite that syntax-checks its package now does so with `"$BASH"`, the
  interpreter running the suite, rather than a bare `bash` resolved through
  `PATH`. On `macos-15` those differ: CI starts the suite with `/bin/bash`,
  the Apple 3.2 that is the point of that job, while `PATH` there puts
  Homebrew's Bash 5 ahead of `/bin`. #49 fixed the macOS suite; the k8s-toolbox
  suite had the same bug and does run on that runner (`run-tests.sh static
  k8s dotfiles`), so its `bash -n` was asking Bash 5 too. The git, linux and
  windows suites are changed for the same rule, though they run only where the
  two interpreters coincide. `check_conventions.sh` now enforces it across
  every suite: the probe that proves the pattern still matches the bare form
  and leaves `"$BASH"`, `"${BASH:-bash}"`, an absolute path and a printed
  `ok "bash -n …"` label alone is itself a floor, and zero suites scanned
  fails.

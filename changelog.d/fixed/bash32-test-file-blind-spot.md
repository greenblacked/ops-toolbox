- The "Bash 3.2 compatibility" section of `check_conventions.sh` skipped
  every file under `*/tests/*`, including
  `macos-initial-setup/tests/test_macos_initial_setup.sh` — the one test file
  the native macOS job hands to `/bin/bash` by absolute path, forcing the real
  3.2 interpreter, and whose own header already says it must stay Bash-4-free.
  A `declare -A` added there passed this check, passed every other gate, and
  would have failed only on a real Mac. That file is now scanned by name
  alongside the packages the section already covers; the rest of `*/tests/*`
  stays excluded on purpose, because none of the rest ever meets the real
  interpreter — most run inside a Linux container, two refuse to start
  anywhere else, and the packages reached through `run-tests.sh` on the native
  runner resolve a bare `bash` to a newer version that sits ahead of it on
  `PATH`. The section also gained a floor of its own: a probe it builds itself
  proves the scanner still catches a known-bad construct, and the check now
  fails outright, naming the gap, if it ever ends up inspecting zero files.

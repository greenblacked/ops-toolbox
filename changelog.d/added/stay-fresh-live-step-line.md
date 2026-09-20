- `stay_fresh.sh` draws a live line while a step runs: the step, its position
  in the plan and its elapsed time, rewriting in place. Homebrew and Xcode take
  minutes and say nothing while they do, and a static `==> Homebrew` gave no way
  to tell a slow step from a hung one.
- It is written to `/dev/tty`, never to stdout, so the log file, a pipe, this
  repository's test suites and CI see exactly the bytes they saw before. Piping
  the step through a filter would have kept the line clear of the step's own
  output and was not available: a piped step runs in a subshell, and the freed
  bytes and warning counts set in there would never reach the caller. The line
  waits a second before drawing, by which time a step has printed its opening
  lines and gone quiet — and a step that finishes inside that second never
  draws at all, which is most of them.
- `--no-progress`, or `STAY_FRESH_PROGRESS=0`, turns it off.

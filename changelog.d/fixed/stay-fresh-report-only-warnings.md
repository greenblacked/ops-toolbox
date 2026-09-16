- Two ways a scheduled `stay_fresh.sh` run turned red on a machine with
  nothing wrong. The brew step takes a line-count mark on the log before
  `brew update` and reads what came after it for a git lock; a mark that could
  not be taken (`wc` failing, an unreadable log) fell back to 0, so the reader
  started at line 1 and attributed every earlier step's output to brew — an
  `index.lock` mentioned by the docker step became "brew update did not
  refresh the taps", a `warn_step`, and under the LaunchAgent's
  `--fail-on-warn` a failed daily run. The mark now carries whether it is
  real; when it is not, the detector says it is not checking, as `info`, and
  the three counting readers keep their fallback because they match shapes
  only brew emits. And the Downloads step raised `warn_step` for an unreadable
  `~/Downloads` or a missing scratch directory, then fell through to report
  "nothing in ~/Downloads untouched" as though it had looked. Both are `warn`
  now, and a scan that failed returns instead of reporting an answer it does
  not have; a prune that fails still counts through `clear_paths`.
- The rule behind that is now checked, not remembered: the steps
  `--reports` names — "the steps that change nothing" — may not call
  `warn_step`, because the scheduled run passes `--fail-on-warn` and a
  report that warns on an ordinary machine is how somebody learns to stop
  reading it. `check_conventions.sh` reads the `--reports` list and the step
  table from the script itself, so a step that joins or leaves the list is
  covered by the commit that moves it. Four floors: the scheduled run must
  still pass `--fail-on-warn` or the check says to retire itself, every listed
  id must resolve to a step function, zero functions inspected fails, and at
  least one sweeping step must call `warn_step` or the scan has stopped
  matching. The tree did not pass it: `step_downloads` was the finding above.

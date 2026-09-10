- A scheduled `stay_fresh` run defers entirely on battery, and runs only the
  read-only reports when somebody has used the keyboard in the last five
  minutes. A full sweep is minutes of `du` and `rm` plus a `brew upgrade`, and
  neither a battery nor a working afternoon should pay for it unasked. The
  decision is recorded in the scheduled-run stamp and shown by `status`, so a
  deferral is never silent; `--ignore-power` skips both checks, and neither
  applies to `run-now`.

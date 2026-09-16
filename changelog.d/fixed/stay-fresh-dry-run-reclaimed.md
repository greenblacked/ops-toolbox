- A macOS `stay_fresh.sh --dry-run` no longer reports a reclaimed total. The
  summary subtracted the free-space reading taken at the end from the one taken
  at the start and printed it, in green, as `(N reclaimed)` — but a dry run
  deletes nothing, so that delta is whatever else the machine did while the run
  was going. On a busy Mac it is negative, which put `(-478.43M reclaimed)` in
  green directly above `steps freed: 0B` on a preview that had removed nothing.
  Both readings are still shown, without the claim. `history.tsv` and
  `last-run.json` were already skipped for dry runs, so `--trend` was never
  affected.
- A real run whose free space went *down* — something else wrote more than the
  sweep freed — reports that in yellow rather than green. It is a fact worth
  printing and not a win.
- The run log path no longer renders with a doubled slash
  (`.../T//stay_fresh-....log`) on macOS, where `TMPDIR` already ends in one.
  It appeared in the preflight line and in the warnings naming the directory.
  `linux/stay_fresh.sh` carried the same line and gets the same fix.
- The plan table lines up. `run` is three characters and `skip` is four, and
  neither was padded, so the DETAIL text on every `run` row sat one column left
  of the `skip` rows around it. The header also called the whole right-hand
  side `STATUS`, which named the verb and not the sentence beside it; the
  columns are now `STEP`, `DO` and `DETAIL`.
- Each step header carries its position — `==> Dev-tool caches [16/23]`. On a
  run where Homebrew and Xcode take minutes apiece, the step name alone does
  not say whether the run is a third of the way through or nearly done. The
  total is counted by the plan rather than kept as a second list, and the suite
  asserts the two cannot drift.
- The horizontal rule is drawn to the width of the terminal (clamped to 100)
  instead of a fixed 62 dashes, which fell short of a full line on a wide
  terminal and wrapped onto a second two-dash line on an 80-column one. Only
  when a terminal is attached: captured output keeps the bytes it had.

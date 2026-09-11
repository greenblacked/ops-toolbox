- `stay_fresh.sh` invented a reclaimed total when `df` could not answer. The
  reading after the run discarded its failure status, so a working `df` before
  and a failing one after made the total the negative of the whole disk — and
  that figure travelled into the summary, `last-run.json`, `history.tsv` and
  every `--trend` average computed from them. An unmeasured run now says so and
  records nothing; the per-step total, which is counted rather than subtracted,
  is unaffected.
- `stay_fresh.sh` announced local snapshots "thinned" when every
  `tmutil deletelocalsnapshots` had failed: the flag behind the verdict and the
  notification was set before the deletion loop rather than from what it
  achieved. A run that deletes nothing now reports the snapshots kept, with each
  failure named.

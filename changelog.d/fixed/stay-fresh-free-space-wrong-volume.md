- `stay_fresh.sh` measured free space on `/`, which since Catalina is the
  sealed System volume, while every byte it deletes is on the Data volume where
  `$HOME` lives. The two usually share one APFS container, so the figure was
  right by construction rather than by measurement — and wrong for a `$HOME` on
  another volume, another container or an external disk, which is the machine
  whose owner is watching it. Both readings, the reclaimed total in the summary
  and the free-space column carried into `history.tsv` and `last-run.json`, are
  now taken on the volume that holds `$HOME`. A run that cannot read it still
  reports no measurement rather than a zero.

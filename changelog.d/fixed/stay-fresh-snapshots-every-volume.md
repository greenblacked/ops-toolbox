- `stay_fresh.sh` looked for local Time Machine snapshots on `/` alone, so a
  second APFS volume or an external disk could hold a fortnight of them while
  the run reported "no local Time Machine snapshots" and `--thin-snapshots`
  left them where they were. Every mounted local volume is now listed, counted
  and thinned, from the same mount table the Trash step already reads — a
  network share is skipped by its type before the path is touched. `tmutil`
  deletes by date rather than by volume, so a date two volumes share is asked
  for once, and what a thinning run achieved is measured by listing the volumes
  again afterwards instead of inferred from `tmutil`'s exit status.

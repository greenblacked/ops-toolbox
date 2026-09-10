- `stay_fresh.sh --trend` reads the runs already recorded and answers what a
  single run cannot: whether free space is keeping up (it compares the space
  left after each run, not just what each run freed), which steps do the work,
  and which are taking steadily longer — the shape of a cache growing out of
  control, visible long before it is visible as a full disk. Read-only. Each
  run now also records one row per step in `steps.tsv` beside `history.tsv`,
  and the history row carries the free space left after the run.

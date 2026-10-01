- `git/git_prune_gone.sh` limits gone-upstream pruning to the selected remote,
  requires `--allow-unmerged` for tips not reachable from HEAD, and preserves
  every candidate tip in durable recovery refs before deleting any branch.
  Full-SHA restore commands remain usable after reflog expiry and garbage
  collection; a bounded recovery store and failed backup creation stop deletion,
  while current, worktree, protected, and symbolic branches remain guarded.

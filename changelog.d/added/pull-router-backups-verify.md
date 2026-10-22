- `mikrotik/features/pull_router_backups.sh` can check that what it pulled is
  usable and recent. `--verify` fails the run on an empty file, an `.rsc`
  without the RouterOS export header, or a `.backup` without its `.rsc`, and
  `--max-age HOURS` fails it when the newest `backup-*.backup` it pulled is
  older than that (files other routers left in a shared destination do not
  count). The script used to exit 0 for all of those, including a
  router whose backup scheduler had died and left one stale pair to be pulled
  again every night. Both checks are off unless asked for. `--verify`
  runs in the staging directory and publishes only the files that pass,
  so a rejected re-pull (a zero-byte file, say) never replaces an archived
  copy of the same name; the run exits 1 and the earlier copy is kept.
  `--max-age` also rejects a backup stamped more than 5 minutes in the
  future (a router clock running ahead), which would otherwise look fresh.
  When one extension's transfer fails (a permission or transport error, not
  the "no such file" result), the other extension's file is not paired with
  an archived copy of the missing one: it is rejected and the archived pair
  stays coherent.

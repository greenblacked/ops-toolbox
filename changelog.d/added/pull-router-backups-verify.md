- `mikrotik/features/pull_router_backups.sh` can check that what it pulled is
  usable and recent. `--verify` fails the run on an empty file, an `.rsc`
  without the RouterOS export header, or a `.backup` without its `.rsc`, and
  `--max-age HOURS` fails it when the newest `backup-*.backup` it pulled is
  older than that (files other routers left in a shared destination do not
  count). The script used to exit 0 for all of those, including a
  router whose backup scheduler had died and left one stale pair to be pulled
  again every night. Both checks only read the destination and are off
  unless asked for.

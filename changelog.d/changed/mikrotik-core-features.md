- The RouterOS scripts are split into `mikrotik/core/` and
  `mikrotik/features/`, by whether this fleet runs them. `core/` holds the three
  that are deployed and scheduled — `backup_update_check.lua`,
  `detect_internet.lua`, and the Telegram helper they both need, `tg_send.lua`
  (installed on the router as `tg_send_new`). `features/` holds everything else
  the package offers and nobody has deployed: the other backup and update paths,
  the hardening audit, the watchers and notifiers, and the two host-side tools.
  Being in `features/` says nothing about quality — both folders are held to the
  same conventions and the CHR suite runs all of them — only that no running
  router depends on it yet. Nothing changes on a router: a script's name in
  `/system script` and `/system scheduler` is still its filename without the
  extension, so `backup_update_check` is what it was.
- Three discoverers only looked one directory deep, and two of them would have
  passed rather than failed once the files moved. The CHR suite globbed
  `mikrotik/*.lua` and carried `skipif(not SCRIPT_FILES)`, so the suite that
  loads every script onto a real router would have reported success having
  loaded none; it walks now, and an empty list raises instead of skipping.
  `router_doctor.py` listed one directory to decide which scripts a router
  should have, so it would have compared the router against nothing and found
  nothing missing; it walks the package now, skipping `tests/`, and the names it
  returns are unchanged because a router script's name carries no folder. The
  convention suite's `find -maxdepth 1` would at least have failed loudly, and
  now resolves each script by filename, so a script that moves between the two
  folders needs no edit there.
- The convention suite gained the check that keeps the split honest: a script
  sitting loose at the top of the package fails, and so does one in neither
  folder, with a floor that fails if the check inspected nothing.

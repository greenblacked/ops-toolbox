- The RouterOS scripts are split into `mikrotik/core/` and
  `mikrotik/monitoring/`, by what a failure costs. `core/` holds the
  notification transport every other script calls, the backups, the two update
  checks and the hardening audit — lose those and there is no way back and no
  alert to say so. `monitoring/` holds the watchers and notifiers: lose one and
  a signal arrives late. Nothing changes on a router: a script's name in
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

- `mikrotik/features/router_doctor.py` now asks the router which RouterOS
  release it runs and says whether each installed script can run on it. On
  7.24 or later a script that declares an underscored `:global` or `:local`
  never gets past the parser and logs nothing, so the doctor used to call
  such a router healthy. Each one is now a `fail` when a scheduler runs it
  and a `warn` when nothing does, naming `backup_update_check` as the
  replacement for `update_check`. Routers on 7.23 get one line listing what
  will stop running after the upgrade. JSON output gains `routeros_version`
  and `incompatible_scripts`.

- `mikrotik/features/router_doctor.py` audits a whole fleet from one hosts
  file with `--hosts-file`, so checking ten routers is one run and one exit
  code rather than ten. Each router gets its usual report under its own
  heading, followed by a summary table; JSON output wraps the per-router
  reports with a summary. The run exits with the worst router: unreachable,
  then probe failed, then findings, and 4 only when every router is clean. A
  bad line in the file is reported with its line number before any router is
  contacted.

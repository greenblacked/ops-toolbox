- `linux/log_triage.sh` reports what has been going wrong in the logs over a
  `--since` window: the kernel's OOM kills, crashes, storage and filesystem
  errors, hung tasks and hardware errors counted by class, the identifiers
  with the most error-level lines, failed SSH logins grouped by source with
  accepted logins and failed sudo, and the most repeated messages with
  numbers folded. It is read-only, bounds what each section prints, strips
  control characters from log text before printing it, never prints a
  password, and refuses a `--since` that journalctl could read as an option.
  `--fail-on warn` makes findings exit 1.

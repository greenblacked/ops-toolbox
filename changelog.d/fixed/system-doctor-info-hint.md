- `linux/system_doctor.sh` swallowed the hint beside its pending-upgrade count.
  `info()` rendered only its first argument, so the preview command passed as a
  second one went nowhere — the single observation that offers you a next
  command without being a finding was the single one that could not show it.
  `info()` now takes the same optional dimmed second line `warn()` has, and
  `--quiet` still suppresses both.

- The Runbooks section has a runbook for a Linux host that cannot reach the
  network or resolve names. It reads the `net_doctor.sh` sections in order,
  quotes each warning it can print, and maps them to the link, DNS or a
  firewall, with `hardening_audit.sh` for the local firewall posture. It
  warns that `net_doctor.sh` exits `0` whenever the report printed, so the
  warnings, not the exit code, carry the verdict.

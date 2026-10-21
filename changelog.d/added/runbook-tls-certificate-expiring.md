- The Runbooks section has a runbook for a TLS certificate that is expired
  or about to expire. It checks files and hosts with `tls_expiry.sh`, uses
  `net_doctor.sh` to tell a network fault from a bad certificate, and warns
  that a host that cannot be fetched is only a warning, so the default
  `--fail-on expired` still exits `0`; a check that must notice it needs
  `--fail-on warn`.

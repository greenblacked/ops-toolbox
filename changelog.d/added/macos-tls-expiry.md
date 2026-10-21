- `macos-initial-setup/tls_expiry.sh` is the macOS counterpart of
  `linux/tls_expiry.sh`: it grades PEM files and the leaf a host presents,
  failing an expired certificate and warning inside the `--days` window,
  without GNU date or `timeout`. `--keychain` grades the client identities in
  the login and System keychains (matched by SHA-1 fingerprint, so
  unrelated expired certificates do not fail the run), reading public
  certificates only so no unlock prompt appears.
  Exit 1 at or above `--fail-on` makes it a runbook and scheduler check.

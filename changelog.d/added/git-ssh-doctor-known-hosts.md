- `git_ssh_doctor.py` now checks whether each host's key is already in
  known_hosts before it tries to authenticate, the cause of "Host key
  verification failed" on a runner that cannot answer the prompt. The lookup
  honours custom known_hosts files, non-22 ports, `HostKeyAlias` and hashed
  entries, and prints the `ssh-keyscan` and fingerprint check that pin the
  key. `StrictHostKeyChecking no` is reported as a risk. An unknown key is a
  warning, or a failure with `--require-known-host` for a CI preflight.

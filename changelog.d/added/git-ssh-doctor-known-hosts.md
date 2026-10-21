- `git_ssh_doctor.py` now checks whether each host's key is already in
  known_hosts before it tries to authenticate, the cause of "Host key
  verification failed" on a runner that cannot answer the prompt. The lookup
  honours custom known_hosts files, non-22 ports, `HostKeyAlias` and hashed
  entries, and prints the `ssh-keyscan` and fingerprint check that pin the
  key. `StrictHostKeyChecking no` is reported as a risk. An unknown key is a
  warning, or a failure with `--require-known-host` for a CI preflight, also
  when `StrictHostKeyChecking accept-new` would record it on first use.
  `--require-known-host` fails closed when `ssh-keygen` is missing, and an
  effective `KnownHostsCommand` is reported as not checked (never run)
  instead of failing the requirement on the file scan alone.
  With `--require-known-host` the authentication attempt uses
  `StrictHostKeyChecking=yes` and `UpdateHostKeys=no`, so it does not
  write to known_hosts, and a
  missing `ssh-keygen` is reported as an unchecked key rather than an
  unknown one.

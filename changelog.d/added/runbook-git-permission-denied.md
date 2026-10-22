- The Runbooks section has a runbook for `Permission denied (publickey)` on
  a Git remote. It pairs `git_ssh_doctor.py`, which asks OpenSSH what it
  will really offer and catches an `Include` that matches only directories,
  with `ssh_client_doctor.sh` for the modes and missing key files under
  `~/.ssh`. It says that the doctor makes one real connection per host even
  without `--test-auth`, that it tests `git@HOST` on the configured port
  (so a remote with another user or an explicit port needs a manual
  `ssh -v -T -p PORT user@host`), and that the scripts print fixes but
  never apply them.

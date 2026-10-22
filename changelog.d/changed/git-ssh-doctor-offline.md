- `git_ssh_doctor.py` makes no connection unless `--test-auth` is given.
  Before, the default run and `--quiet` still tried one authentication,
  which uses the network and may record a host key under `accept-new`,
  against the README's promise that a quiet CI probe stays offline. Without
  the flag it now reports the configuration and says authentication was not
  attempted; `--test-auth` authenticates as git would and then tries each
  discovered key.
- `git_ssh_doctor.py` authenticates as the user git would use: the one in
  the remote URL (`ssh://deploy@host`, `deploy@host:path`) or in
  `--host deploy@host`, else a `User` set in ssh config for the host, else
  `git`, instead of probing the local account name. It also follows
  `GIT_SSH_COMMAND` and `core.sshCommand` for a repository's remotes,
  applying their `-i`, `-F`, `-p`, `-o` and `-l` options to `ssh -G` and the
  attempt. Any other command is reported as a custom SSH command that was
  not inspected, and the run exits 1 (a failure under
  `--require-known-host`) since nothing was checked.

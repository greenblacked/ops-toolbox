- `git_ssh_doctor.py` makes no connection unless `--test-auth` is given.
  Before, the default run and `--quiet` still tried one authentication,
  which uses the network and may record a host key under `accept-new`,
  against the README's promise that a quiet CI probe stays offline. Without
  the flag it now reports the configuration and says authentication was not
  attempted; `--test-auth` authenticates as git would and then tries each
  discovered key.
- `git_ssh_doctor.py` exits 1 (a failure under `--require-known-host`)
  when the effective ssh command is a custom program or an ssh command
  with options it cannot read (such as `-J`), since nothing was checked.

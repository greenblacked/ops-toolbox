- `macos-initial-setup/ssh_client_doctor.sh` is the macOS counterpart of
  `linux/ssh_client_doctor.sh`: it checks the modes of `~/.ssh` (a
  group- or other-writable directory fails, read access only warns) and
  its keys, grades DSA and short RSA keys from the private key itself
  (warning when a `.pub` beside it does not match), finds private keys
  that open with no passphrase (dot-prefixed ones such as `.deploy_key`
  and `IdentityFile` targets outside `~/.ssh` included; a key with loose
  permissions is reported as not checked, with no keychain advice), names
  `IdentityFile` paths that do not exist, and warns when
  `ForwardAgent yes`, `StrictHostKeyChecking no` or
  `UserKnownHostsFile /dev/null` applies to every host (`Host *`,
  `Match all` or `Match host *`). It changes nothing, never prints key
  material, and prints the `chmod` or `ssh-keygen` command for each
  finding. Modes are read through symlinks, so a link to a `0600` key or a
  symlinked `--ssh-dir` is graded by its target, not as `0777`.
  OpenSSH uses the first value it obtains for an option, so a risky
  `ForwardAgent`, `StrictHostKeyChecking` or `UserKnownHostsFile` in a
  block for every host that comes after an earlier such value is noted as
  ignored instead of warned.

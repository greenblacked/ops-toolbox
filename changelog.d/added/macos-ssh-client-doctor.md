- `macos-initial-setup/ssh_client_doctor.sh` is the macOS counterpart of
  `linux/ssh_client_doctor.sh`: it checks the modes of `~/.ssh` (a group- or other-writable directory
  fails, read access only warns) and its keys,
  grades DSA and short RSA keys from the private key itself (warning when
  a `.pub` beside it does not match), finds private keys that open with no
  passphrase, names `IdentityFile` paths that do not exist, and warns when
  `ForwardAgent yes`, `StrictHostKeyChecking no` or
  `UserKnownHostsFile /dev/null` applies to every host. It changes nothing,
  never prints key material, and prints the `chmod` or `ssh-keygen` command
  for each finding.

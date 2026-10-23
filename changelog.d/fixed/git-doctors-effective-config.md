- `git_ssh_doctor.py` authenticates as the user git would use, instead of
  always `git`: a `-l` or `-o User=` in the effective ssh command (the
  first one wins), else the user in the remote URL (`ssh://deploy@host`,
  `deploy@host:path`) or in `--host deploy@host`, else a `User` from ssh
  config unless it equals the local account, else `git`. It also follows
  `GIT_SSH_COMMAND` and `core.sshCommand` for a repository's remotes,
  applying their `-i`, `-F`, `-p`, `-o` and `-l` options to `ssh -G` and
  the attempt, and reports a custom program or an ssh command with
  options it cannot read (such as `-J`) as a custom SSH command that was
  not inspected.
- `git_remote_doctor.py` counts URL-scoped `credential.<url>.helper` entries
  when it checks the credential helpers of an HTTP remote, so a helper
  configured for one host is no longer reported as missing.
- `git_signing_doctor.py` reads `user.signingkey` according to `gpg.format`:
  under `openpgp` an email, user id or `<fingerprint>!` forced subkey is a
  valid GnuPG selector and is no longer called an SSH key path.
  A mismatch message names the configured `gpg.format` (such as `x509`)
  instead of always saying `openpgp`.

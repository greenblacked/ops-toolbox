- `windows/setup/ssh_client_doctor.ps1` checks the OpenSSH client side of a
  Windows account, the counterpart of `linux/ssh_client_doctor.sh` with the
  same verdicts and exit codes. It catches the Windows-only reasons a key
  is refused: an access list that lets anyone but you, SYSTEM and
  Administrators read it, an `ssh-agent` service that is still Disabled,
  and Git's bundled ssh that cannot see the keys in the Windows agent. It
  reads only the first line of each key, prints no key material, and
  prints the `icacls` or `git config` fix instead of applying it.

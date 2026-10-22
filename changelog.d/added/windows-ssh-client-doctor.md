- `windows/setup/ssh_client_doctor.ps1` checks the OpenSSH client side of a
  Windows account, the counterpart of `linux/ssh_client_doctor.sh` with the
  same verdicts and exit codes. It catches the Windows-only reasons a key
  is refused: an access list that lets anyone but you, SYSTEM and
  Administrators read it, an owner other than you, SYSTEM or
  Administrators (with the `icacls /setowner` fix), an `ssh-agent`
  service that is still Disabled, and Git's bundled ssh that cannot see
  the keys in the Windows agent, whether by default or because
  `GIT_SSH_COMMAND`, `core.sshCommand` or `GIT_SSH` (the first one set,
  as git decides) pins it. It reports that git and ssh agree on the
  agent's client only when that client is positively Windows OpenSSH, and
  otherwise says agent use is not verified for it. It reads only the first
  line of each key, prints no key material, and prints the `icacls` or
  `git config` fix instead of applying it. A `core.sshCommand` set only
  in the system-wide git config is graded too.

- `windows/wsl/wsl_manage.ps1 clone` copies a distro under a new name, the
  safest place to try a distro upgrade or a script you do not trust yet. It
  exports to a staging tar that can never be mistaken for a backup, imports
  it, gives the copy the source's default user, and deletes the staging tar
  in a `finally` block (`-KeepTar` keeps it as a dated backup with its
  sidecar). The source is never touched, nothing is ever unregistered, every
  refusal comes before the slow export, and `-DryRun` prints each step.
  `restore -DefaultUser NAME` closes the gap that made a restored distro boot
  as root: after the import it adds the `[user]` section to `/etc/wsl.conf`,
  terminates the distro so the file is read, and confirms the result; a name
  that is not a valid Linux user is refused before anything is imported.

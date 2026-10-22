- `dotfiles/dotfiles_doctor.sh` checks the untracked overlays the ssh and git
  configs rely on: that `known_hosts` holds no plaintext host while
  `~/.ssh/config` turns `HashKnownHosts` on, that no ControlMaster socket
  from a killed master is left in `~/.ssh`, that a commit identity is set
  through `config.local`, and that no `~/.gitconfig` silently overrides the
  tracked git config. The ssh config is read as text and ssh is never run
  (`ssh -G` would execute `Match exec` lines). Host names and identity
  values are never printed, and every fix is printed rather than run.

- `dotfiles/dotfiles_doctor.sh` checks the untracked overlays the ssh and git
  configs rely on: that `ssh -G` accepts `~/.ssh/config`, that `known_hosts`
  holds no plaintext host while `HashKnownHosts` is on, that no ControlMaster
  socket from a killed master is left in `~/.ssh`, that a commit identity is
  set through `config.local`, and that no `~/.gitconfig` silently overrides
  the tracked git config. Host names and identity values are never printed,
  and every fix is printed rather than run.

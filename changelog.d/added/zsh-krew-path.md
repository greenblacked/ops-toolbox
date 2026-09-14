- `zsh_aliases.zsh` puts `$KREW_ROOT/bin` on `PATH` when the directory exists,
  so kubectl can find the plugins krew installed and krew stops telling you to
  add the line yourself. Guarded both ways, like the `GOPATH` entry beside it:
  nothing changes on a machine without krew, and re-sourcing the file does not
  stack copies.

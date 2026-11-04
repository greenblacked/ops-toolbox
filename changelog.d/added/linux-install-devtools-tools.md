- `linux/install_devtools.sh` installs `mc`, `iotop`, `nload`, `ncdu` and
  `btop` with the other DevOps CLIs. `ripgrep` and `fd` move out of the core
  batch with them, so each is installed on its own and a package missing on
  an older release is a warning rather than a failed batch; the core batch is
  now `git`, `jq` and `unzip`, plus `curl` only when none is installed. `iotop`
  is `iotop-c` on dnf hosts, falling back to `iotop`. `nmtui` is added as
  `NetworkManager-tui` only where NetworkManager is already installed; the
  script never installs NetworkManager, which could take over the interfaces
  of a server that does not use it.

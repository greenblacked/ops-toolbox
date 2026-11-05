- `linux/install_devtools.sh` enables EPEL (`epel-release`, then `crb enable`)
  on Rocky, Alma and CentOS before installing the DevOps CLIs, because
  `ripgrep`, `fd-find`, `btop`, `nload` and `ncdu` live in EPEL there. The step
  persistently adds third-party repositories, so `--no-epel` skips it. Other EL
  rebuilds such as Oracle Linux and RHEL are left to the administrator. The
  Linux tests also run in a Rocky 9.8 container, pinned by digest
  (`LINUX_DISTROS=rocky`, included in `all`), with a matching `linux (rocky)`
  job in CI.

- `linux/kernel_cleanup.sh` removes old kernel packages, the usual reason a
  full `/boot` makes an apt or dnf upgrade fail, which `apt-get autoremove`
  does not reliably fix. It keeps the running kernel, the newest `--keep`
  kernels besides it (default 2) and the newest installed one, never leaves
  fewer than two installed, and refuses rather than guesses when it cannot
  tell which kernel is running. On apt it purges each old release's image,
  modules and headers (including the common flavour-less headers package
  once no kept release shares its version) in one call; on dnf it removes the versioned kernel
  packages; pacman needs nothing. `--list` shows the plan read-only,
  `--dry-run` previews the removal and a real run needs `--yes`. It never
  autoremoves, reboots or edits the bootloader.

- `linux/packages.sh` has two read-only commands for the questions asked
  before maintenance. `holds` lists held, version-locked or ignored packages
  (`apt-mark showhold`, dnf versionlock and `exclude=`, pacman `IgnorePkg`),
  the ones an upgrade skips. `orphans` lists what autoremove would remove
  (`apt-get -s autoremove`, `dnf repoquery --unneeded`, `pacman -Qdtq`).
  Both print sorted names only on stdout, so they pipe like `list`, and
  need no sudo.
  On dnf, a versionlock listing that fails while the plugin is installed
  is an error (exit `1`), not an empty list of locks.

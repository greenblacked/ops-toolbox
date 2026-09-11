- `linux/config_backup.sh` created its archive at whatever umask it inherited,
  which under a stock 022 meant mode 0644. The default `--paths` is `/etc` and
  the script plainly expects a privileged run — it treats tar's exit 1 as
  "unreadable files under /etc, archive still written" — so `sudo
  ./config_backup.sh --yes` left shadow, the sshd host keys and sudoers in a
  tarball under a predictable name that every local account could read. The
  archive is now created 0600. `--dest` keeps the mode the operator gave it:
  the secret is the file, not the folder.

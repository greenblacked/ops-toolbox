- `linux/config_backup.sh` takes `--exclude` (repeatable tar globs relative
  to `/`) and `--exclude-secrets`, a short fixed list: shadow and gshadow,
  opasswd, the SSH host private keys, `/etc/ssl/private` and the distro's
  `passwd-` style backup copies. That makes an archive you can attach to a
  ticket or hand to a colleague, and a non-root run whose only unreadable
  files are excluded is no longer partial. The list is deliberately narrow
  and documented as not making an archive safe to publish.
  The exclusions are recorded in the archive (`.config_backup/excludes`), so
  a later `--diff` leaves the same files out of its new-file scan instead of
  listing each as `NEW`; `--exclude` and `--exclude-secrets` are also
  accepted on `--diff`, and older archives without the record compare as
  before.
  Exclusions that cover every source now fail the run (exit `1`, nothing
  published) instead of publishing an archive holding only that record or
  bare directory entries. When no `--exclude` was given, the message says
  the sources contain no files to back up instead of blaming exclusions;
  the `--exclude-secrets` patterns count as exclusions.

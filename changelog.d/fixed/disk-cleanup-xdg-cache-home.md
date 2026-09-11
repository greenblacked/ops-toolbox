- `linux/disk_cleanup.sh --home DIR` deleted files outside `DIR`. The
  thumbnail step read `$XDG_CACHE_HOME` straight from the environment, so a
  run aimed at one profile emptied the cache of whoever invoked it — and
  `linux/tests/test_linux_scripts.sh`, which cleans a scratch profile, did
  exactly that to a developer's own thumbnails. With `--home` the ambient
  variable is now inert and the run says so; without it, it is still honoured.

- The macOS steps suite forwarded only a named list of variables to
  `stay_fresh.sh`, and the cache-location ones were not on it. `BUN_INSTALL`
  is exported on a developer machine and in the suite's own container, so a
  test meant to exercise the default cache path cleared the real one instead
  and passed for the wrong reason; a caller writing `FOO=x out="$(run_sf …)"`
  was also making two assignments rather than prefixing a command, so the
  value never reached the script at all. `BUN_INSTALL`, `TF_PLUGIN_CACHE_DIR`,
  `CLOUDSDK_CONFIG` and `UV_CACHE_DIR` are now forwarded explicitly, which
  both carries a test's value in and keeps the host's out.

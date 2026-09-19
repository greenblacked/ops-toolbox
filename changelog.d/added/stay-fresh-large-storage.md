- `stay_fresh.sh` classifies idle Claude renderer caches through
  `large_storage.py`. VM bundles, sessions, Service Worker data, blob storage,
  GeForce NOW data, JetBrains Local History and downloaded models remain kept,
  including during `--deep-clean`. Helper executables count as app activity;
  a failed process check keeps caches even with `--force-active-app-caches`.

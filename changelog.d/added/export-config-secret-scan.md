- `mikrotik/features/export_config.py` finds secrets in an export and can
  redact them. Plain `/export` does not hide script sources or scheduler
  `on-event` bodies, and the install steps put the Telegram bot token in a
  startup script, so `--commit` could put a live token into git history.
  `--scan-secrets` reports each finding by line and kind, never the value,
  and exits 1 when there is one; `--scan-file` does the same for a stored
  export with no ssh; `--redact-secrets` replaces each value with
  `<redacted>` before anything is printed, diffed or written. One behaviour
  changes: `--commit` now refuses an export that holds a secret unless
  `--redact-secrets` is given, and the other modes warn on stderr.

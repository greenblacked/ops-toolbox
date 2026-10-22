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
  A quoted field value that never closes is treated as a secret to the end
  of the line, and a value that starts with an escaped `\$` in a field is a
  literal dollar in the secret, not a variable reference. A field value
  that is a RouterOS expression (`$name`, `$[...]`, `$(...)`, `$"name"`) is still
  not reported.
  The scan also catches script variables with underscores in the name
  (`BACKUP_PASSWORD`, `CF_API_TOKEN`), and `--redact-secrets --diff`
  redacts the stored export too, so an old secret never prints on a
  removed line.
  An unquoted literal (`:global ApiPassword abc123`) is found and redacted
  like a quoted one. Only the exact placeholder assignments the package
  ships are exempt, plus `<redacted>`; a value such as
  `"<production-secret>"` is reported.
  A bare literal stops at a closing `}`, `]` or `)`, so
  `do={:set password abc}` redacts only `abc`, and an array value
  (`{"a";"b"}`) is not reported as a literal.
  A quoted variable name (`:global "api-token" "x"`, escaped inside an
  export) is recognised, and `preshared-key=` on a WireGuard peer is
  treated as a secret field.

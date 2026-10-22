- `mikrotik/features/export_config.py` no longer commits what its secret
  scan cannot read. The scan was a set of patterns, so a script line the
  patterns skipped (an unbalanced quote, an unknown escape, a quote inside
  the field, a `$`, `[...]` or array value that might hold a literal, a
  variable name it could not extract) passed as clean. Every `:global`,
  `:local` and `:set` is now also tokenized on its own, and one that cannot
  be read with confidence is reported as unverifiable. `--commit` refuses
  it with the line number and the reason and exits 1, like a leak, and
  `--redact-secrets` does not override it. There is no option to skip the
  check. Print-only output still warns and redacts, and `--scan-secrets`
  and `--scan-file` list unverifiable lines and exit 1.
  A bare word inside `[...]`, `(...)` or `{...}` counts as a possible
  literal, a backslash-n in a plain script is no longer taken for a line
  break, and `:global`/`:set` glued to a quote or bracket is still read.

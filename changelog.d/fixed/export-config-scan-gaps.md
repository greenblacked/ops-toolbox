- `mikrotik/features/export_config.py`: the secret scan closes three more
  gaps. A number inside an expression is no longer taken for harmless
  (`:set WifiPassword (12345678)`, `[:tostr 12345678]`,
  `:set ApiToken (10.20.30.40.50.60)` are unverifiable; only up to three
  digits with no dot, as in `[:pick $a 0 4]`, passes), and a quoted value
  starting with `[` or `(` is a literal string, not an expression. A plain
  string that ends in `=` (`"a="`) is no longer read as an open export
  field, so a later backslash-n and `#` cannot hide an assignment. A
  commented-out assignment of a literal to a secret-named variable is now
  reported as `commented assignment with a literal` and blocks `--commit`;
  placeholders, `<redacted>` and variables in comments stay quiet.

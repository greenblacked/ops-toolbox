- `mikrotik/features/export_config.py`: the secret scan now decides a
  secret-named variable's value by shape, not by an allowlist of tokens.
  The allowlist kept leaking (`(123 . 456 . 78)` joined short numbers into
  a pre-shared key). A `:global`, `:local` or `:set` of a secret-named
  variable is accepted only when its value is empty, a lone `$variable`,
  `<redacted>` or a shipped placeholder; any expression, bracket, paren,
  brace, number, concatenation or command result is reported and blocks
  `--commit`. `[:pick $a 0 4]` and `$[/system/identity/get $name]`, which
  used to pass, are now findings. Variables with other names are not
  affected.
- `mikrotik/features/export_config.py`: secret names match whatever the
  separator, so `api_key`, `api-key` and `API_KEY` count like `apikey`, and
  `private_key`, `access_key`, `pre_shared_key`, `wpa_key` and a `pin` word
  are covered too. `global`, `local` and `set` without the colon are read
  where they start a statement. A commented-out assignment whose name
  cannot be parsed is reported when its raw text names a secret
  (`# :set "api:token" "x"`).

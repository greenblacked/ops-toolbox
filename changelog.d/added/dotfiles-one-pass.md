- The dotfiles suite parses its TOML, YAML, JSON and Python configs in one
  Python run instead of one interpreter launch per file, which was most of
  the suite's wall clock. Per-file verdicts and the skip-when-no-parser
  behaviour are unchanged.

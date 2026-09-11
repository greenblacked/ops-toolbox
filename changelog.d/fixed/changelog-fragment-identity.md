- `changelog.d/changelog.sh check` and the paste disagreed about what a
  fragment is. `check` enumerated dot-files while the paste globbed only
  `*.md`, so a `.hidden.md` was counted and then silently dropped by
  `release`, and a `.DS_Store` or a vim swapfile in the working tree failed
  the whole static suite. Both now enumerate the same thing. A fragment of
  nothing but whitespace is also rejected rather than pasting two blank lines.

- `changelog.sh` could not be parsed by the Bash that ships on macOS, and the
  first attempt at fixing it was wrong. The cause is a `case` statement inside a
  multi-line `$( )`: Bash 3.2 parses `$(` by scanning for the matching `)` and
  miscounts on the unbalanced `)` closing each case pattern, so it dies with
  `syntax error near unexpected token 'newline'` and every `preview` and
  `release` assertion fails at once. The `case` is an `if` now.
- A conventions check refuses that construct repository-wide. It is valid Bash 4
  syntax, shellcheck is silent on it, and the Bash 4+ keyword scan looks for
  `mapfile`, `declare -A` and `${x,,}` — so nothing saw it but a macOS runner.
  Unlike the keyword scan this is not scoped to `BASH32_DIRS`: any script the
  static suite executes must parse under whatever `/bin/bash` the runner has.

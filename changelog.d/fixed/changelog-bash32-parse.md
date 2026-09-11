- `changelog.sh` could not be parsed by the Bash that ships on macOS. A nested
  `$( ... do ... done )` sitting in a `case` pattern word inside another command
  substitution is valid Bash 4 and a syntax error in Bash 3.2, which is what
  `/bin/bash` is on macOS: the script died with `syntax error near unexpected
  token 'newline'` and every `preview` and `release` assertion failed at once.
  The label list is built before the substitution now. Nothing caught this
  because the Bash 3.2 convention check scans for version-specific *keywords*
  (`mapfile`, `declare -A`, `${x,,}`) and this is a parser incompatibility in
  otherwise ordinary syntax — only running the suite on a BSD box finds it,
  which is what the widened macOS job now does.

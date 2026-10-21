- `git/git_hooks_doctor.py` explains why a git hook does not run: a
  `core.hooksPath` that points nowhere (so git runs no hooks and says
  nothing) or that shadows the repository's own hooks from global config, a
  hook without the exec bit, a CRLF or missing interpreter in the shebang (including an `env`
  shebang with several words and no `-S`, which Linux cannot run),
  a misnamed hook file (a .sh suffix, a missing hyphen), and a committed
  `.pre-commit-config.yaml`, `.husky/`, `.githooks/` or lefthook config that
  was never activated in this clone. It reads only the start of each hook
  and prints every repair, with paths shell-quoted, instead of making
  it. It takes `--quiet` and `--json` like the other doctors.

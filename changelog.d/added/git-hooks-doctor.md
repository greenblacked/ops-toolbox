- `git/git_hooks_doctor.py` explains why a git hook does not run: a
  `core.hooksPath` that points nowhere (so git runs no hooks and says
  nothing; a relative path is read from the work tree root for client hooks
  and from `$GIT_DIR` for the hooks a push runs, and both are reported) or that shadows the repository's own hooks from global config, a
  hook without the exec bit, a CRLF or missing interpreter in the shebang (including an `env`
  shebang with several words and no `-S`, which Linux cannot run, and a
  direct interpreter given several arguments, which Linux passes as one),
  a misnamed hook file (a .sh suffix, a missing hyphen), and a committed
  `.pre-commit-config.yaml`, `.husky/`, `.githooks/` or lefthook config that
  was never activated in this clone. It reads only the start of each hook
  and prints every repair, with paths shell-quoted, instead of making
  it. It takes `--quiet` and `--json` like the other doctors.

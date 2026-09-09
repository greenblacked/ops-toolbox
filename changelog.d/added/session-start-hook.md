- A startup hook for hosted coding sessions, `.claude/hooks/session-start.sh`,
  registered through `.claude/settings.json`. A session that starts from a
  bare clone lacked `zsh` (the macOS contract suite died at its last check),
  ran a different ShellCheck than the one `ci.yml` pins, had no Docker daemon
  for the macOS suites, and had lost the attribution guard with the
  container. The hook reads the versions from `ci.yml`, installs ShellCheck,
  ruff and markdownlint-cli2 at those versions, adds `zsh`, lays out `/repo`,
  `/.dockerenv`, `/rootonly` and `/rootlocked` so the macOS steps and
  unprivileged suites run directly, and reinstalls the guard. `--check`
  reports without changing anything and exits 1 when something is missing;
  outside a remote session the hook is a no-op unless `--force`. The
  `.gitignore` rule that keeps agent state out of the tree now re-admits just
  those two files.

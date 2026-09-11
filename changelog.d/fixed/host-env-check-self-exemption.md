- The host-environment convention check exempted `check_conventions.sh`, the one
  suite that actually executes every script in the repository — `--help`, an
  unknown flag and a full dry run apiece. It pinned only `HOME` and `TMPDIR`, so
  eighteen variables reached those runs from the developer's shell, notifier
  tokens among them, and an `XDG_CONFIG_HOME` sent a dry run to the real
  `~/.config` where the scratch snapshot could not see the write. The suite is
  on its own list now and pins the rest; coverage went from 53 pairs to 71.
- `dotfiles/tests/test_dotfiles.sh` passed all thirteen configs without parsing
  any of them when `python3` could not start: the verdicts arrive through a
  process substitution, whose exit status the shell never sees, so no lines meant
  no failures. It now asserts one verdict per file.

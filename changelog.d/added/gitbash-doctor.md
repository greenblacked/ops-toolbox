- `windows/git-bash/gitbash_doctor.sh` is a read-only doctor for the Git Bash
  environment around the dotfiles, for the quiet failures that each cost an
  hour the first time: a dotfile saved with CRLF or that no longer parses, a
  `~/.ssh/agent.env` pointing at an agent that is gone, Windows' OpenSSH
  client ahead of Git's so the agent's keys are invisible, a `HOME` under
  OneDrive or with a space in it, long paths off in Git and in the registry,
  no credential helper, a private key with no passphrase or one that is
  malformed rather than protected, `safe.directory = *`, and the Microsoft
  Store `python` stub on `PATH`. Each finding comes with the command that
  fixes it; nothing is changed and no key material is printed. A probe whose
  tool is absent is skipped, so it also runs on Linux. With `--source`, a
  managed file missing from the source directory is a failure (exit 1), so
  an incomplete source cannot pass as a clean one.
  The global Git settings are read from both `~/.gitconfig` and the XDG file
  (`$XDG_CONFIG_HOME/git/config`, default `~/.config/git/config`; with
  `--home`, always `<home>/.config/git/config`), with `~/.gitconfig`
  winning, as Git itself resolves them. When several credential helpers
  are configured, all are listed in the order Git runs them: system file
  first, then the XDG file, then `~/.gitconfig`, with an empty
  `helper =` line dropping the ones before it.

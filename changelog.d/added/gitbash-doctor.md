- `windows/git-bash/gitbash_doctor.sh` is a read-only doctor for the Git Bash
  environment around the dotfiles, for the quiet failures that each cost an
  hour the first time: a dotfile saved with CRLF or that no longer parses, a
  `~/.ssh/agent.env` pointing at an agent that is gone, Windows' OpenSSH
  client ahead of Git's so the agent's keys are invisible, a `HOME` under
  OneDrive or with a space in it, long paths off in Git and in the registry,
  no credential helper, `safe.directory = *`, and the Microsoft Store
  `python` stub on `PATH`. Each finding comes with the command that fixes it;
  nothing is changed and no key material is printed. A probe whose tool is
  absent is skipped, so it also runs on Linux.

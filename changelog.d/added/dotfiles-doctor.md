- `dotfiles/dotfiles_doctor.sh` is a read-only health report for the configs
  `install_dotfiles.sh` put in place. Its first check finds a credential that
  a tool wrote through a link into the tracked repository (`npm login` into
  `~/.npmrc`, a token in a pip index URL, a password in a git url rewrite),
  and names the file and the line, never the value, before anyone runs
  `git add`. It works copied alone into `~/bin`, where the link check is
  skipped.

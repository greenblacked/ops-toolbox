- `dotfiles/install_dotfiles.sh` no longer treats a link as its own because
  its text starts with the repository path: a target that climbs out with
  `..` or resolves outside the folder is reported as a foreign link and
  `--diff` names it instead of printing the file it leads to.

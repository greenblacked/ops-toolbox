- `dotfiles/dotfiles_doctor.sh` no longer reads a file because a link's
  text starts with the repository path: a target that climbs out with `..`
  or whose chain resolves outside the folder is skipped instead of being
  scanned for credentials.

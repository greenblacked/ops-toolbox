- `dotfiles/install_dotfiles.sh --status` reports an `ORPHAN` line for each
  link into the dotfiles folder at a path no tracked file installs to, which
  is what renaming or deleting a config used to leave behind for good, and
  `--prune` removes those links. It removes only links whose text points into
  the folder, never a regular file, a directory or a `.backup-*` link,
  scans a bounded depth (including hidden directories at the top of the home,
  so a deleted source directory is still found), and previews with `--dry-run`.

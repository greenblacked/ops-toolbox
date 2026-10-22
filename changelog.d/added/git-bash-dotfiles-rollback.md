- `windows/git-bash/install_dotfiles.sh` can now undo itself. Every install
  left `<name>.backup-<stamp>` files in `$HOME` with no way back but finding
  the right stamp and copying three files by hand while the shell was already
  broken, and the backups piled up forever. `--list-backups` shows the sets
  newest first, `--restore STAMP` (or `latest`) puts one back after saving
  what it replaces as a new set (under a `-1`, `-2` ... suffixed stamp when
the current second's is taken, never over an existing set), so a rollback is
itself undoable, and keeps a
  symlinked dotfile a symlink (a destination that is a directory is skipped
  and the command exits 1 once the rest of the set is back);
  `--prune-backups N` deletes all but the newest sets, previewing unless
  `--yes` is given. Only files this script named are touched, and none of
  the three needs the source files.

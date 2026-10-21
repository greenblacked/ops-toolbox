- `dotfiles/install_dotfiles.sh` gained `--backups`, which lists the
  `NAME.backup-STAMP` files `--force` set aside, and `--restore`, which moves
  the newest (or the one `--stamp` names) back into place, so trying the
  dotfiles and changing your mind no longer means a hand-typed `mv` per
  file. A restore acts only where the path is empty or holds the installer's
  own link or an identical copy; a changed file is left in place with exit 4,
  and no backup is ever deleted.

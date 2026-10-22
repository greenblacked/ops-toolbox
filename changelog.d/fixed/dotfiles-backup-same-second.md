- `dotfiles/install_dotfiles.sh --force` no longer overwrites a backup made
  in the same second: the second one is named `.backup-STAMP-1` (then `-2`,
  ...), and `--backups`, `--restore` and `--stamp` understand the suffix.

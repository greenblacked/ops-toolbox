- `dotfiles/install_dotfiles.sh` gained `--diff`: for each file `--status`
  reports as `DRIFT`, `CONFLICT` or `FOREIGN` it prints a unified diff of the
  tracked source against what is on disk, so the edit k9s, `aws configure` or
  `docker login` made to a copied config can be folded back by hand.
  Credential values are printed as `<redacted>`, nothing is written, and the
  exit code is 4 when anything differs.

- `dotfiles/install_dotfiles.sh` follows a link's whole chain before
  trusting it, not only its directory: an alias inside the folder that is
  itself a link to a file outside is reported as a foreign link and
  `--diff` does not print that file. Chains and loops are bounded.

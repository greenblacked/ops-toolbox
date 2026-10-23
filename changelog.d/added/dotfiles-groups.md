- `dotfiles/install_dotfiles.sh --only` takes a group as well as a unit:
  `--only @server` installs what a jump host needs (git, ssh, gnupg and the
  command-line tools, no GUI terminal, no k9s, no Homebrew), and `@shell`,
  `@terminal`, `@git`, `@access`, `@k8s`, `@cloud`, `@scanners` and
  `@packages` cover the rest by role. `--groups` prints the table. An unknown
  group, or one naming a unit that is gone, exits 3 before anything is
  written.

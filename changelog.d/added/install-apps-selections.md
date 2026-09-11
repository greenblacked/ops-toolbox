- `install_apps.sh` grew `--list-casks` and `--list-formulae`, the same
  shape as `install_devtools.sh --list-tools`, both answering before preflight
  so they work on a machine the script refuses to run on. The catalogue adds
  Obsidian and Stats, plus `gh`, `sops`, `age`, `cloud-sql-proxy`, `fzf`,
  `ripgrep`, `fd`, `k6`, `shellcheck` and `hadolint`. Vault and Packer are
  deliberately absent: HashiCorp relicensed them under the BUSL, homebrew-core
  dropped them, and the working spelling is now `hashicorp/tap/vault` — a tap
  this script does not add, so listing them would have been a name nobody can
  install.

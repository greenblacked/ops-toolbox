- `install_apps.sh` grew `--profile core|platform|full` and `--list-profiles`.
  `core` is the day-one machine; `platform` is the lead workstation; `full` is
  the unfiltered catalogue, which remains the default. `--list-casks` and
  `--list-formulae` honour the profile so a runbook can print the subset on a
  machine this script refuses to run on. The catalogue adds Secretive, Ghostty
  and `1password-cli`, plus `glab`, `jfrog-cli`, `gitleaks`, `syft`,
  `kubeconform`, `yamllint`, `rclone`, `direnv`, `actionlint` and `ansible`.

- `install_apps.sh` takes `--profile`, a named subset of the two catalogues for
  the common case of setting a machine up for a role rather than naming forty
  casks by hand. `core` is a day-one machine that can work, `platform` adds the
  Kubernetes, cloud and IaC tools, and `full` is the unfiltered catalogue and
  still the default. `--list-profiles` prints the names and what each is for.
  Both answer before the macOS preflight, as `--list-casks` and `--list-tools`
  do, so a runbook can be written from a Linux box. A profile fills `--only` and
  `--only-formulae` only when they are unset: an explicit selector is an
  instruction and wins. A profile naming an id the catalogue does not have exits
  3 rather than quietly installing less than it says.
- The catalogue gains Secretive and Ghostty as casks, and `glab`, `gitleaks`,
  `syft`, `kubeconform`, `yamllint`, `rclone`, `direnv`, `actionlint` and
  `ansible` as formulae.

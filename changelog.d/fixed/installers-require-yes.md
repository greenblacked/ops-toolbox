- `install_apps.sh` and `install_devtools.sh` refuse a non-interactive
  real run that omitted `--yes`, the same contract `stay_fresh.sh`
  already enforced. Piped stdin used to count as consent and the
  installers proceeded; a preview still does not need `--yes`.

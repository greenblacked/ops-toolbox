- `macos-initial-setup/ops_context.sh` prints on one screen which Kubernetes
  context and namespace, gcloud configuration, AWS profile, Terraform
  workspace, Docker context and GitHub CLI login the current shell is
  pointed at, from local files only. A `--warn-on prod,live` pattern that
  matches any of them is a warning and exits 1, so
  `ops_context.sh --warn-on prod --quiet && terraform apply` is a one-line
  pre-flight against running the right command in the wrong place. It never
  opens `~/.aws/credentials`, names token variables without printing them,
  and flags an expired AWS SSO login and a remote Docker daemon.

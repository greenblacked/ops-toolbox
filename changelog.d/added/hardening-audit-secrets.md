- `macos-initial-setup/hardening_audit.sh` has a `secrets` group for the
  credentials a DevOps laptop keeps on disk: AWS, kubeconfig, Docker,
  `.netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, the GitHub CLI,
  Terraform Cloud and gcloud application-default credentials. A file
  readable by every local user fails and one readable by its group warns,
  each with the `chmod 600` that fixes it. Static AWS keys, base64 registry
  passwords without a credential store, a literal npm token, a `.netrc`
  password and `credential.helper store` are warnings. It names files and
  never prints a value.

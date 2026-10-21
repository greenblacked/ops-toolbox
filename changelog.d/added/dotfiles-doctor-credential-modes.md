- `dotfiles/dotfiles_doctor.sh` checks that the eleven credential files the
  dotfiles package never tracks (`~/.aws/credentials`, `~/.kube/config`, gh
  `hosts.yml`, docker auths, the Terraform login token, `~/.netrc`, argocd,
  jfrog, gcloud and Azure tokens) are private: writable by group or other
  fails, readable warns, and the `chmod 600` is printed rather than run. It
  only stats them, so their contents never reach the report.

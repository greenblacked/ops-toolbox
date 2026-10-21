- The Git Bash aliases have `ctx`, a one-line-per-tool answer to "where will
  the next command land": the Kubernetes context and namespace, the AWS
  profile and region, the gcloud project, the Terraform workspace, the Docker
  context, and the Git branch with its origin host. The same file defines
  `tfaa`, `tfda` and `kdelete`, and nothing showed which cluster, account or
  workspace they would hit. A value that looks like production is marked
  with a trailing `!`, in red on a terminal, and the pattern is yours to set
  in `CTX_DANGER_PATTERN`. It prints names only; exported AWS keys show as
  `static-keys`, never their value. No existing alias changed.

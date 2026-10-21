- The Git Bash aliases have `ctx`, a one-line-per-tool answer to "where will
  the next command land": the Kubernetes context and namespace, the AWS
  profile and region, the gcloud project, the Terraform workspace, the Docker
  context, and the Git branch with its origin host. The same file defines
  `tfaa`, `tfda` and `kdelete`, and nothing showed which cluster, account or
  workspace they would hit. A value that looks like production is marked
  with a trailing `!`, in red on a terminal, and the pattern is yours to set
  in `CTX_DANGER_PATTERN`. With no `AWS_PROFILE` and no exported keys it
  shows the `[default]` profile of the AWS shared files and its region; a
  named `AWS_PROFILE` without `AWS_REGION` gets the region of its
  `[profile NAME]` section. It honours the overrides the tools honour:
  `CLOUDSDK_CORE_PROJECT` and `CLOUDSDK_ACTIVE_CONFIG_NAME` for gcloud,
  `TF_WORKSPACE` (and `default` for an initialised directory with no
  environment file) for Terraform, and `DOCKER_HOST` for Docker.
  It prints names only; exported AWS keys show as `static-keys`, never
  their value. No existing alias changed.

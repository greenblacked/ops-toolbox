- The Runbooks section has a Kubernetes runbook for unhealthy pods. It walks
  `kubectl_pod_diag.sh` and `debug_pod.sh` from a read-only triage to an
  ephemeral debug container, previewed with `--dry-run` first, and says
  which exit code means findings and which means the cluster looks quiet.

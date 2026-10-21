- `k8s-toolbox/kubectl_workload_audit.sh` audits the pod templates of every
  Deployment, StatefulSet, DaemonSet and CronJob for what incident reviews
  keep finding by hand: missing requests or memory limits, no readiness
  probe, untagged or `latest` images, privileged, host-namespace or hostPath
  pods, containers that may run as root, single-replica Deployments and
  replicated workloads no PodDisruptionBudget covers. Findings are labelled
  `[risk]` or `[advice]`, each check prints a fix and never runs it, and
  `--list-checks`, `--only`, `--include-system` and `--limit` work the way
  the GKE doctor's checks do.

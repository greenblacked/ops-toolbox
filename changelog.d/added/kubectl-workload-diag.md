- `k8s-toolbox/kubectl_workload_diag.sh` is the read-only second half of the
  pod triage. It reports what `kubectl_pod_diag.sh` cannot see while every
  pod that exists is healthy: Deployments past their progress deadline,
  paused or short of available replicas, StatefulSets stuck mid-update,
  DaemonSets with unavailable or misscheduled pods, autoscalers that cannot
  read metrics or sit at `maxReplicas`, and failed Jobs. Each finding is
  followed by the `kubectl rollout status` or `kubectl describe` command to
  run next, printed and never executed. `--list-checks` and `--only` pick the
  checks, and it exits `4` when every check ran and found nothing.

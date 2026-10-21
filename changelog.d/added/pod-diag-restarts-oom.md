- `k8s-toolbox/kubectl_pod_diag.sh` reports restart loops and recent OOM
  kills in containers, restartable init-container sidecars included, that are
  Running and Ready again. Before, a container
  OOMKilled five minutes earlier, or one restarting all week, left the run
  saying the cluster looked quiet. The new section reuses the pod listing,
  names the container's memory limit, prints the `kubectl logs --previous`
  command to run next, and never repeats a container the unhealthy-pods
  section already reported. `--restarts` sets the threshold (5 by default)
  and `--since` now bounds the OOM lookback as well as the events.

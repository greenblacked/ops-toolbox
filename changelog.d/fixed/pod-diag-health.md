- `k8s-toolbox/kubectl_pod_diag.sh` reports unready Running containers,
  failing init containers, and unhealthy restartable sidecars, and fetches
  crash logs from the named failing container. Warning lookback uses the latest
  observation before the first event time. Failed queries, malformed JSON,
  and unusable event timestamps report an incomplete check instead of quiet
  health; remaining sections still run. Current container log requests also
  work under Bash 3.2 when there are no optional log flags.

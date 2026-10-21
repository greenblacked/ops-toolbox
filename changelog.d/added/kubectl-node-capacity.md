- `k8s-toolbox/kubectl_node_capacity.sh` sets each node's CPU, memory and
  pod requests against its allocatable, which is what decides whether a pod
  can be scheduled and what `kubectl top` cannot show. Requests are added up
  the way the scheduler does it, init and sidecar containers and pod
  overhead included, and every quantity form the API writes is parsed
  exactly. Nodes at or above `--threshold` (85% by default) or NotReady are
  findings, Unschedulable pods are listed with the scheduler's message, and
  no metrics-server is needed.

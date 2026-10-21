- `k8s-toolbox/kubectl_drain_preflight.sh` answers "can I drain this node?"
  before anything is cordoned. It reports what makes a drain hang or refuse
  (a PodDisruptionBudget allowing no disruption, a pod under two budgets, a
  pod with no controller, no other Ready node to move to) and what a drain
  quietly costs (lost `emptyDir` data, PVC-bound pods, StatefulSet order).
  It then prints the `kubectl cordon` and `kubectl drain` commands with only
  the flags the node needs. It runs neither, exits `4` when the node is safe
  to drain, and gives no verdict at all when a query fails.

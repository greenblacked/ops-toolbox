- `k8s-toolbox/kubectl_drain_preflight.sh` answers "can I drain this
  node?" before anything is cordoned. It reports what makes a drain hang
  or refuse (a PodDisruptionBudget allowing no disruption, a pod under two
  budgets, a pod with no controller, no other Ready node to move to) and
  what a drain quietly costs (lost `emptyDir` data, PVC-bound pods,
  StatefulSet order). It also reports a pod whose `nodeSelector` or
  required `nodeAffinity`, or whose PVC's PersistentVolume `nodeAffinity`
  (a local volume), no other Ready schedulable node satisfies. It then
  prints the `kubectl cordon` and `kubectl drain` commands with only the
  flags the node needs. It runs neither, exits `4` when there is nothing
  to report, never claims the node is safe because placement of evicted
  pods (taints, resources, topology) is not simulated, and gives no
  verdict at all when a query fails.

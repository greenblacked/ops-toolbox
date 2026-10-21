- `k8s-toolbox/kubectl_pod_cleanup.sh` clears the Evicted, OutOfcpu and
  failed Job pods that pile up by the thousand, without the wrong-context
  one-liner. It previews by default: the context, every candidate with its
  reason and age, and the exact `kubectl delete pod` it would run. Only
  `--yes` deletes, and then only those pods, one by one by name, never with
  `--force`, and it re-reads each pod just before the delete, skipping one
  that was recreated under the same name; `--dry-run` always wins. `--older-than` (a day by default) keeps
  recent failures for the post-mortem, `--include-succeeded` adds finished
  pods, and `--max` (200) refuses a larger batch before the first delete.

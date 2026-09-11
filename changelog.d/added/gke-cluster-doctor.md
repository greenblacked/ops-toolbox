- `k8s-toolbox/gke_cluster_doctor.sh` reports a GKE cluster's release
  channel, control-plane vs node-pool skew, Workload Identity, and
  private-cluster flags. It prints the `gcloud` command that would fix
  each finding and never mutates the cluster. `--list-checks` and `--help`
  work before `gcloud` is required.

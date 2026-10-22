- `k8s-toolbox/gke_cluster_doctor.sh` pairs every node pool with its own
  version in the skew check. `gcloud` joins the pool names and the versions
  with `;` inside two tab-separated columns, and splitting the whole line on
  `;` gave a two-pool cluster a pool reported with its neighbour's version
  and a version reported as a pool, so real skew could pass unnoticed.

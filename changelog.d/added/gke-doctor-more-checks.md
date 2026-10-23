- `k8s-toolbox/gke_cluster_doctor.sh` has six more checks, each with the
  `gcloud` command that fixes it: node auto-repair and auto-upgrade
  (`nodepool-mgmt`), a maintenance window (`maintenance`), master authorized
  networks and an open `0.0.0.0/0` block (`authnets`), system and workload
  logging and monitoring (`observability`), shielded nodes (`shielded`), and
  network policy or Dataplane V2 (`dataplane`). They share one JSON describe
  read with `python3`; without it they are skipped with a warning and the
  original four still run. A new suite runs all ten checks against a stubbed
  `gcloud`, which no test did before.

# Kubernetes

## What it covers

`k8s-toolbox/` is a Debian-based, GKE-oriented CLI image (kubectl, helm,
gcloud and related tools), build and run helpers, read-only cluster triage, a
GKE doctor, and an ephemeral debug-container helper. The host scripts are Bash
only.

## Requirements

- Bash on the host.
- `kubectl` for triage and debug; `gcloud` for `gke_cluster_doctor.sh`.
- `python3` for the read-only `kubectl_*` reports, and `openssl` for
  `kubectl_cert_expiry.sh`, which only parses certificates from stdin.
- Docker with buildx for `build.sh` and `run.sh`. Both exit 2 without Docker,
  except under `--dry-run`.
- Credentials for any cluster you query.

## Main scripts

<!-- markdownlint-disable MD033 -->

| Script | Purpose | Preview |
| --- | --- | --- |
| `kubectl_pod_diag.sh` | Triage unhealthy pods, restarts and OOM kills, Warning events and unbound PVCs. | <span class="stage stage-report">read-only</span> |
| `kubectl_workload_diag.sh` | Triage stuck rollouts, DaemonSets, autoscalers and failed Jobs; `--list-checks`, `--only`. | <span class="stage stage-report">read-only</span> |
| `kubectl_cert_expiry.sh` | Expired and expiring TLS certificates in Secrets; `--warn-days`, `--cert-manager`. | <span class="stage stage-report">read-only</span> |
| `gke_cluster_doctor.sh` | GKE health checks; `--list-checks`, `--only`. | <span class="stage stage-report">read-only</span> |
| `build.sh` | Build the toolbox or debug image with buildx. | `--dry-run` |
| `run.sh` | Run the image with `~/.kube` mounted read-only. | `--dry-run` |
| `debug_pod.sh` | Attach an ephemeral debug container with `kubectl debug`. | `--dry-run` |
| `debug/`, `examples/` | Sample manifests, applied by hand with `kubectl apply`. | n/a |

<!-- markdownlint-enable MD033 -->

All paths are under `k8s-toolbox/`.

## Examples

=== "Report"

    ```bash
    ./k8s-toolbox/kubectl_pod_diag.sh --namespace prod
    ./k8s-toolbox/kubectl_pod_diag.sh --context staging -n api
    ./k8s-toolbox/kubectl_pod_diag.sh --since 6h --restarts 10
    ./k8s-toolbox/kubectl_workload_diag.sh --namespace prod --only deployments,hpa
    ./k8s-toolbox/kubectl_cert_expiry.sh --warn-days 14 --cert-manager
    ./k8s-toolbox/gke_cluster_doctor.sh --list-checks
    ./k8s-toolbox/gke_cluster_doctor.sh --project P --cluster C --location europe-west1
    ```

=== "Preview"

    ```bash
    ./k8s-toolbox/build.sh --dry-run
    ./k8s-toolbox/debug_pod.sh --pod api-7d9f8 --dry-run
    ```

=== "Apply"

    ```bash
    ./k8s-toolbox/build.sh
    ./k8s-toolbox/debug_pod.sh --pod api-7d9f8 --namespace prod
    ```

## Limitations and caveats

!!! warning "Check your kube context"
    `kubectl_pod_diag.sh` and `debug_pod.sh` use the current kube context unless
    you pass `--context`. Check it before running.

!!! apply "debug_pod.sh changes a live pod"
    It adds an ephemeral container to an existing pod; it does not create a
    new pod.

- A multi-arch `build.sh --push` is pushed, not loaded locally.
- Toolchain versions are pinned in `versions.env`. The Dockerfile and
  `build.sh` must agree; the contract tests check this.
- The image runs as uid 1000 with a restricted Pod Security posture. `--root`
  is opt-in.
- `gcloud` credentials are not mounted by default. `--gcloud-config` mounts
  them read-only, and is opt-in.
- No test contacts a real cluster; they use stubbed `kubectl` fixtures. The
  image smoke build is opt-in (`K8S_IMAGE_SMOKE=1`) and runs weekly in CI.

## Repository

- [`k8s-toolbox/`](https://github.com/greenblacked/ops-toolbox/tree/master/k8s-toolbox)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/k8s-toolbox/README.md)

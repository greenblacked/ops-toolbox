# k8s-toolbox

A reusable **Kubernetes toolbox container image** intended for:

- interactive debugging (`kubectl exec`, ephemeral containers)
- running one-off diagnostics (DNS/TLS/HTTP/network)
- acting as a safe “entrypoint” image for ad-hoc jobs

This toolbox is **GKE-focused** (includes `gcloud` + `gke-gcloud-auth-plugin`) and ships the common Kubernetes CLIs (`kubectl`, `helm`, `kustomize`).

## What’s inside

- Core: `bash`, `curl`, `git`, `jq`, `yq`, `openssl`, `less`
- K8s: `kubectl`, `helm`, `kustomize`
- GCP: `gcloud`, `gke-gcloud-auth-plugin`
- Network/debug: `dig`/`nslookup` (`dnsutils`), `ip` (`iproute2`)

The image runs as a **non-root** user by default (`toolbox`, uid/gid 1000).

## Build

From repo root:

```bash
./k8s-toolbox/build.sh --tag k8s-toolbox:local
```

Multi-arch build (for pushing to a registry):

```bash
./k8s-toolbox/build.sh --tag gcr.io/YOUR_PROJECT/k8s-toolbox:latest --push
```

## Run locally

Interactive shell with the current directory mounted at `/work`:

```bash
./k8s-toolbox/run.sh --tag k8s-toolbox:local
```

If you want to run as root (sometimes useful for deeper network debugging):

```bash
./k8s-toolbox/run.sh --tag k8s-toolbox:local --root
```

## Use in Kubernetes

See [`examples/`](examples/) for ready-to-apply manifests:

- `examples/pod.yaml`: long-running pod you can `kubectl exec` into
- `examples/job.yaml`: one-off job example

Typical flow:

```bash
kubectl apply -f k8s-toolbox/examples/pod.yaml
kubectl exec -it k8s-toolbox -- bash
```

## GKE auth notes

Inside the container, `kubectl` will authenticate to GKE using the installed
`gke-gcloud-auth-plugin` when your kubeconfig uses the `gcloud` auth flow.

For local runs, `run.sh` can mount your kubeconfig directory read-only so you
get the same contexts as your host.

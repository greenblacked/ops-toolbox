# k8s-toolbox

A container image with the Kubernetes CLIs already in it, plus the scripts that
build it, run it and point it at a cluster.

It exists because the alternative is `kubectl run -it --rm --image=alpine` and
then twenty minutes of `apk add`, on a pod that will be gone before you finish.
This image is GKE-focused — it ships `gcloud` and `gke-gcloud-auth-plugin`, so
a kubeconfig using the `gcloud` auth flow works inside it — and it runs as an
unprivileged user by default.

| File | Purpose |
| --- | --- |
| [`Dockerfile`](Dockerfile) | The image: Debian slim plus the CLIs, every version a build ARG |
| [`versions.env`](versions.env) | The pinned versions, and the only place they are written down |
| [`build.sh`](build.sh) | Build (and optionally push) the image with those pins |
| [`run.sh`](run.sh) | Run it locally with the working directory and your kubeconfig mounted |
| [`kubectl_pod_diag.sh`](kubectl_pod_diag.sh) | Read-only cluster triage: unhealthy pods, warnings, PVCs, node pressure |
| [`debug_pod.sh`](debug_pod.sh) | Attach the image to a running pod as an ephemeral debug container |
| [`examples/`](examples/) | A pod, a job, and a kustomization to retag both |
| [`debug/`](debug/) | A pod, a job, and a kustomization for the debug image tag |
| [`tests/`](tests/) | Contract checks for the four scripts; no image build, no Docker |

## What is inside the image

- Core: `bash`, `curl`, `git`, `jq`, `yq`, `openssl`, `python3`, `less`
- Kubernetes: `kubectl`, `helm`, `kustomize`
- GCP: `gcloud`, `gke-gcloud-auth-plugin`
- Network: `dig`/`nslookup` (`dnsutils`), `ip` and `ss` (`iproute2`)
- Process inspection: `ps`, `top` (`procps`)

The image runs as `toolbox`, uid/gid 1000, with `/work` as the working
directory. Nothing in it needs root, and running as root is the exception you
ask for rather than the default you inherit.

## Pinned versions

Every tool version lives in [`versions.env`](versions.env):

```bash
YQ_VERSION=v4.53.3
KUBECTL_VERSION=v1.36.3
HELM_VERSION=v4.2.3
KUSTOMIZE_VERSION=v5.8.1
GCLOUD_VERSION=579.0.0
```

`build.sh` sources that file and passes each value as a `--build-arg`; the
Dockerfile declares a matching `ARG` and **asserts the version it actually
installed** after each download, so a moved release or a redirected URL fails
the build instead of quietly shipping something else. The k8s suite checks that
the three lists agree — a version added to `versions.env` but never declared as
an `ARG` is a pin with no effect, which is worse than no pin at all.

Bumping one is a deliberate commit. That is the same rule the RouterOS CHR
image and the CI toolchain follow: a release on somebody else's schedule should
not turn a green repository red.

The Google Cloud SDK is installed from its versioned tarball rather than from
`curl … | bash`. The convenience installer always fetches the current release,
which would make the `GCLOUD_VERSION` pin decorative.

## Build

```bash
./build.sh --dry-run                          # print the buildx command, run nothing
./build.sh                                    # k8s-toolbox:local, for this machine
./build.sh --pull                             # resolve/pull the pinned base instead of cache
./build.sh --tag REGISTRY/k8s-toolbox:1.2.3 --push
./build.sh --variant debug                    # k8s-toolbox:debug
./build.sh --dry-run --variant debug
./build.sh --variant debug --tag REGISTRY/k8s-toolbox:1.2.3-debug --push
```

Without `--push` the build is single-platform (the first entry of
`--platform`, `linux/amd64` by default) and `--load`ed into the local daemon,
because a multi-arch build cannot be loaded there — only pushed. `--push` does
build all the platforms.

The build context is the `k8s-toolbox/` directory, and
[`.dockerignore`](.dockerignore) reduces it to two files: the Dockerfile copies
nothing, so there is no reason to upload the tests and the README to the daemon
on every build.

## Debug image

`build.sh --variant debug` builds a second stage on top of the default image.
It adds `htop`, `iperf3`, `ping`, `lsof`, `ltrace`, `mtr`, `nc`, `socat`,
`strace`, `tcpdump` and `traceroute` as unpinned Debian packages on purpose —
the default image keeps its pinned CLIs; these are optional in-pod tools whose
versions track the base image's apt archive, not a separate release schedule.

```bash
./run.sh --tag k8s-toolbox:debug
./debug_pod.sh --pod api-7d9f8 --image k8s-toolbox:debug
kubectl apply -f debug/pod.yaml
```

[`debug/`](debug/) holds a long-running pod, a one-off job, and a kustomization
to retag both. The manifests add `NET_RAW`, `NET_ADMIN` and `SYS_PTRACE` so
`tcpdump`, `ping`, `strace` and `ltrace` can run; they do **not** pass the
restricted Pod Security Standard. The default image and [`examples/`](examples/)
stay restricted.

There is no new switch on the run scripts: `run.sh` takes the existing `--tag`
flag and `debug_pod.sh` takes the existing `--image` flag.

## Run it locally

```bash
./run.sh                                      # bash in k8s-toolbox:local
./run.sh -- kubectl get pods -A               # one command, then exit
./run.sh --root                               # uid 0, for lower-level network work
./run.sh --no-kubeconfig                      # no cluster access at all
./run.sh --no-tty -- kubectl get pods -A       # automation without a TTY
./run.sh --gcloud-config "$HOME/.config/gcloud" # opt-in GKE auth; host stays read-only
./run.sh --dry-run                            # print the docker run command
```

The current directory is mounted at `/work`, and `~/.kube` is mounted read-only
so you get the same contexts as the host. Read-only is deliberate: a container
you are debugging in should not be able to rewrite the credentials of the
cluster you are debugging.

GKE kubeconfigs usually invoke `gke-gcloud-auth-plugin`, which in turn needs
gcloud credentials. Those are deliberately not mounted by default. Pass
`--gcloud-config DIR` to opt in. The host directory is mounted read-only at a
staging path, copied into a mode-0700 container `tmpfs`, and that writable,
ephemeral copy becomes `CLOUDSDK_CONFIG`. Token refreshes and gcloud logs work
without ever writing through to the host credentials. The staging wrapper
starts as root so mode-0600 host files can be read, then drops back to the
`toolbox` user unless `--root` was explicit.

The mount point follows the user. Under `--root` the kubeconfig goes to
`/root/.kube` rather than `/home/toolbox/.kube`, because uid 0's `$HOME` is
`/root` and a kubeconfig mounted where the running user will not look for it is
just a confusing "connection refused".

## Triage a cluster

`kubectl_pod_diag.sh` is read-only. It never patches, deletes or restarts
anything — it answers "what is unhappy here" in one pass:

```bash
./kubectl_pod_diag.sh                         # every namespace
./kubectl_pod_diag.sh --namespace prod
./kubectl_pod_diag.sh --context staging -n api
./kubectl_pod_diag.sh --since 30m             # event lookback; also accepts h/d
./kubectl_pod_diag.sh -A                      # back to every namespace explicitly
```

`-A` / `--all-namespaces` is the default and only needs stating to undo an
earlier `--namespace` in a wrapper or an alias.

It reports, in order:

- pods that are neither Running nor Succeeded, plus Running pods whose
  containers are in `CrashLoopBackOff`, `ImagePullBackOff` or `ErrImagePull` —
  a pod can be "Running" and completely broken
- `Warning` events from the configured `--since` lookback (one hour by
  default), truncated to something readable
- PVCs that are not `Bound`
- nodes reporting memory, disk or PID pressure, or not `Ready`

For a pod in `CrashLoopBackOff` it also prints the last 40 lines of the
*previous* container's logs, which is where the reason for the crash is — the
current container has usually not got far enough to say anything.

Exit code `4` means nothing was found. That is distinct from `0` (findings
reported) on purpose, so it can drive a scheduled check without parsing output.
Exit `2` covers both halves of the environment this script needs: no `kubectl`,
and no `python3` — the JSON from each `kubectl get` is reduced by a
standard-library `python3 -c` filter.

## Debug a running pod

`debug_pod.sh` wraps `kubectl debug` with this image, which attaches an
ephemeral container to a pod that is already running:

```bash
./debug_pod.sh --pod api-7d9f8 --namespace prod
./debug_pod.sh --pod api-7d9f8 --target api          # share the app's process namespace
./debug_pod.sh --pod api-7d9f8 --image REGISTRY/k8s-toolbox:1.2.3
./debug_pod.sh --pod api-7d9f8 --no-tty -- sh -c 'id; ps aux' # one-shot command
./debug_pod.sh --pod api-7d9f8 --dry-run             # print the kubectl command
```

This is the tool for a distroless or scratch container that has no shell of its
own: the ephemeral container brings its own userspace and joins the pod, so the
application keeps running and nothing about it is modified. `--target` shares
the process namespace of a named container, which is what makes the
application's processes and `/proc` visible.
Everything after `--` replaces the default `bash`, so a minimal image can use
`sh`. Add `--no-tty` for one-shot probes and automation; without it the wrapper
preserves its interactive `-it` behavior for troubleshooting sessions.

The image has to be reachable from the *cluster*, so `k8s-toolbox:local` only
works where the nodes can see your local daemon — kind, minikube or Docker
Desktop. Anywhere else, push it and pass `--image`.

## Use it in a cluster

[`examples/`](examples/) holds a long-running pod to exec into, a one-off job
that prints the toolchain versions, and a kustomization that retags both:

```bash
kubectl apply -f examples/pod.yaml
kubectl exec -it k8s-toolbox -- bash
kubectl delete pod k8s-toolbox
```

Both manifests are written to pass the **restricted** Pod Security Standard
unchanged, because an example is what gets copied: non-root with an explicit
uid, `allowPrivilegeEscalation: false`, all capabilities dropped, the
`RuntimeDefault` seccomp profile, and requests and limits set. They also set
`automountServiceAccountToken: false` — a debugging shell that can reach the
API server as the namespace default service account is a larger hole than
whatever it was opened to investigate. Mount a token deliberately if you need
`kubectl` from inside the pod.

`readOnlyRootFilesystem` is the one restricted-profile nicety left off, and it
is not part of that standard: `gcloud` writes to its configuration directory on
first use, and a toolbox that cannot run `gcloud auth` is not a toolbox. Mount
an `emptyDir` over `~/.config` and turn it on if your policy requires it.

To point the examples at a real registry, use the kustomization rather than
editing them:

```bash
cd examples
kustomize edit set image k8s-toolbox:local=REGISTRY/k8s-toolbox:1.2.3
kubectl apply -k .
```

## GKE auth

Inside the container, `kubectl` authenticates to GKE through the installed
`gke-gcloud-auth-plugin` whenever your kubeconfig uses the `gcloud` auth flow.
Mounting `~/.kube` gets you the contexts; the credentials the plugin needs come
from `gcloud auth application-default login` or a mounted service-account key.

## Conventions

The four scripts follow the same rules as everything else in this repository:

- `--help` works before any preflight check, so it answers on a machine with
  neither Docker nor `kubectl` installed.
- An unrecognised flag exits `3`, and so does a flag given no value —
  `--tag --push` is a usage error, not a build tagged `--push`.
- A dry run writes nothing, and does not need the tool it is previewing. There
  is no reason `./build.sh --dry-run` should require Docker to print a command.
- Exit codes: `0` success, `1` the work ran and failed, `2` wrong environment
  (no Docker, no `kubectl`, no reachable cluster), `3` usage, `4` nothing to
  report.
- `NO_COLOR` is honoured, and `err()` writes to stderr.

They also use `set -euo pipefail`, like the short single-purpose scripts in
[`git/`](../git/), and pin every toolchain version in
[`versions.env`](versions.env) so a release on somebody else's schedule cannot
turn this repository red.
[`CONTRIBUTING.md`](../CONTRIBUTING.md) has the shell rules in full.

## Tests

```bash
./run-tests.sh k8s          # from the repository root
./tests/run.sh              # or directly
```

Contract checks, and no image build: five pinned toolchains fetched from five
hosts is minutes of network per run, and what actually regresses is the scripts
that drive the build. The suite covers `bash -n` and ShellCheck where it is
installed, the `--help` and unknown-flag contracts, flags that require a value,
the dry-run promise **asserted against the filesystem** rather than against the
script's own claim to have written nothing, exit `2` when `kubectl` or Docker
is missing, agreement between `versions.env`, the Dockerfile and `build.sh`,
and the Pod Security posture of the examples.

To build the image and probe it for real:

```bash
K8S_IMAGE_SMOKE=1 ./run-tests.sh k8s
```

That builds `k8s-toolbox:ci-smoke` for `linux/amd64` and asserts the container
runs as uid 1000 with every CLI on `PATH`. It needs Docker and network, which
is why it is opt-in locally and runs in the scheduled
[`Kubernetes image smoke`](../.github/workflows/k8s-image-smoke.yml) workflow
every Monday at 04:17 UTC (plus manual dispatch), rather than on every pull
request. Downloads retry transient network errors before the build fails.

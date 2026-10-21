# Kubernetes toolbox

[Ops Toolbox](../README.md) / **Kubernetes toolbox**

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
| [`kubectl_pod_diag.sh`](kubectl_pod_diag.sh) | Read-only cluster triage: unhealthy pods, OOM kills and restart loops, warnings, PVCs, node pressure |
| [`kubectl_workload_diag.sh`](kubectl_workload_diag.sh) | Read-only workload triage: stuck rollouts, DaemonSets, autoscalers, failed Jobs |
| [`kubectl_cert_expiry.sh`](kubectl_cert_expiry.sh) | Read-only report of expired and expiring TLS certificates in Secrets and cert-manager |
| [`kubectl_drain_preflight.sh`](kubectl_drain_preflight.sh) | Read-only check of what would block or hurt a node drain; prints the drain command |
| [`kubectl_node_capacity.sh`](kubectl_node_capacity.sh) | Read-only per-node CPU, memory and pod requests against allocatable, plus Unschedulable pods |
| [`kubectl_workload_audit.sh`](kubectl_workload_audit.sh) | Read-only pod-template audit: requests and limits, probes, image tags, security context, PDBs |
| [`kubectl_rbac_audit.sh`](kubectl_rbac_audit.sh) | Read-only RBAC review: cluster-admin, wildcards, default ServiceAccounts, dangling bindings, Secret readers |
| [`gke_cluster_doctor.sh`](gke_cluster_doctor.sh) | Read-only GKE report: release channel, version skew, Workload Identity, private cluster, node management, maintenance window, authorized networks, observability, shielded nodes, network policy |
| [`kubectl_pod_cleanup.sh`](kubectl_pod_cleanup.sh) | Preview, then with `--yes` delete, Failed (and optionally Succeeded) pods past a grace period |
| [`debug_pod.sh`](debug_pod.sh) | Attach the image to a running pod as an ephemeral debug container |
| [`examples/`](examples/) | A pod, a job, and a kustomization to retag both |
| [`debug/`](debug/) | A pod, a job, and a kustomization for the debug image tag |
| [`tests/`](tests/) | Contract checks and stubbed-cluster tests for every script; no image build, no Docker |

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What is inside the image](#what-is-inside-the-image)
- [Pinned versions](#pinned-versions)
- [Build](#build)
- [Debug image](#debug-image)
- [Run it locally](#run-it-locally)
- [Triage a cluster](#triage-a-cluster)
- [Triage workloads](#triage-workloads)
- [Check certificate expiry](#check-certificate-expiry)
- [Check a node before draining](#check-a-node-before-draining)
- [Check node capacity](#check-node-capacity)
- [Audit workloads](#audit-workloads)
- [Audit RBAC](#audit-rbac)
- [Clean up dead pods](#clean-up-dead-pods)
- [Debug a running pod](#debug-a-running-pod)
- [Use it in a cluster](#use-it-in-a-cluster)
- [GKE auth](#gke-auth)
- [Conventions](#conventions)
- [Tests](#tests)

## Requirements

Nothing here needs all of these at once — each script states which of them it
needs, and exits `2` rather than half-working when one is missing.

| Requirement | Needed by | Notes |
| --- | --- | --- |
| **Bash** | every script | `#!/usr/bin/env bash` with `set -euo pipefail`. |
| **Docker with `buildx`** | [`build.sh`](build.sh), [`run.sh`](run.sh) | `build.sh` invokes `docker buildx build`; `run.sh` invokes `docker run`. Both exit `2` without Docker — except under `--dry-run`, which prints the command it would have run and warns instead. |
| **`kubectl`** | [`kubectl_pod_diag.sh`](kubectl_pod_diag.sh), [`kubectl_workload_diag.sh`](kubectl_workload_diag.sh), [`kubectl_cert_expiry.sh`](kubectl_cert_expiry.sh), [`kubectl_drain_preflight.sh`](kubectl_drain_preflight.sh), [`kubectl_node_capacity.sh`](kubectl_node_capacity.sh), [`kubectl_workload_audit.sh`](kubectl_workload_audit.sh), [`kubectl_rbac_audit.sh`](kubectl_rbac_audit.sh), [`kubectl_pod_cleanup.sh`](kubectl_pod_cleanup.sh), [`debug_pod.sh`](debug_pod.sh) | Plus a kubeconfig with a context that reaches the cluster. `debug_pod.sh` wraps `kubectl debug`, so the image it attaches must be reachable from the *cluster* — `k8s-toolbox:local` only works where the nodes can see your local daemon. |
| **`python3`** | [`gke_cluster_doctor.sh`](gke_cluster_doctor.sh) (six of its ten checks), [`kubectl_pod_diag.sh`](kubectl_pod_diag.sh), [`kubectl_workload_diag.sh`](kubectl_workload_diag.sh), [`kubectl_cert_expiry.sh`](kubectl_cert_expiry.sh), [`kubectl_drain_preflight.sh`](kubectl_drain_preflight.sh), [`kubectl_node_capacity.sh`](kubectl_node_capacity.sh), [`kubectl_workload_audit.sh`](kubectl_workload_audit.sh), [`kubectl_rbac_audit.sh`](kubectl_rbac_audit.sh), [`kubectl_pod_cleanup.sh`](kubectl_pod_cleanup.sh) | Standard library only: the JSON from each `kubectl get` is reduced by an inline `python3 -c` filter. The macOS system interpreter (3.9) is enough. |
| **`openssl`** | [`kubectl_cert_expiry.sh`](kubectl_cert_expiry.sh) | Only to read a certificate's end date from stdin (`openssl x509 -noout -enddate`); no network use. OpenSSL and LibreSSL both work. |
| **`kustomize`** | [`examples/`](examples/), [`debug/`](debug/) | Optional, and only to retag the manifests with `kustomize edit set image`. |

The image itself is Debian bookworm-slim, and the CLI versions it installs are
pinned in [`versions.env`](versions.env) — see [Pinned versions](#pinned-versions).

## Quick start

The read-only scripts look at a cluster and change nothing, so they are the
ones to try first. None of them needs the image built.

Find out what is unhappy in a cluster, in one read-only pass:

```bash
./kubectl_pod_diag.sh
```

It reports unhealthy pods and containers, recent OOM kills and restart loops,
recent `Warning` events, unbound PVCs, and nodes under pressure. Running pods with unready containers, failing init
containers, and unhealthy restartable sidecars are findings too. For a crashing
container it fetches that named container's logs. It exits `4` when every check
completed and found nothing, distinct from `0` for findings and `1` for an
incomplete check, so it can drive a scheduled check without parsing its output.

Then build the image the rest of the package is about:

```bash
./build.sh --dry-run    # print the buildx command, run nothing
./build.sh              # k8s-toolbox:local, for this machine
./run.sh                # a bash shell in it, with $PWD at /work and ~/.kube read-only
```

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
./kubectl_pod_diag.sh --restarts 10           # restart-loop threshold (default 5)
./kubectl_pod_diag.sh -A                      # back to every namespace explicitly
```

`-A` / `--all-namespaces` is the default and only needs stating to undo an
earlier `--namespace` in a wrapper or an alias.

It reports, in order:

- pods that are neither Running nor Succeeded, plus waiting, failed, or unready
  regular containers, failing init containers, and unhealthy restartable
  sidecars; completed init containers and healthy Running/Succeeded pods stay
  quiet
- containers (restartable init-container sidecars included) that are Running and Ready again but were `OOMKilled` within the
  `--since` lookback, or have restarted at least `--restarts` times (5 by
  default), with the container's memory limit and a printed
  `kubectl logs ... --previous` to run next. This reuses the pod listing, so
  it costs no extra API call; a container already reported above is never
  repeated here, and a failed pod listing is counted once
- `Warning` events from the configured `--since` lookback (one hour by
  default), truncated to something readable
- PVCs that are not `Bound`
- nodes reporting memory, disk or PID pressure, or not `Ready`

For each container in `CrashLoopBackOff` it prints the last 40 lines of that
named container's *previous* logs. For a container terminated with a nonzero
exit code it fetches its current logs, including failed init containers. Every
log request specifies the container, so a healthy sibling cannot supply the
crash evidence by accident. Missing logs are reported alongside the finding.

Warning lookback uses the first usable timestamp in this order:
`series.lastObservedTime`, `lastTimestamp`, `deprecatedLastTimestamp`,
`eventTime`, then `metadata.creationTimestamp`. A fresh repetition therefore
remains visible even when its first occurrence is old. Invalid timestamps fall
back to the next field; an event with no usable timestamp makes the check
incomplete.

Exit code `4` means every query and JSON filter succeeded and nothing was found.
That is distinct from `0` (findings reported) on purpose, so it can drive a
scheduled check without parsing output. Failed queries, empty responses, and
invalid JSON produce a section diagnostic and exit `1` after the remaining
checks finish, even when other checks found problems. Incomplete checks never
print the final "cluster looks quiet" summary.
Exit `2` covers both halves of the environment this script needs: no `kubectl`,
and no `python3` — the JSON from each `kubectl get` is reduced by a
standard-library `python3 -c` filter.

## Triage workloads

`kubectl_workload_diag.sh` is the other half of the pod triage, and just as
read-only. A rollout can be stuck while every pod that exists is healthy, so
`kubectl_pod_diag.sh` cannot see it; this looks at the controllers instead:

```bash
./kubectl_workload_diag.sh                    # every namespace, every check
./kubectl_workload_diag.sh --namespace prod
./kubectl_workload_diag.sh --list-checks      # deployments statefulsets daemonsets hpa jobs
./kubectl_workload_diag.sh --only hpa,jobs
```

Each check is one `kubectl get <kind> -o json`, so a missing `list` permission
on one kind costs that section only. What counts as a finding:

- `deployments`: `ProgressDeadlineExceeded` (or `Progressing=False`), a paused
  rollout, a spec generation the controller has not observed yet, or fewer
  available replicas than requested. A Deployment scaled to zero is skipped.
- `statefulsets`: fewer ready replicas than requested, or an update whose new
  revision has not reached every replica it should: with a `partition`, that
  is `replicas - partition` replicas, so a deliberate hold stays quiet but a
  partitioned update that has not moved is still reported. An `OnDelete`
  StatefulSet is never judged on its rollout.
- `daemonsets`: unavailable or not-ready pods, and pods scheduled where the
  DaemonSet no longer wants them (misscheduled).
- `hpa`: `ScalingActive=False` (for example `FailedGetResourceMetric`, with the
  first 100 characters of the message), `AbleToScale=False`, or
  `currentReplicas` at `maxReplicas`. `ScalingDisabled`, which an autoscaler
  reports while its target is scaled to zero, is not a fault.
- `jobs`: a `Failed` condition such as `BackoffLimitExceeded` or
  `DeadlineExceeded`. Completed Jobs and Jobs already being deleted are skipped.

Every finding is followed by a `next` line, for example
`kubectl rollout status deployment/api -n prod`,
`kubectl rollout undo deployment/api -n prod` or
`kubectl describe hpa web -n prod`. It is printed and never run: the only
commands this script executes are `kubectl cluster-info` and `kubectl get`.
With `--context`, the printed command names the same context.

Exit codes match the pod triage: `0` findings, `1` a query or JSON filter
failed (the remaining checks still run, and "workloads look quiet" is never
printed), `2` no `kubectl` or `python3`, or no reachable cluster, `3` usage,
including an unknown id or an empty selection in `--only`, and `4` every
selected check ran and found nothing. `--list-checks` and `--help` answer
before `kubectl` is required.

## Check certificate expiry

`kubectl_cert_expiry.sh` answers "which TLS certificate in this cluster
expires next" without changing anything:

```bash
./kubectl_cert_expiry.sh                      # every namespace, 30-day window
./kubectl_cert_expiry.sh --namespace prod --warn-days 14
./kubectl_cert_expiry.sh --cert-manager       # also read cert-manager Certificates
```

It lists Secrets of type `kubernetes.io/tls`, decodes each `tls.crt` and asks
`openssl x509 -noout -enddate` for the end date of the first certificate in
it. Expired and expiring certificates are printed soonest first, for example
`secret prod/web-tls: EXPIRING in 12d (2026-11-02)` or
`EXPIRED 3d ago`, each with a printed command to inspect the certificate.
A Secret whose `tls.crt` is missing, not base64 or not a certificate is
reported as `UNREADABLE`: a broken Secret is a finding, never a silent skip.
Certificates outside the window are only counted, in a closing
`checked N certificate(s), M within W days` line.

Only the public certificate is read. The listing is piped from `kubectl`
straight into the filter, so no Secret lands in a shell variable, a file or
the output, and `tls.key` is never decoded, printed or passed to `openssl`.
The suite holds it to that with a canary key.

`--cert-manager` adds one `kubectl get certificates.cert-manager.io` and
reports each Certificate's `notAfter` (with its `renewalTime`) and any
Certificate whose `Ready` condition is `False`, with its message. It is opt-in
because the CRD is not in every cluster; when it is asked for and the listing
fails, the run is incomplete like any other failed query.

It needs `list` permission on Secrets. A `Forbidden` is reported as
`could not list TLS secrets` and exit `1`, never as a clean bill of health.
Exit codes: `0` expired, expiring or unreadable certificates found, `1` a
query or JSON filter failed, `2` no `kubectl`, `python3` or `openssl`, or no
reachable cluster, `3` usage (`--warn-days` must be a whole number, 1 or
more), and `4` nothing ends within the window, so it can run from cron.

## Check a node before draining

`kubectl_drain_preflight.sh` answers "can I drain this node?" before anything
is cordoned. It never cordons, drains, evicts or deletes; it prints the
commands that would:

```bash
./kubectl_drain_preflight.sh --node gke-pool-1-abcd
./kubectl_drain_preflight.sh --node gke-pool-1-abcd --context prod
```

It reads the node, the pods scheduled on it, every PodDisruptionBudget and the
other nodes, then reports:

- **BLOCKER** lines, for what makes `kubectl drain` hang or refuse: a pod
  covered by a PodDisruptionBudget whose `disruptionsAllowed` is `0` (the
  eviction is retried until the timeout; a pod that is not Ready is let go
  when the budget sets `unhealthyPodEvictionPolicy: AlwaysAllow`), a pod
  covered by more than one
  budget (the eviction API refuses it), a pod with no controller (drain
  refuses it without `--force`, and nothing would recreate it), and no other
  node that is Ready and schedulable when there are pods to move.
- **NOTE** lines, for what a drain does that is easy to regret: an `emptyDir`
  volume whose data is lost (`--delete-emptydir-data`), a pod bound to a PVC
  that can only restart where its volume can attach (a zonal disk stays in
  its zone), and StatefulSet pods, which come back one at a time under the
  same name.

Budget selectors are matched the way the API matches them: `matchLabels` and
the `In`, `NotIn`, `Exists` and `DoesNotExist` expressions, in the pod's own
namespace, with an empty selector matching every pod there.
`status.disruptionsAllowed` is taken as the answer, so `minAvailable` and
`maxUnavailable` need no arithmetic here. DaemonSet pods, static (mirror)
pods and finished pods are counted and left out, as `kubectl drain
--ignore-daemonsets` leaves them, so a node running only those is safe.

The closing lines are `kubectl cordon NODE` and a `kubectl drain NODE
--ignore-daemonsets --timeout=300s` with `--delete-emptydir-data` or `--force`
added only when a finding needs it, and a warning that `--force` deletes the
pods with no controller for good. Both are printed, never run, and name the
`--context` that was read.

Exit codes: `0` blockers or notes reported, `1` a query or JSON filter failed,
in which case there is no verdict and no command to paste, `2` no `kubectl` or
`python3`, or no reachable cluster, `3` usage (`--node` is required), and `4`
nothing to report: safe to drain.

## Check node capacity

`kubectl_node_capacity.sh` answers "why is this pod Pending?" and "is there
room for the next rollout?" from requests, not usage, so it needs no
metrics-server:

```bash
./kubectl_node_capacity.sh                    # threshold 85%
./kubectl_node_capacity.sh --threshold 70 --context prod
```

One `kubectl get nodes` and one `kubectl get pods --all-namespaces` feed a
table with one row per node: CPU and memory requested against allocatable,
pods against the node's pod limit, each with a percentage, and flags for
`NotReady`, `cordoned` and taints (`key:effect`). A pod counts once it has a
node and until it has finished, with its request worked out the way the
scheduler does it: the larger of the app containers plus restartable
(sidecar) init containers, or each ordinary init container plus the sidecars
started before it, and then pod `overhead` on top; requests set on the
pod itself (`spec.resources.requests`) replace that sum for each resource
they name. Every quantity form the API
writes is parsed exactly (`250m`, `0.5`, `1500Mi`, `2Gi`, `1G`, `129e6`,
`100k` and the rest); an unparsable one makes the run incomplete rather than
guessing.

A node at or above `--threshold` (1-100, default 85) on CPU, memory or pods,
or one that is `NotReady`, is a finding. Cordoned and tainted nodes are
flagged in the table but are not findings on their own. Below the table come
the totals for schedulable, Ready nodes, a count of scheduled pods that
declare no CPU or memory request (the scheduler treats them as free, so the
totals understate them), and a `Pending` section listing every pod marked
`Unschedulable`, with the scheduler's message. These numbers are what the
scheduler reserves, not what the containers use; `kubectl top` answers that
other question.

Exit codes: `0` findings, `1` a query or JSON filter failed, `2` no `kubectl`
or `python3`, or no reachable cluster, `3` usage, and `4` no node at or above
the threshold and nothing pending.

## Audit workloads

`kubectl_workload_audit.sh` is a read-only "is this production-ready?" lint
over the pod templates of every Deployment, StatefulSet, DaemonSet and
CronJob. It has the same shape as the GKE doctor: stable check ids, `--only`,
and a fix printed for every check, never run.

```bash
./kubectl_workload_audit.sh                   # every namespace, every check
./kubectl_workload_audit.sh --namespace prod --only resources,security
./kubectl_workload_audit.sh --list-checks
./kubectl_workload_audit.sh --include-system --limit 100
```

| Check | Reports | Label |
| --- | --- | --- |
| `resources` | A container with no CPU or memory request, or no memory limit. A limit with no request counts as a request, because the API sets one from the other. CPU limits are not asked for: they throttle a container that has spare CPU next to it, while a missing memory limit lets one container take the node's memory. | `[risk]` when the memory limit is missing, otherwise `[advice]` |
| `probes` | A Deployment or StatefulSet container with no `readinessProbe`. DaemonSets and CronJobs are exempt. | `[advice]` |
| `image-tag` | An image with no tag and no `@sha256` digest, or tagged `latest`, init containers included. A registry port (`registry:5000/app`) is not mistaken for a tag. | `[advice]` |
| `security` | `privileged`, `hostNetwork`, `hostPID`, `hostIPC` or a `hostPath` volume; a container whose `allowPrivilegeEscalation` is not explicitly `false`, or with `runAsNonRoot` set at neither pod nor container level. | `[risk]` for privileged, host namespaces and `hostPath`, otherwise `[advice]` |
| `availability` | A Deployment with one replica, and a Deployment or StatefulSet with two or more that no PodDisruptionBudget in its namespace selects (`matchLabels` and `matchExpressions`, as the API matches them). | `[advice]` |

Findings read like
`[risk] deployment prod/api: container web has no memory limit`, so a CI
wrapper can grep for `[risk]`. Each check ends with one `fix` line for its
first finding, for example
`kubectl set resources deployment/api -n prod -c web --requests=cpu=100m,memory=128Mi --limits=memory=256Mi`
(the values are placeholders to size from real usage), `kubectl set image`,
`kubectl scale`, or a `kubectl create poddisruptionbudget ... --dry-run=client
-o yaml` that only prints a manifest. With `--context` the printed command
names the same context.

Only the kinds a selected check reads are listed, one `kubectl get` per kind,
and PodDisruptionBudgets only for `availability`. `kube-system`,
`kube-public`, `kube-node-lease` and namespaces starting `gke-` or `gmp-` are
skipped unless `--include-system` is given, so managed components do not drown
out your own workloads. `--limit N` (default 40) caps the rows per check and
says how many more there were; the hidden ones still count. The audit reads
images, probes, resources, security contexts and volume types only: it never
reads Secrets or environment variable values.

Exit codes: `0` findings, `1` a query or JSON filter failed, `2` no `kubectl`
or `python3`, or no reachable cluster, `3` usage, including an unknown id or
an empty selection in `--only` and a `--limit` that is not a positive whole
number, and `4` nothing to report. `--list-checks` and `--help` answer before
`kubectl` is required.

## Audit RBAC

`kubectl_rbac_audit.sh` answers the four questions every access review asks,
read-only and without `kubectl auth can-i` (which impersonates):

```bash
./kubectl_rbac_audit.sh                       # every check
./kubectl_rbac_audit.sh --only cluster-admin,secrets
./kubectl_rbac_audit.sh --namespace prod      # Roles and RoleBindings in prod only
./kubectl_rbac_audit.sh --list-checks
```

| Check | Reports |
| --- | --- |
| `cluster-admin` | Every ClusterRoleBinding or RoleBinding to `cluster-admin`, one row per subject: `ServiceAccount ns/name`, `User`, or `Group`. |
| `wildcard` | A ClusterRole or Role with a `*` in any rule dimension (`verbs`, `resources`, `apiGroups` or `nonResourceURLs`), or the `escalate`, `bind` or `impersonate` verbs. Verb `*` on resource or API group `*`, and the escalation verbs, are `[risk]` in a ClusterRole; a `*` in a single dimension is `[advice]`. |
| `default-sa` | A binding whose subject is a ServiceAccount named `default`, which every pod without its own `serviceAccountName` inherits. |
| `dangling` | A binding whose ClusterRole does not exist, or whose Role does not exist in the binding's own namespace (a Role of that name elsewhere does not count). |
| `secrets` | A bound role that can `get`, `list` or `watch` core Secrets (or `*`), with the bindings that grant it. A grant narrowed by `resourceNames` is still listed, with the names. |

ClusterRoles and ClusterRoleBindings are always read cluster-wide;
`--namespace` narrows Roles and RoleBindings only. Only the objects the
selected checks need are listed. Rows are labelled `[risk]` when the grant is
cluster-wide and `[advice]` when it is one namespace, for example
`[risk] clusterrolebinding ci-deployer -> cluster-admin: ServiceAccount ci/deployer`,
and each is followed by a `next` line such as
`kubectl describe clusterrolebinding ci-deployer`. For a dangling binding the
next step includes the `kubectl delete` that removes it: printed, never run.
Each check prints at most 40 rows and says how many more there were.

Objects and subjects whose names start with `system:` (such as the
`system:masters` group) and the built-in `cluster-admin`, `admin`, `edit` and
`view` roles are not judged unless `--include-system` is given, so the report
shows what someone added. A `Forbidden` on any RBAC listing is itself worth
knowing and makes the run incomplete (exit `1`). The script reads RBAC objects
only, never a Secret or a token.

Exit codes: `0` findings, `1` a query or JSON filter failed, `2` no `kubectl`
or `python3`, or no reachable cluster, `3` usage, including an unknown id or
an empty selection in `--only`, and `4` nothing to report.

## Clean up dead pods

`kubectl_pod_cleanup.sh` is the one script here that deletes anything, so it
previews by default. Evicted, `OutOfcpu`, `NodeAffinity` and failed Job pods
pile up by the thousand, and the usual one-line fix is a delete with a field
selector that is easy to run against the wrong context. This lists exactly
what it would remove, names the context first, and deletes only with `--yes`:

```bash
./kubectl_pod_cleanup.sh                      # preview: Failed pods older than 1d, every namespace
./kubectl_pod_cleanup.sh --namespace batch --older-than 2h
./kubectl_pod_cleanup.sh --include-succeeded  # Succeeded pods too
./kubectl_pod_cleanup.sh --yes                # delete what the preview listed
./kubectl_pod_cleanup.sh --yes --dry-run      # --dry-run wins: still a preview
```

Candidates come from one `kubectl get pods`, filtered here rather than by a
field selector: phase `Failed` (and `Succeeded` with `--include-succeeded`),
not already being deleted, and last active (the newest of start time, any
container's finish time, and creation) longer ago than `--older-than` (`1d` by
default, because a failed pod is post-mortem evidence). Running, Pending and
terminating pods are never candidates. The preview prints the context, the
scope, each candidate with its reason (for example `Failed (Evicted)`) and
age, then one pasteable `dry-run: would run: printf %s '<DeleteOptions JSON>' |
kubectl delete --raw /api/v1/namespaces/NS/pods/NAME -f -` line per pod (the
JSON carries the uid it will require) and `dry-run complete; no changes written`.

With `--yes`, it deletes those pods and no others, one call per pod by name and
namespace: never a selector, never `--force`, never `--grace-period=0`. Each pod
is re-read just before its delete and skipped (reported, not an error) if it is
no longer in its listed phase or its uid changed. The delete itself is a
`kubectl delete --raw` with a `DeleteOptions` body that carries the listed uid as
a precondition, so a pod recreated under the same name after that re-read is
refused by the API server (409 Conflict) and reported as skipped, never deleted. A pod
already gone by then counts as done; any other failure is reported and the
rest still run. `--max N` (default 200) caps the blast radius: more matches
than that is exit `3` before anything is deleted, and the preview stops with
the same message, so it never promises what `--yes` would refuse.

A preview writes nothing and still answers without `kubectl`, `python3` or a
reachable cluster: it warns and prints the listing command it would have run.

Exit codes: `0` previewed, or every listed pod deleted (or already gone), `1`
the listing failed or a delete failed, `2` no `kubectl` or `python3`, or no
reachable cluster, with `--yes`, `3` usage or more than `--max` pods match,
and `4` no pod matches.

## Doctor a GKE cluster

`gke_cluster_doctor.sh` is read-only. It never updates the cluster — it
runs `gcloud container clusters describe` and nothing else, and prints the
`gcloud` command that would fix each finding.

```bash
./gke_cluster_doctor.sh --list-checks
./gke_cluster_doctor.sh --project P --cluster C --location europe-west1
./gke_cluster_doctor.sh --only channel,skew
./gke_cluster_doctor.sh --only authnets,shielded,dataplane
```

| Check | Finding | Fix printed |
| --- | --- | --- |
| `channel` | No release channel. | `--release-channel regular` |
| `skew` | A node pool on a different version from the control plane, pool by pool. | `clusters upgrade --node-pool POOL --cluster-version` |
| `identity` | Workload Identity not set. | `--workload-pool=PROJECT.svc.id.goog` |
| `network` | Reports private nodes and private endpoint; never a finding. | none |
| `nodepool-mgmt` | Node auto-repair off, or auto-upgrade off on a cluster with no release channel (a channel keeps auto-upgrade on whatever the pool says). | `node-pools update POOL --enable-autorepair --enable-autoupgrade` |
| `maintenance` | No maintenance window, so upgrades can start at any hour. | `--maintenance-window-start START --maintenance-window-end END --maintenance-window-recurrence RRULE` |
| `authnets` | A public control-plane endpoint with master authorized networks off, or `0.0.0.0/0` among the authorized blocks. Other blocks are counted, never printed. | `--enable-master-authorized-networks --master-authorized-networks CIDR` |
| `observability` | Logging without `SYSTEM_COMPONENTS` or `WORKLOADS`, or monitoring without `SYSTEM_COMPONENTS`. | `--logging=SYSTEM,WORKLOAD --monitoring=SYSTEM` |
| `shielded` | Shielded nodes off. | `--enable-shielded-nodes` |
| `dataplane` | Neither Dataplane V2 nor network policy enforcement, so NetworkPolicies are accepted and ignored. Dataplane V2 can only be chosen when a cluster is created. | `--update-addons=NetworkPolicy=ENABLED`, then `--enable-network-policy` |

The first four read single fields with `--format=value(...)` and need nothing
but `gcloud`. The last six share one `--format=json` describe, reduced by a
standard-library `python3` filter to booleans, names and counts. Without
`python3` they are skipped with a warning and the first four still run, but
naming one of them in `--only` exits `2`, because a skipped check asked for by
name would read as a pass.

Flags, or a kubectl context named `gke_PROJECT_LOCATION_CLUSTER`, resolve
the cluster. `--list-checks` and `--help` answer before `gcloud` is required.
Exit codes: `0` whether or not there are findings, `1` `gcloud` failed after
connecting or its JSON could not be read, `2` no `gcloud`, an unresolved
cluster, or no `python3` for a check `--only` named, `3` usage, and `4`
`--only` selected nothing.

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

The scripts follow the same rules as everything else in this repository:

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
and the Pod Security posture of the examples. The cleanup suite records every
delete its stub receives, so it proves a preview deletes nothing, `--yes`
deletes exactly the listed pods by name, and `--max` stops before the first.

Secret-free stubbed `kubectl` fixtures cover container readiness, init
failures, restartable sidecars, named container logs, restart loops and OOM
kills, Warning last-observation timestamps, stuck rollouts, StatefulSet and
DaemonSet updates, autoscaler conditions, failed Jobs, certificate expiry
windows and unreadable certificates (with an `openssl` stub, plus one real
certificate when `openssl` is installed), drain blockers and budget selectors,
every Kubernetes quantity form through the capacity percentages, each workload
and RBAC audit check with its label and next step, and query/JSON failures
across every diagnostic section. The workload, certificate, drain, capacity
and audit suites also prove from the stub's call log that nothing but `get`
and `cluster-info` ever ran. A stubbed
`gcloud` runs all ten GKE doctor checks against cluster descriptions, with and
without `python3`, and proves it only ever ran `container clusters describe`.
These tests never contact a real cluster.

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

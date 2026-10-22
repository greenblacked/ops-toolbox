# Kubernetes pods are unhealthy

<!-- markdownlint-disable MD033 -->

**When to use:** pods crash, stay Pending or never become Ready, or the
cluster looks unhappy, and you need to find what is wrong and look inside the
failing container before you change anything.

## Symptoms

- Pods sit in `CrashLoopBackOff`, `Pending` or `ImagePullBackOff`, or show
  `0/1` ready.
- A PersistentVolumeClaim stays `Pending` instead of `Bound`.
- A node reports `MemoryPressure`, `DiskPressure` or `PIDPressure`, or is not
  `Ready`.
- `kubectl get events` is full of `Warning` entries.

## Before you start

- `kubectl` with a kubeconfig context that reaches the cluster. Both scripts
  use the current context unless you pass `--context`, so check it first.
- `python3` (standard library only) on the machine that runs
  `kubectl_pod_diag.sh`; it parses the `kubectl` JSON with it. A missing
  `kubectl` or `python3` is exit `2`, as is a cluster the context cannot
  reach.
- The scripts. Work from a clone of the repository, or copy
  `k8s-toolbox/kubectl_pod_diag.sh` and `k8s-toolbox/debug_pod.sh` onto the
  machine; each works on its own. See
  [Installation and usage](../getting-started/usage.md).
- More on the package, its image and its caveats is on the
  [Kubernetes page](../platforms/kubernetes.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    `kubectl_pod_diag.sh` only runs `kubectl get` and `kubectl logs`. It
    never restarts, deletes, scales or patches anything.

Start with the whole cluster, then narrow it down:

```{ .bash .rpt-report title="Report" }
./k8s-toolbox/kubectl_pod_diag.sh
./k8s-toolbox/kubectl_pod_diag.sh --namespace prod --since 30m
./k8s-toolbox/kubectl_pod_diag.sh --context staging -n api
```

| Option | Meaning |
| --- | --- |
| `--namespace NS`, `-n NS` | Limit the pod, event and PVC checks to one namespace. Nodes are always checked cluster-wide. |
| `--context CTX` | The `kubectl` context to use. |
| `--since DURATION` | How far back to look for Warning events. Default `1h`; units `m`, `h`, `d` (for example `30m`, `2h`, `1d`). |
| `--all-namespaces`, `-A` | Scan every namespace. This is already the default; it only undoes an earlier `--namespace` on the same command line. |

The report has four sections, always in this order:

1. **Unhealthy pods.** Every pod that is not `Succeeded` and has a container
   (or init container, or sidecar) that is waiting, exited with a nonzero
   code, stopped while the pod is still `Running`, or is not ready. A pod
   that is not `Running` and has no such container, such as one stuck
   `Pending`, is listed by its phase. For each
   container in `CrashLoopBackOff` it prints the last 40 lines of that named
   container's **previous** logs, the run that crashed. For a container that
   exited nonzero it prints the last 40 lines of its current logs.
2. **Warning events (last 1h).** The heading shows your `--since` value.
   Warning events seen inside that window, at most 40, each message cut to 120 characters.
3. **Unbound PVCs.** Every PersistentVolumeClaim whose phase is not `Bound`.
4. **Node pressure.** Nodes with `MemoryPressure`, `DiskPressure` or
   `PIDPressure` set, and nodes whose `Ready` condition is not `True`.

Illustrative output (yours will differ):

```text
== Unhealthy pods ==
[warn] pod prod/api-7d9f8: container api: CrashLoopBackOff
[info] previous logs for prod/api-7d9f8 (container api):
    panic: missing DATABASE_URL

== Warning events (last 30m) ==
[warn] event prod/api-7d9f8: BackOff — Back-off restarting failed container api

== Unbound PVCs ==
[ ok ] no unbound PVCs

== Node pressure ==
[ ok ] no node pressure conditions

[info] 2 finding(s)
```

Read the exit code carefully. It is the other way round from most scripts in
this repository: `0` means the report **found** something, and `4` means it
looked and found nothing.

| Exit | Meaning |
| --- | --- |
| `0` | Findings reported. |
| `1` | A `kubectl` query or a JSON parse failed. The run still finishes the other sections, ends with "health check incomplete", and never prints "cluster looks quiet". Treat the report as incomplete. |
| `2` | No `kubectl`, no `python3`, or the cluster cannot be reached. |
| `3` | Bad arguments. |
| `4` | Every query worked and nothing was found: "cluster looks quiet". |

Decide from what you find. The previous logs of a crash-looping container
usually name the cause. When they do not, or the image has no shell to look
around in, go on to the debug container below.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "Nothing is attached"
    `--dry-run` prints the `kubectl debug` command and exits. It works even on
    a machine without `kubectl`.

```{ .bash .rpt-preview title="Preview" }
./k8s-toolbox/debug_pod.sh --pod api-7d9f8 -n prod --target api --dry-run
```

`--target` names the container whose process namespace the debug container
shares, which is what makes the application's processes and `/proc` visible.
The printed command uses `kubectl debug -it` with `--profile=general`, the
image, the namespace and the target, and ends with the command to run in the
debug container (`bash` unless you pass one after `--`).

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "This changes a live pod"
    `debug_pod.sh` adds an ephemeral container to the running pod. It does
    not create a new pod and it does not restart the application, but the
    pod's spec now carries that container.

```{ .bash .rpt-apply title="Apply" }
./k8s-toolbox/debug_pod.sh --pod api-7d9f8 -n prod --target api \
  --image REGISTRY/k8s-toolbox:TAG
```

For a one-shot look without an interactive shell:

```{ .bash .rpt-apply title="Apply, one-shot" }
./k8s-toolbox/debug_pod.sh --pod api-7d9f8 -n prod --target api \
  --image REGISTRY/k8s-toolbox:TAG --no-tty -- sh -c 'id; ps aux'
```

The default image is `k8s-toolbox:local`, which only works where the nodes
can see your local image store (kind, minikube or Docker Desktop). On any
other cluster push the image to a registry the cluster can pull from and pass
`--image`. Without `--namespace` the current context's namespace is used.

Exit codes: `0` success, `1` failure, `2` wrong environment (no `kubectl`),
`3` bad arguments (including a missing `--pod`). After its own checks the
script hands over to `kubectl debug`, so from there on the exit status is
the one `kubectl` returns.

Fixing the workload is outside this repository's scripts. A rollout restart,
a scale, a rollback, a corrected config or a resized PVC is your own `kubectl`
step, taken once the report and the debug container have told you what is
wrong.

## Verify

<span class="stage stage-report">read-only</span>

After your fix, run the report again with the same namespace and context:

```{ .bash .rpt-report title="Verify" }
./k8s-toolbox/kubectl_pod_diag.sh --namespace prod --since 30m
```

Success is exit `4` and the line `cluster looks quiet`. Exit `0` means
something is still listed; exit `1` means part of the check did not run, so
it is not a pass. Recent Warning events from before the fix stay inside the
`--since` window for a while; a shorter `--since` shows only what is new.

## Roll back

`kubectl_pod_diag.sh` changes nothing, so it has nothing to roll back.

`debug_pod.sh` has no removal step. What follows is Kubernetes behaviour, not
a feature of the script: an ephemeral container cannot be removed from a
running pod. It stops when its command exits, and the pod spec keeps the entry
until the pod is replaced, for example by its Deployment rolling out a new
pod. If you do not want that entry on a production pod, preview first and
attach only when you need to look inside.

## Related

- [Kubernetes platform page](../platforms/kubernetes.md)
- [`k8s-toolbox/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/k8s-toolbox/README.md)
- [Scripts overview](../scripts/index.md)
- On GKE, `./k8s-toolbox/gke_cluster_doctor.sh --list-checks` lists the
  read-only control-plane and node-pool checks, including version skew. Its
  exit codes differ again: `0` findings or healthy, `1` `gcloud` failed,
  `2` wrong environment, `3` bad arguments, `4` `--only` selected nothing.

<!-- markdownlint-enable MD033 -->

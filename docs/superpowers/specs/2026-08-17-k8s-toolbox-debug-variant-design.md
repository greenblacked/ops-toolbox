# k8s-toolbox debug image variant

Date: 2026-08-17
Branch: `feat/k8s-debug-config`

## Goal

Ship extra in-pod debug tools without changing the default k8s-toolbox image.

The default image stays the GKE-focused CLI toolbox and the restricted Pod
Security examples stay copy-pasteable. Network and process tools live in a
second image tag, built from a named Dockerfile stage, and used only by a
separate manifest directory.

## Non-goals

- No new flags on `run.sh` or `debug_pod.sh`. Callers pass
  `--tag k8s-toolbox:debug` or `--image k8s-toolbox:debug`.
- No `kubectl debug` profile flags (`netadmin`, `sysadmin`).
- No `hostNetwork`, no `privileged: true`, no node-debug wrappers.
- No pins in `versions.env` for Debian packages. The existing apt set in the
  toolbox stage is already unpinned; the debug packages follow that rule.
- No second Dockerfile.

## Architecture

The current image becomes a named stage `toolbox`. A second stage `debug`
starts from it, installs the extra packages as root, then drops back to user
`toolbox` (uid 1000).

`docker build` without `--target` builds the last stage. That would silently
tag the debug image as the default. `build.sh` therefore always passes
`--target`: `toolbox` unless `--variant debug` is set.

```text
debian:bookworm-slim
        │
        ▼
   stage: toolbox     →  k8s-toolbox:local     (unchanged CLIs)
        │
        ▼
   stage: debug       →  k8s-toolbox:debug     (those CLIs plus the debug set)
```

Default `examples/` keep naming `k8s-toolbox:local` and keep passing the
restricted Pod Security Standard. Debug manifests live in `k8s-toolbox/debug/`
so those restricted checks never see them.

## Dockerfile

Rename the existing `FROM debian:bookworm-slim` to
`FROM debian:bookworm-slim AS toolbox`. Leave the rest of that stage as it is,
including `USER toolbox` and `CMD ["bash"]`.

After that stage, add:

```dockerfile
FROM toolbox AS debug
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    htop iperf3 iputils-ping lsof ltrace mtr-tiny \
    netcat-openbsd socat strace tcpdump traceroute \
  && rm -rf /var/lib/apt/lists/*
USER toolbox
```

The debug stage does not declare `CMD` or `ENTRYPOINT`. It inherits
`CMD ["bash"]` from `toolbox`, which is what `run.sh` composes with.

Debian package names and the binaries the tests look for:

| Package | Binary on PATH |
| --- | --- |
| `htop` | `htop` |
| `iperf3` | `iperf3` |
| `iputils-ping` | `ping` |
| `lsof` | `lsof` |
| `ltrace` | `ltrace` |
| `mtr-tiny` | `mtr` |
| `netcat-openbsd` | `nc` |
| `socat` | `socat` |
| `strace` | `strace` |
| `tcpdump` | `tcpdump` |
| `traceroute` | `traceroute` |

`.dockerignore` is unchanged: the context is still only `Dockerfile` and
`versions.env`.

## `build.sh`

Add `--variant toolbox|debug`. Default is `toolbox`.

Default tags when `--tag` is omitted:

- `--variant toolbox` (or omitted) → `k8s-toolbox:local`
- `--variant debug` → `k8s-toolbox:debug`

`--tag` always wins over the default tag. `--variant` still selects the
`--target`. So `--variant debug --tag REGISTRY/k8s-toolbox:1.2.3-debug` builds
the debug stage and tags that name.

The buildx command always includes `--target` matching the variant. An empty
value, a value that starts with `--`, or any name other than `toolbox` or
`debug` exits `3`. `--help` still runs before Docker is required. `--dry-run`
still prints the command and writes nothing, including on a host without
Docker.

`--push`, `--pull`, and `--platform` keep their current meaning and combine
with `--variant`.

## `run.sh` and `debug_pod.sh`

No code changes. The debug image is an ordinary tag:

```bash
./build.sh --variant debug
./run.sh --tag k8s-toolbox:debug
./debug_pod.sh --pod api-7d9f8 --image k8s-toolbox:debug
```

## `k8s-toolbox/debug/`

Three files, mirroring `examples/` without sharing its kustomization:

- `pod.yaml` — long-running `sleep infinity` pod named `k8s-toolbox-debug`
- `job.yaml` — one-shot job that prints `command -v` for every binary in the
  table above, then exits
- `kustomization.yaml` — retags `k8s-toolbox:debug` the same way `examples/`
  retags `k8s-toolbox:local`

Shared with `examples/`:

- `runAsNonRoot: true`, uid/gid/fsGroup 1000
- `allowPrivilegeEscalation: false`
- `seccompProfile.type: RuntimeDefault`
- `automountServiceAccountToken: false`
- `readOnlyRootFilesystem: false` (gcloud still needs a writable config dir)
- `resources` requests and limits, same numbers as `examples/pod.yaml`
- `imagePullPolicy: IfNotPresent`

Different from `examples/`:

- image `k8s-toolbox:debug`
- container `capabilities.drop: [ALL]` then
  `capabilities.add: [NET_RAW, NET_ADMIN, SYS_PTRACE]`
- comments state that this directory does not pass restricted PSS, and that
  those three capabilities exist because `tcpdump`/`ping` need raw sockets and
  `strace`/`ltrace` need ptrace
- `privileged: false` is left at the default (unset). Do not set
  `privileged: true`. Do not set `hostNetwork: true`.

The pod is a toolbox you exec into, so `tcpdump` sees that pod's network
namespace. Attaching to someone else's process namespace remains
`debug_pod.sh --target`, with `--image k8s-toolbox:debug`.

## Tests

Contract suite (`./run-tests.sh k8s`), no image build:

- `--help` documents `--variant` and still documents exit codes.
- `--variant` with no value, `--variant --push`, and `--variant foo` each
  exit `3`.
- Default `--dry-run` includes `--target toolbox` and tag `k8s-toolbox:local`.
- `--dry-run --variant debug` includes `--target debug` and tag
  `k8s-toolbox:debug`.
- `--dry-run --variant debug --tag REGISTRY/k8s-toolbox:1.2.3` includes that
  tag and still `--target debug`.
- `examples/` restricted PSS checks are unchanged and still iterate only
  `examples/pod.yaml` and `examples/job.yaml`.
- `debug/` is asserted separately over both `debug/pod.yaml` and
  `debug/job.yaml`: image `k8s-toolbox:debug`, `runAsNonRoot`,
  `automountServiceAccountToken: false`, `NET_RAW`, `NET_ADMIN`, `SYS_PTRACE`.
  It is not required to pass restricted PSS. The job uses the same
  capabilities as the pod, even though `command -v` does not need them,
  because the job is also an example people copy.
- Dockerfile contains `AS toolbox` and `AS debug`.
- `CMD ["bash"]` still appears exactly once; still no `ENTRYPOINT`.

Optional `K8S_IMAGE_SMOKE=1` builds both tags (`k8s-toolbox:ci-smoke` for
toolbox, `k8s-toolbox:ci-smoke-debug` for debug) and probes them with
`run.sh --no-kubeconfig --no-tty`:

- Toolbox image: uid 1000, existing CLIs on PATH, `command -v tcpdump` fails.
  That last check is the last-stage footgun: if `build.sh` forgot `--target
  toolbox`, tcpdump would be present.
- Debug image: uid 1000, existing CLIs still on PATH, every binary in the
  table above is on PATH.

The scheduled image-smoke workflow already runs `K8S_IMAGE_SMOKE=1`; it picks
up the second build with no workflow change.

## Docs

- `k8s-toolbox/README.md`: document `--variant`, the debug tag, the package
  list, `debug/` as a non-restricted overlay, and that `run.sh` /
  `debug_pod.sh` take the tag/image flag rather than a new switch.
- Root README Kubernetes glance: one bullet that the debug tools are a second
  tag, not the default image.
- `CHANGELOG.md` `[Unreleased]` Added: debug variant and `debug/` manifests.

## Usage

```bash
./build.sh --dry-run --variant debug
./build.sh --variant debug
./run.sh --tag k8s-toolbox:debug
./debug_pod.sh --pod api-7d9f8 --image k8s-toolbox:debug
kubectl apply -f k8s-toolbox/debug/pod.yaml
kubectl exec -it k8s-toolbox-debug -- bash
kubectl delete pod k8s-toolbox-debug
```

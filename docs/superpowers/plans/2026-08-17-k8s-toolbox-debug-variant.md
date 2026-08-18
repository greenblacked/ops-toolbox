# k8s-toolbox Debug Variant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a named `debug` image stage and `k8s-toolbox/debug/` manifests so extra network and process tools ship as `k8s-toolbox:debug`, leaving the default restricted toolbox image unchanged.

**Architecture:** The current Dockerfile becomes stage `toolbox`. A second stage `debug` installs Debian debug packages and drops back to uid 1000. `build.sh` always passes `--target` so the last-stage default cannot silently ship debug as `k8s-toolbox:local`. Restricted PSS checks stay on `examples/` only.

**Tech Stack:** Bash 3.2-safe scripts, Docker Buildx multi-stage Dockerfile, Kubernetes YAML, the existing `./run-tests.sh k8s` contract suite, and `K8S_IMAGE_SMOKE=1` for a real image build under Docker.

**Spec:** [`docs/superpowers/specs/2026-08-17-k8s-toolbox-debug-variant-design.md`](../specs/2026-08-17-k8s-toolbox-debug-variant-design.md)

## Global Constraints

- Default image tag remains `k8s-toolbox:local`; debug tag is `k8s-toolbox:debug`.
- `build.sh` always passes `--target toolbox` or `--target debug`. Never rely on Docker's last-stage default.
- No new flags on `run.sh` or `debug_pod.sh`.
- No `versions.env` pins for Debian packages.
- No second Dockerfile, no `hostNetwork`, no `privileged: true`.
- `examples/` keep passing restricted PSS. `debug/` does not, and is not checked for it.
- Extra capabilities on debug manifests: `NET_RAW`, `NET_ADMIN`, `SYS_PTRACE`, after `drop: [ALL]`.
- Debug packages: `htop iperf3 iputils-ping lsof ltrace mtr-tiny netcat-openbsd socat strace tcpdump traceroute`.
- Binaries the tests look for: `htop iperf3 ping lsof ltrace mtr nc socat strace tcpdump traceroute`.
- `K8S_IMAGE_SMOKE=1` is a **required** verification task in this plan, not optional. Do not claim the work is done until both tags have been built and probed under Docker.
- Follow [`CONTRIBUTING.md`](../../../CONTRIBUTING.md). No AI attribution in commits, comments, changelog, or docs.
- Write the failing test first; confirm it fails against unfixed code; then implement.

## File map

- Modify: `k8s-toolbox/tests/test_k8s_toolbox.sh` — `--variant` contracts, stage names, `debug/` assertions, dual-tag smoke
- Modify: `k8s-toolbox/build.sh` — `--variant`, default tags, always `--target`
- Modify: `k8s-toolbox/Dockerfile` — `AS toolbox` plus `debug` stage
- Create: `k8s-toolbox/debug/pod.yaml`
- Create: `k8s-toolbox/debug/job.yaml`
- Create: `k8s-toolbox/debug/kustomization.yaml`
- Modify: `k8s-toolbox/README.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Unchanged: `run.sh`, `debug_pod.sh`, `.dockerignore`, `.github/workflows/k8s-image-smoke.yml`

---

### Task 1: `build.sh --variant`

**Files:**
- Modify: `k8s-toolbox/tests/test_k8s_toolbox.sh`
- Modify: `k8s-toolbox/build.sh`

**Interfaces:**
- Consumes: existing `require_value`, `--dry-run`, `--tag`
- Produces: `--variant toolbox|debug` (default `toolbox`); default tags `k8s-toolbox:local` / `k8s-toolbox:debug`; every buildx command includes `--target` matching the variant; `--tag` wins over the default tag

- [ ] **Step 1: Write the failing tests**

In `k8s-toolbox/tests/test_k8s_toolbox.sh`, add `"build.sh --variant"` to `missing_value_cases`.

After the existing `build.sh --tag --push` assertion, add:

```bash
guard "$K/build.sh" --variant --push >/dev/null 2>&1
assert_rc "build.sh --variant --push (flag is not a value)" 3 "$?"

guard "$K/build.sh" --variant foo >/dev/null 2>&1
assert_rc "build.sh --variant foo" 3 "$?"
```

After the `--help` loop, add:

```bash
out="$(guard "$K/build.sh" --help 2>&1)"
if [[ "$out" == *"--variant"* ]]; then
  ok "build.sh --help documents --variant"
else
  err "build.sh --help does not document --variant"
fi
```

After the existing `build.sh --dry-run --tag k8s-toolbox:test` content check, add:

```bash
out="$(guard "$K/build.sh" --dry-run 2>&1)"
if [[ "$out" == *"--target"* && "$out" == *"toolbox"* &&
      "$out" == *"k8s-toolbox:local"* && "$out" != *"k8s-toolbox:debug"* ]]; then
  ok "build.sh --dry-run defaults to --target toolbox and k8s-toolbox:local"
else
  err "build.sh --dry-run does not pin --target toolbox / k8s-toolbox:local"
fi

out="$(guard "$K/build.sh" --dry-run --variant debug 2>&1)"
if [[ "$out" == *"--target"* && "$out" == *"debug"* &&
      "$out" == *"k8s-toolbox:debug"* ]]; then
  ok "build.sh --dry-run --variant debug targets debug and tags k8s-toolbox:debug"
else
  err "build.sh --dry-run --variant debug is missing --target debug or the debug tag"
fi

out="$(guard "$K/build.sh" --dry-run --variant debug --tag REGISTRY/k8s-toolbox:1.2.3 2>&1)"
if [[ "$out" == *"--target"* && "$out" == *"debug"* &&
      "$out" == *"REGISTRY/k8s-toolbox:1.2.3"* ]]; then
  ok "build.sh --tag wins over the debug default and still passes --target debug"
else
  err "build.sh --variant debug --tag did not keep --target debug or the explicit tag"
fi
```

Also extend `dry_run_case` coverage:

```bash
dry_run_case "build.sh --variant debug" "$K/build.sh" --dry-run --variant debug
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./run-tests.sh k8s`

Expected: FAIL. `build.sh --help does not document --variant`, unknown `--variant foo` is not exit 3 (today it is "unknown option" which *is* exit 3 — that one may already pass), `--dry-run` does not contain `--target toolbox`. If `--variant foo` already exits 3 via unknown-option, that is acceptable as a temporary pass; the dry-run `--target` checks and `--help` must fail.

If every new check already passes, stop: the tests are not covering the spec.

- [ ] **Step 3: Implement `--variant` in `build.sh`**

Replace the default `tag="k8s-toolbox:local"` with an empty tag and a `variant` variable. Parse `--variant` / `--variant=*` with `require_value`. After the argument loop, reject any variant other than `toolbox` or `debug` with `err` and exit 3. If `tag` is still empty, set `k8s-toolbox:debug` for debug and `k8s-toolbox:local` otherwise. Always pass `--target "$variant"` into `build_args`.

```bash
tag=""
variant="toolbox"
platforms="linux/amd64,linux/arm64"
push="false"
pull="false"
DRY_RUN=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tag) require_value "$1" "${2:-}"; tag="$2"; shift ;;
    --tag=*) tag="${1#*=}"; require_value "--tag" "$tag" ;;
    --variant) require_value "$1" "${2:-}"; variant="$2"; shift ;;
    --variant=*) variant="${1#*=}"; require_value "--variant" "$variant" ;;
    --platform) require_value "$1" "${2:-}"; platforms="$2"; shift ;;
    --platform=*) platforms="${1#*=}"; require_value "--platform" "$platforms" ;;
    --push) push="true" ;;
    --pull) pull="true" ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$variant" in
  toolbox|debug) ;;
  *)
    err "unknown --variant: $variant (want toolbox or debug)"
    exit 3
    ;;
esac

if [[ -z "$tag" ]]; then
  if [[ "$variant" == "debug" ]]; then
    tag="k8s-toolbox:debug"
  else
    tag="k8s-toolbox:local"
  fi
fi
```

Insert `--target "$variant"` next to `--tag "$tag"` in `build_args`:

```bash
build_args=(
  --build-arg "YQ_VERSION=${YQ_VERSION}"
  --build-arg "KUBECTL_VERSION=${KUBECTL_VERSION}"
  --build-arg "HELM_VERSION=${HELM_VERSION}"
  --build-arg "KUSTOMIZE_VERSION=${KUSTOMIZE_VERSION}"
  --build-arg "GCLOUD_VERSION=${GCLOUD_VERSION}"
  -f "$SCRIPT_DIR/Dockerfile"
  --target "$variant"
  --tag "$tag"
  "$SCRIPT_DIR"
)
```

Update `usage()`:

```text
Usage:
  $(basename "$0") [--tag TAG] [--variant toolbox|debug] [--platform PLATFORMS]
                  [--push] [--pull] [--dry-run]

Options:
  --tag TAG            Image tag (default: k8s-toolbox:local, or
                       k8s-toolbox:debug with --variant debug)
  --variant toolbox|debug  Dockerfile stage to build (default: toolbox)
```

Keep the rest of `--help` (platform, push, pull, dry-run, exit codes) as it is today.

- [ ] **Step 4: Re-run the k8s suite**

Run: `./run-tests.sh k8s`

Expected: all k8s-toolbox checks passed.

- [ ] **Step 5: Commit**

```bash
git add k8s-toolbox/tests/test_k8s_toolbox.sh k8s-toolbox/build.sh
git commit -m "$(cat <<'EOF'
feat(k8s): let build.sh select the toolbox or debug stage

Always pass --target so a later debug stage cannot become the default
image, and default the debug variant to k8s-toolbox:debug.
EOF
)"
```

---

### Task 2: Dockerfile `debug` stage

**Files:**
- Modify: `k8s-toolbox/tests/test_k8s_toolbox.sh`
- Modify: `k8s-toolbox/Dockerfile`

**Interfaces:**
- Consumes: Task 1 `--target toolbox|debug`
- Produces: named stages `toolbox` and `debug`; debug stage installs the spec package list and returns to `USER toolbox`; still exactly one `CMD ["bash"]` and no `ENTRYPOINT`

- [ ] **Step 1: Write the failing tests**

In the existing `pinned toolchain` section, next to the `CMD ["bash"]` check, replace that check with:

```bash
if grep -q 'AS toolbox' "$K/Dockerfile"; then
  ok "Dockerfile names the toolbox stage"
else
  err "Dockerfile is missing AS toolbox — build.sh --target toolbox would fail"
fi

if grep -q 'AS debug' "$K/Dockerfile"; then
  ok "Dockerfile names the debug stage"
else
  err "Dockerfile is missing AS debug — build.sh --variant debug would fail"
fi

cmd_count="$(grep -cFx 'CMD ["bash"]' "$K/Dockerfile" || true)"
if [[ "$cmd_count" == "1" ]] && ! grep -q '^ENTRYPOINT ' "$K/Dockerfile"; then
  ok "Dockerfile default command composes with run.sh commands"
else
  err "Dockerfile must declare CMD [\"bash\"] once; an ENTRYPOINT would prepend bash to run.sh commands"
fi

for pkg in htop iperf3 iputils-ping lsof ltrace mtr-tiny netcat-openbsd socat strace tcpdump traceroute; do
  if grep -Fq "$pkg" "$K/Dockerfile"; then
    ok "Dockerfile debug stage installs $pkg"
  else
    err "Dockerfile debug stage does not install $pkg"
  fi
done
```

Remove the old `grep -Fxq 'CMD ["bash"]'` block so it is not duplicated.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./run-tests.sh k8s`

Expected: FAIL on `AS toolbox`, `AS debug`, and the package names. The CMD check should still pass (one `CMD ["bash"]` already exists).

- [ ] **Step 3: Add the named stages**

Change line 1 of `k8s-toolbox/Dockerfile` from `FROM debian:bookworm-slim` to `FROM debian:bookworm-slim AS toolbox`.

After `CMD ["bash"]`, append:

```dockerfile
FROM toolbox AS debug
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    htop \
    iperf3 \
    iputils-ping \
    lsof \
    ltrace \
    mtr-tiny \
    netcat-openbsd \
    socat \
    strace \
    tcpdump \
    traceroute \
  && rm -rf /var/lib/apt/lists/*
USER toolbox
```

Do not add a second `CMD` or an `ENTRYPOINT`. The debug stage inherits `CMD ["bash"]`.

- [ ] **Step 4: Re-run the k8s suite**

Run: `./run-tests.sh k8s`

Expected: all k8s-toolbox checks passed.

If `hadolint` is on PATH, also run `hadolint --failure-threshold error k8s-toolbox/Dockerfile`. Expected: no errors. `FROM toolbox` is a previous stage, not an unpinned registry image.

- [ ] **Step 5: Commit**

```bash
git add k8s-toolbox/Dockerfile k8s-toolbox/tests/test_k8s_toolbox.sh
git commit -m "$(cat <<'EOF'
feat(k8s): add a debug image stage with in-pod network and process tools

Keep the default toolbox stage unchanged; tcpdump, strace and the rest
install only when build.sh --variant debug is selected.
EOF
)"
```

---

### Task 3: `k8s-toolbox/debug/` manifests

**Files:**
- Modify: `k8s-toolbox/tests/test_k8s_toolbox.sh`
- Create: `k8s-toolbox/debug/pod.yaml`
- Create: `k8s-toolbox/debug/job.yaml`
- Create: `k8s-toolbox/debug/kustomization.yaml`

**Interfaces:**
- Consumes: image tag `k8s-toolbox:debug` from Task 1
- Produces: a long-running pod `k8s-toolbox-debug` and a job that prints `command -v` for every debug binary; both drop ALL then add `NET_RAW`, `NET_ADMIN`, `SYS_PTRACE`

- [ ] **Step 1: Write the failing tests**

After the existing `restricted Pod Security basics` loop (which must still iterate only `examples/pod.yaml` and `examples/job.yaml`), add:

```bash
head_ "debug overlay"

for manifest in "$K/debug/pod.yaml" "$K/debug/job.yaml"; do
  if [[ -f "$manifest" ]]; then
    ok "${manifest##*/} exists"
  else
    err "missing ${manifest##*/}"
    continue
  fi
  name="${manifest##*/}"
  for want in \
    'k8s-toolbox:debug' \
    'runAsNonRoot: true' \
    'automountServiceAccountToken: false' \
    'NET_RAW' \
    'NET_ADMIN' \
    'SYS_PTRACE'
  do
    if grep -q "$want" "$manifest"; then
      ok "$name sets '$want'"
    else
      err "$name is missing '$want'"
    fi
  done
  if grep -q 'privileged: true' "$manifest"; then
    err "$name sets privileged: true — the spec forbids it"
  else
    ok "$name does not set privileged: true"
  fi
  if grep -q 'hostNetwork: true' "$manifest"; then
    err "$name sets hostNetwork: true — the spec forbids it"
  else
    ok "$name does not set hostNetwork: true"
  fi
done

if [[ -f "$K/debug/kustomization.yaml" ]] &&
   grep -q 'k8s-toolbox:debug' "$K/debug/kustomization.yaml"; then
  ok "debug kustomization retags k8s-toolbox:debug"
else
  err "debug/kustomization.yaml missing or does not name k8s-toolbox:debug"
fi
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./run-tests.sh k8s`

Expected: FAIL with `missing pod.yaml` / `missing job.yaml` under `debug overlay`. The `examples/` restricted checks must still pass.

- [ ] **Step 3: Create the manifests**

`k8s-toolbox/debug/pod.yaml`:

```yaml
---
# A long-running debug toolbox pod to exec into.
#
# This directory does not pass the restricted Pod Security Standard.
# tcpdump and ping need NET_RAW/NET_ADMIN; strace and ltrace need
# SYS_PTRACE. Copy examples/ when you want restricted; copy this when
# you need those tools to actually work.
#
# Delete it when you are done: `kubectl delete pod k8s-toolbox-debug`.
apiVersion: v1
kind: Pod
metadata:
  name: k8s-toolbox-debug
  labels:
    app: k8s-toolbox-debug
spec:
  restartPolicy: Always
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: toolbox
      image: k8s-toolbox:debug
      imagePullPolicy: IfNotPresent
      command: ["bash", "-lc", "sleep infinity"]
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: false
        capabilities:
          drop:
            - ALL
          add:
            - NET_RAW
            - NET_ADMIN
            - SYS_PTRACE
        seccompProfile:
          type: RuntimeDefault
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 512Mi
```

`k8s-toolbox/debug/job.yaml` uses the same pod securityContext, image `k8s-toolbox:debug`, name `k8s-toolbox-debug-job`, `restartPolicy: Never`, `backoffLimit: 0`, `ttlSecondsAfterFinished: 3600`, and this command (same extra capabilities as the pod, because the job is also an example people copy):

```yaml
command:
  - bash
  - -lc
  - |
    set -euo pipefail
    for bin in htop iperf3 ping lsof ltrace mtr nc socat strace tcpdump traceroute; do
      command -v "$bin"
    done
```

`k8s-toolbox/debug/kustomization.yaml`:

```yaml
---
# Retag the debug manifests without editing them.
#
#   kustomize edit set image k8s-toolbox:debug=REGISTRY/k8s-toolbox:1.2.3-debug
#   kubectl apply -k k8s-toolbox/debug/
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - pod.yaml
  - job.yaml

images:
  - name: k8s-toolbox:debug
    newName: k8s-toolbox
    newTag: debug

labels:
  - includeSelectors: false
    pairs:
      app.kubernetes.io/name: k8s-toolbox
      app.kubernetes.io/component: debug-tools
```

- [ ] **Step 4: Re-run the k8s suite**

Run: `./run-tests.sh k8s`

Expected: all k8s-toolbox checks passed, including `debug overlay`.

- [ ] **Step 5: Commit**

```bash
git add k8s-toolbox/debug k8s-toolbox/tests/test_k8s_toolbox.sh
git commit -m "$(cat <<'EOF'
feat(k8s): add debug manifests beside the restricted examples

Keep extra capabilities in k8s-toolbox/debug/ so examples/ still pass
restricted PSS and tcpdump/strace have the caps they need.
EOF
)"
```

---

### Task 4: Docs

**Files:**
- Modify: `k8s-toolbox/README.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `--variant`, `k8s-toolbox:debug`, `k8s-toolbox/debug/`
- Produces: documented build/run/apply paths; changelog Added entry

- [ ] **Step 1: Update `k8s-toolbox/README.md`**

Add a file-table row for [`debug/`](debug/). Extend the Build examples:

```bash
./build.sh --variant debug                    # k8s-toolbox:debug
./build.sh --dry-run --variant debug
./build.sh --variant debug --tag REGISTRY/k8s-toolbox:1.2.3-debug --push
```

Add a short "Debug image" section listing the extra packages, stating they are unpinned Debian packages on purpose, showing:

```bash
./run.sh --tag k8s-toolbox:debug
./debug_pod.sh --pod api-7d9f8 --image k8s-toolbox:debug
kubectl apply -f debug/pod.yaml
```

State that `debug/` does not pass restricted PSS, and that `run.sh` / `debug_pod.sh` take the existing `--tag` / `--image` flags rather than a new switch.

- [ ] **Step 2: Update the root README glance**

After the `examples/` bullet in "Kubernetes toolbox at a glance", add:

```markdown
- `debug/` — a second image tag (`k8s-toolbox:debug`) with tcpdump, strace
  and the rest, plus manifests that add `NET_RAW` / `NET_ADMIN` /
  `SYS_PTRACE`. The default image and `examples/` stay restricted.
```

Also mention `--variant` on the `build.sh` bullet.

- [ ] **Step 3: Changelog**

Insert `### Added` above `### Fixed` under `## [Unreleased]`:

```markdown
### Added

- `k8s-toolbox` now has a `debug` image stage, selected with
  `build.sh --variant debug`, tagged `k8s-toolbox:debug` by default.
  It adds tcpdump, strace, htop and the other in-pod network/process
  tools as Debian packages, without putting them in the default image.
  Manifests live in `k8s-toolbox/debug/` and add `NET_RAW`,
  `NET_ADMIN` and `SYS_PTRACE`; `examples/` still pass restricted PSS.
```

- [ ] **Step 4: Lint the markdown and re-run k8s contracts**

Run:

```bash
npx markdownlint-cli2 --config .markdownlint-cli2.yaml \
  k8s-toolbox/README.md README.md CHANGELOG.md
./run-tests.sh k8s
```

Expected: markdownlint clean, k8s suite passed.

- [ ] **Step 5: Commit**

```bash
git add k8s-toolbox/README.md README.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: describe the k8s-toolbox debug image variant

Record that extra debug tools are a second tag and a separate
manifest directory, not the default restricted image.
EOF
)"
```

---

### Task 5: Docker image smoke (required)

This task is not optional. The contract suite never builds the image; the last-stage footgun (`tcpdump` present on `k8s-toolbox:local`) is only visible by building both tags.

**Files:**
- Modify: `k8s-toolbox/tests/test_k8s_toolbox.sh` (smoke block only)
- Unchanged: `.github/workflows/k8s-image-smoke.yml` (already runs `K8S_IMAGE_SMOKE=1`)

**Interfaces:**
- Consumes: `build.sh --tag` (toolbox) and `build.sh --variant debug --tag` (debug)
- Produces: smoke that builds `k8s-toolbox:ci-smoke` and `k8s-toolbox:ci-smoke-debug`, asserts uid 1000, asserts toolbox has the CLIs and **not** `tcpdump`, asserts debug has every extra binary

- [ ] **Step 1: Extend the smoke block**

Replace the current `K8S_IMAGE_SMOKE` build/probe so it builds both tags. Keep the existing gcloud staging check on the toolbox tag. After the existing CLI checks inside the toolbox container, add `command -v tcpdump` as a **failure**:

```bash
if [[ "${K8S_IMAGE_SMOKE:-0}" == "1" ]]; then
  printf '[info] K8S_IMAGE_SMOKE=1 — building toolbox and debug images (slow, needs network)\n'
  if "$K/build.sh" --tag k8s-toolbox:ci-smoke --platform linux/amd64; then
    ok "toolbox image build"
    if "$K/run.sh" --tag k8s-toolbox:ci-smoke --no-kubeconfig --no-tty -- bash -lc '
         set -euo pipefail
         [ "$(id -u)" = "1000" ]
         kubectl version --client=true >/dev/null
         helm version >/dev/null
         kustomize version >/dev/null
         yq --version >/dev/null
         gcloud --version >/dev/null
         gke-gcloud-auth-plugin --version >/dev/null
         if command -v tcpdump >/dev/null 2>&1; then
           echo "tcpdump must not be in the toolbox image" >&2
           exit 1
         fi
       '; then
      ok "toolbox image is uid 1000, has the CLIs, and does not ship tcpdump"
    else
      err "toolbox image smoke checks failed"
    fi
    # existing gcloud staging check against k8s-toolbox:ci-smoke stays here
  else
    err "toolbox image build failed"
  fi

  if "$K/build.sh" --variant debug --tag k8s-toolbox:ci-smoke-debug --platform linux/amd64; then
    ok "debug image build"
    if "$K/run.sh" --tag k8s-toolbox:ci-smoke-debug --no-kubeconfig --no-tty -- bash -lc '
         set -euo pipefail
         [ "$(id -u)" = "1000" ]
         kubectl version --client=true >/dev/null
         for bin in htop iperf3 ping lsof ltrace mtr nc socat strace tcpdump traceroute; do
           command -v "$bin" >/dev/null
         done
       '; then
      ok "debug image is uid 1000 with every extra binary on PATH"
    else
      err "debug image smoke checks failed"
    fi
  else
    err "debug image build failed"
  fi
else
  ok "image build skipped — set K8S_IMAGE_SMOKE=1 to build and probe it"
fi
```

Keep the existing gcloud writable-staging block from the current file; only retarget it at `k8s-toolbox:ci-smoke` if the tag name is still that.

- [ ] **Step 2: Confirm Docker is available, then run the smoke**

```bash
docker info >/dev/null
K8S_IMAGE_SMOKE=1 ./run-tests.sh k8s
```

Expected:

- `docker info` succeeds. If it does not, start Docker Desktop (or the daemon) and retry. Do not skip this task.
- Suite prints `toolbox image is uid 1000, has the CLIs, and does not ship tcpdump`
- Suite prints `debug image is uid 1000 with every extra binary on PATH`
- `=== all k8s-toolbox checks passed`
- Exit 0

`k8s-toolbox/tests/run.sh` already exits 1 if `K8S_IMAGE_SMOKE=1` and `docker` is missing. Treat that as a failed task, not a skip.

This build pulls the pinned toolchains and Debian packages. Several minutes is expected.

- [ ] **Step 3: Commit**

```bash
git add k8s-toolbox/tests/test_k8s_toolbox.sh
git commit -m "$(cat <<'EOF'
test(k8s): smoke-build both toolbox and debug image tags

The toolbox image must not contain tcpdump; that is the last-stage
default becoming the debug image. The debug tag must have every extra
binary, still as uid 1000.
EOF
)"
```

---

## Self-review

Spec coverage:

- Named stages + always `--target` → Tasks 1 and 2
- Package/binary list → Tasks 2, 3, 5
- `--variant` default tags and `--tag` wins → Task 1
- No `run.sh` / `debug_pod.sh` flags → File map (unchanged)
- `debug/` manifests, caps, no privileged/hostNetwork → Task 3
- Restricted PSS stays on `examples/` → Task 3 tests
- Docs + changelog → Task 4
- Docker smoke of both tags, including tcpdump-absent on toolbox → Task 5 (required)

No placeholders. Names (`--variant`, `k8s-toolbox:debug`, `k8s-toolbox-debug`, `ci-smoke-debug`) are consistent across tasks.

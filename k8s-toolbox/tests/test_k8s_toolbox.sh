#!/usr/bin/env bash
# Contract checks for the k8s-toolbox scripts.
#
# Deliberately checks contracts rather than the image. Building the image pulls
# five pinned toolchains over the network and takes minutes, which is the same
# reason the RouterOS CHR suite is kept off the pull-request path — so this
# suite needs nothing but bash, and it runs everywhere the static suite does.
#
# K8S_IMAGE_SMOKE=1 opts into the real build and asserts the pinned versions
# landed. That path needs Docker and network; nothing else here does.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
K="$REPO_ROOT/k8s-toolbox"

failures=0
ok()   { printf '[ ok ] %s\n' "$*"; }
err()  { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }
head_() { printf '\n--- %s ---\n' "$*"; }

assert_rc() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    ok "$label"
  else
    err "$label (expected exit $want, got $got)"
  fi
}

# Every check below runs a script. One that blocks on input would hang the
# suite instead of failing it; macOS has no timeout(1), so fall back there.
#
# Resolved to an absolute path once, because some checks below run a script
# with PATH emptied on purpose — a bare `timeout` would then be the thing that
# is not found, and every such check would report 127 instead of the contract.
TIMEOUT_BIN="$(command -v timeout || true)"
if [[ -n "$TIMEOUT_BIN" ]]; then
  guard() { "$TIMEOUT_BIN" 20 "$@"; }
else
  guard() { "$@"; }
fi

# --------------------------------------------------------------------------
head_ "discovery"
# Discovered, not listed: a script added to k8s-toolbox/ is covered by the
# commit that adds it, the way the static suite finds its own subjects.
scripts=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  scripts+=("$f")
done < <(find "$K" -maxdepth 1 -name '*.sh' -type f | sort)

if (( ${#scripts[@]} == 0 )); then
  err "discovered no scripts under k8s-toolbox/ — discovery is broken"
  exit 1
fi
ok "discovered ${#scripts[@]} scripts under k8s-toolbox/"

# The mode has to be right in the index, not just in this working tree: a
# clone gets its permissions from git, and a script that arrives 644 is one
# nobody can run without knowing to chmod it first.
for f in "${scripts[@]}"; do
  name="${f##*/}"
  if [[ ! -x "$f" ]]; then
    err "$name is not executable — chmod +x, and commit the mode"
    continue
  fi
  record="$(git -C "$REPO_ROOT" ls-files -s -- "$f" 2>/dev/null)"
  if [[ -z "$record" ]]; then
    ok "$name is executable (not tracked yet, so no index mode to check)"
  elif [[ "${record%% *}" == "100755" ]]; then
    ok "$name is executable, in this tree and in the index"
  else
    err "$name is 755 here but ${record%% *} in the index — git update-index --chmod=+x"
  fi
done

# --------------------------------------------------------------------------
head_ "syntax"
for f in "${scripts[@]}"; do
  if bash -n "$f" 2>/dev/null; then
    ok "bash -n ${f##*/}"
  else
    err "bash -n ${f##*/}"
    bash -n "$f"
  fi
done

# ShellCheck is a hard gate in CI's lint job. Running it here too means a local
# run catches the same thing, and its absence is reported rather than silent.
if command -v shellcheck >/dev/null 2>&1; then
  for f in "${scripts[@]}"; do
    if shellcheck --severity=error -x --shell=bash "$f"; then
      ok "shellcheck ${f##*/}"
    else
      err "shellcheck ${f##*/}"
    fi
  done
else
  ok "shellcheck is not installed — skipped here, and gated in CI"
fi

# --------------------------------------------------------------------------
head_ "--help contract"
# --help answers before any preflight check, so it works on a machine with
# neither Docker nor kubectl — which is exactly the machine reading the help.
for f in "${scripts[@]}"; do
  out=""
  out="$(guard "$f" --help 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    err "${f##*/} --help exited $rc, expected 0"
  elif [[ -z "${out//[[:space:]]/}" ]]; then
    err "${f##*/} --help printed nothing"
  elif [[ "$out" != *"Exit codes:"* ]]; then
    err "${f##*/} --help does not document its exit codes"
  else
    ok "${f##*/} --help"
  fi
done

# --------------------------------------------------------------------------
head_ "unknown-flag contract"
for f in "${scripts[@]}"; do
  guard "$f" --definitely-not-a-valid-flag-12345 >/dev/null 2>&1
  assert_rc "${f##*/} unknown flag" 3 "$?"
done

# --------------------------------------------------------------------------
head_ "options that take a value require one"
# The "${2:?}" form these were written with exits 1, not 3, so a typo like
# `--tag --push` reported "failure" where the contract says "usage".
missing_value_cases=(
  "build.sh --tag"
  "build.sh --platform"
  "run.sh --tag"
  "debug_pod.sh --pod"
  "debug_pod.sh --namespace"
  "debug_pod.sh --image"
  "kubectl_pod_diag.sh --namespace"
  "kubectl_pod_diag.sh --context"
)
for case_ in "${missing_value_cases[@]}"; do
  script="${case_%% *}"
  flag="${case_#* }"
  guard "$K/$script" "$flag" >/dev/null 2>&1
  assert_rc "$script $flag with no value" 3 "$?"
done

# A flag swallowing the next flag as its value is the failure this guards:
# `--tag --push` must be usage, not a build tagged "--push".
guard "$K/build.sh" --tag --push >/dev/null 2>&1
assert_rc "build.sh --tag --push (flag is not a value)" 3 "$?"

# --------------------------------------------------------------------------
head_ "a dry run writes nothing"
# Asserted against the filesystem, not against the script's own claim. Each run
# gets a scratch HOME and TMPDIR, snapshotted by name and mtime before and
# after, so a rewritten file is caught as well as a new one.
snapshot() {
  find "$1" "$2" -mindepth 1 -printf '%p %T@\n' 2>/dev/null | sort
}

dry_run_case() {
  local label="$1"; shift
  local scratch before after out rc
  scratch="$(mktemp -d)"
  mkdir -p "$scratch/home" "$scratch/tmp"
  before="$(snapshot "$scratch/home" "$scratch/tmp")"
  out="$(HOME="$scratch/home" TMPDIR="$scratch/tmp" guard "$@" 2>&1)"
  rc=$?
  after="$(snapshot "$scratch/home" "$scratch/tmp")"

  if (( rc != 0 )); then
    err "$label --dry-run exited $rc, expected 0"
  elif [[ "$out" != *"dry-run: would run:"* ]]; then
    err "$label --dry-run printed no 'dry-run: would run:' line"
  elif [[ "$out" != *"dry-run complete; no changes written"* ]]; then
    err "$label --dry-run printed no completion line"
  elif [[ "$before" != "$after" ]]; then
    err "$label --dry-run modified the filesystem:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/       /' >&2
  else
    ok "$label --dry-run previewed the command and wrote nothing"
  fi
  rm -rf "$scratch"
}

dry_run_case "build.sh" "$K/build.sh" --dry-run --tag k8s-toolbox:test
dry_run_case "run.sh"   "$K/run.sh"   --dry-run --tag k8s-toolbox:test --no-kubeconfig
dry_run_case "debug_pod.sh" "$K/debug_pod.sh" --dry-run --pod demo --namespace demo-ns

# The preview must name what it would actually do, or it is decoration.
out="$(guard "$K/build.sh" --dry-run --tag k8s-toolbox:test 2>&1)"
if [[ "$out" == *"docker buildx build"* && "$out" == *"k8s-toolbox:test"* ]]; then
  ok "build.sh --dry-run names the buildx command and the tag"
else
  err "build.sh --dry-run does not show the buildx command it would run"
fi

out="$(guard "$K/debug_pod.sh" --dry-run --pod demo --image custom:1 2>&1)"
if [[ "$out" == *"kubectl"* && "$out" == *"debug"* && "$out" == *"custom:1"* ]]; then
  ok "debug_pod.sh --dry-run names the kubectl debug command and the image"
else
  err "debug_pod.sh --dry-run does not show the kubectl command it would run"
fi

# --------------------------------------------------------------------------
head_ "missing tooling is exit 2, not a crash"
# The runner may well have kubectl and docker installed — GitHub's does — so
# "missing" has to be arranged rather than assumed. PATH is replaced with a
# directory holding one symlink to bash, which the `#!/usr/bin/env bash`
# shebang needs and nothing else does: every one of these paths reaches its
# preflight check without running a single external command.
bare_path="$(mktemp -d)"
ln -s "$BASH" "$bare_path/bash"

PATH="$bare_path" guard "$K/kubectl_pod_diag.sh" --namespace default >/dev/null 2>&1
assert_rc "kubectl_pod_diag.sh without kubectl" 2 "$?"

PATH="$bare_path" guard "$K/debug_pod.sh" --pod demo >/dev/null 2>&1
assert_rc "debug_pod.sh without kubectl" 2 "$?"

PATH="$bare_path" guard "$K/run.sh" --tag k8s-toolbox:test >/dev/null 2>&1
assert_rc "run.sh without docker" 2 "$?"

# ...but a preview still answers, because a preview touches nothing.
out="$(PATH="$bare_path" guard "$K/debug_pod.sh" --dry-run --pod demo 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$out" == *"dry-run: would run:"* ]]; then
  ok "debug_pod.sh --dry-run works without kubectl"
else
  err "debug_pod.sh --dry-run needs kubectl (exit $rc); a preview should not"
fi

rm -rf "$bare_path"

# kubectl_pod_diag.sh is read-only and has no --dry-run to hide behind, so its
# help has to work on a machine with no cluster at all.
guard "$K/kubectl_pod_diag.sh" --help >/dev/null 2>&1
assert_rc "kubectl_pod_diag.sh --help without a cluster" 0 "$?"

# --------------------------------------------------------------------------
head_ "conventions"
for f in "${scripts[@]}"; do
  first="$(head -n 1 -- "$f")"
  if [[ "$first" == "#!/usr/bin/env bash" ]]; then
    ok "${f##*/} shebang"
  else
    err "${f##*/} line 1 is '$first', expected '#!/usr/bin/env bash'"
  fi

  if grep -q 'NO_COLOR' "$f"; then
    ok "${f##*/} honours NO_COLOR"
  else
    err "${f##*/} does not honour NO_COLOR"
  fi

  if grep -Eq '^err\(\) *\{.*>&2' "$f"; then
    ok "${f##*/} sends err() to stderr"
  else
    err "${f##*/} defines err() without redirecting to stderr"
  fi
done

# --------------------------------------------------------------------------
head_ "pinned toolchain"
# versions.env is the single source of truth. A version added there but never
# declared as a build ARG is silently ignored by the image, which is the
# failure mode a pin exists to prevent.
# shellcheck disable=SC1091
. "$K/versions.env"
for var in YQ_VERSION KUBECTL_VERSION HELM_VERSION KUSTOMIZE_VERSION GCLOUD_VERSION; do
  if [[ -n "${!var:-}" ]]; then
    ok "$var is pinned to ${!var}"
  else
    err "$var is missing or empty in versions.env"
  fi
  if grep -q "^ARG ${var}$" "$K/Dockerfile"; then
    ok "Dockerfile declares ARG $var"
  else
    err "Dockerfile does not declare ARG $var, so the pin has no effect"
  fi
  if grep -q -- "--build-arg \"${var}=" "$K/build.sh"; then
    ok "build.sh passes $var to the build"
  else
    err "build.sh does not pass $var, so the Dockerfile default wins"
  fi
done

if [[ -f "$K/.dockerignore" ]]; then
  ok ".dockerignore present"
else
  err "missing .dockerignore — the build context would include tests and docs"
fi

# The image is the whole point of the package; a manifest naming a different
# default tag than build.sh produces is a broken copy/paste waiting to happen.
for manifest in "$K/examples/pod.yaml" "$K/examples/job.yaml"; do
  if [[ -f "$manifest" ]]; then
    ok "${manifest##*/} exists"
  else
    err "missing ${manifest##*/}"
  fi
done

# --------------------------------------------------------------------------
head_ "restricted Pod Security basics"
# The examples are what people copy. Anything pasted from here should already
# satisfy the restricted Pod Security Standard rather than teach the opposite.
for manifest in "$K/examples/pod.yaml" "$K/examples/job.yaml"; do
  [[ -f "$manifest" ]] || continue
  name="${manifest##*/}"
  for want in \
    'runAsNonRoot: true' \
    'allowPrivilegeEscalation: false' \
    'type: RuntimeDefault' \
    'automountServiceAccountToken: false' \
    'drop:' \
    'resources:'
  do
    if grep -q "$want" "$manifest"; then
      ok "$name sets '$want'"
    else
      err "$name is missing '$want'"
    fi
  done
  # `kubectl version --short` was removed in 1.28 and now fails the command
  # rather than shortening its output. helm's --short is unrelated and fine.
  if grep -Eq 'kubectl[^|&;]*--short' "$manifest"; then
    err "$name uses 'kubectl version --short', removed in kubectl 1.28"
  else
    ok "$name uses no removed kubectl flags"
  fi
done

# --------------------------------------------------------------------------
head_ "optional image smoke test"
if [[ "${K8S_IMAGE_SMOKE:-0}" == "1" ]]; then
  printf '[info] K8S_IMAGE_SMOKE=1 — building the image (slow, needs network)\n'
  if guard "$K/build.sh" --tag k8s-toolbox:ci-smoke --platform linux/amd64; then
    ok "image build"
    if docker run --rm k8s-toolbox:ci-smoke -lc '
         set -euo pipefail
         [ "$(id -u)" = "1000" ]
         kubectl version --client=true >/dev/null
         helm version >/dev/null
         kustomize version >/dev/null
         yq --version >/dev/null
         gcloud --version >/dev/null
         gke-gcloud-auth-plugin --version >/dev/null
       '; then
      ok "image runs as uid 1000 with every tool on PATH"
    else
      err "image smoke checks failed"
    fi
  else
    err "image build failed"
  fi
else
  ok "image build skipped — set K8S_IMAGE_SMOKE=1 to build and probe it"
fi

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%d k8s-toolbox check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all k8s-toolbox checks passed (%d scripts) ===\n' "${#scripts[@]}"
exit 0

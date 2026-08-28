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

out="$(guard "$K/build.sh" --help 2>&1)"
if [[ "$out" == *"--variant"* ]]; then
  ok "build.sh --help documents --variant"
else
  err "build.sh --help does not document --variant"
fi

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
  "build.sh --variant"
  "build.sh --platform"
  "run.sh --tag"
  "run.sh --gcloud-config"
  "debug_pod.sh --pod"
  "debug_pod.sh --namespace"
  "debug_pod.sh --image"
  "kubectl_pod_diag.sh --namespace"
  "kubectl_pod_diag.sh --context"
  "kubectl_pod_diag.sh --since"
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

guard "$K/build.sh" --variant --push >/dev/null 2>&1
assert_rc "build.sh --variant --push (flag is not a value)" 3 "$?"

guard "$K/build.sh" --variant foo >/dev/null 2>&1
assert_rc "build.sh --variant foo" 3 "$?"

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
dry_run_case "build.sh --variant debug" "$K/build.sh" --dry-run --variant debug
dry_run_case "run.sh"   "$K/run.sh"   --dry-run --tag k8s-toolbox:test --no-kubeconfig
dry_run_case "debug_pod.sh" "$K/debug_pod.sh" --dry-run --pod demo --namespace demo-ns

gcloud_fixture="$(mktemp -d)"
dry_run_case "run.sh gcloud auth" "$K/run.sh" --dry-run --no-kubeconfig --gcloud-config "$gcloud_fixture"
out="$(guard "$K/run.sh" --dry-run --no-kubeconfig --no-tty \
  --gcloud-config "$gcloud_fixture" -- kubectl get pods -A 2>&1)"
if [[ "$out" == *":ro"* && "$out" == *"--tmpfs"* &&
      "$out" == *"CLOUDSDK_CONFIG"* && "$out" == *"setpriv"* &&
      "$out" == *"kubectl get pods -A"* ]]; then
  ok "run.sh stages gcloud credentials into writable container storage"
else
  err "run.sh gcloud preview is missing read-only source, tmpfs staging, privilege drop, or command"
fi
rm -rf "$gcloud_fixture"

# The preview must name what it would actually do, or it is decoration.
out="$(guard "$K/build.sh" --dry-run --tag k8s-toolbox:test 2>&1)"
if [[ "$out" == *"docker buildx build"* && "$out" == *"k8s-toolbox:test"* ]]; then
  ok "build.sh --dry-run names the buildx command and the tag"
else
  err "build.sh --dry-run does not show the buildx command it would run"
fi

out="$(guard "$K/build.sh" --dry-run 2>&1)"
if [[ "$out" == *"--target toolbox"* && "$out" != *"--target debug"* &&
      "$out" == *"k8s-toolbox:local"* && "$out" != *"k8s-toolbox:debug"* ]]; then
  ok "build.sh --dry-run defaults to --target toolbox and k8s-toolbox:local"
else
  err "build.sh --dry-run does not pin --target toolbox / k8s-toolbox:local"
fi

out="$(guard "$K/build.sh" --dry-run --variant debug 2>&1)"
if [[ "$out" == *"--target debug"* &&
      "$out" == *"k8s-toolbox:debug"* ]]; then
  ok "build.sh --dry-run --variant debug targets debug and tags k8s-toolbox:debug"
else
  err "build.sh --dry-run --variant debug is missing --target debug or the debug tag"
fi

out="$(guard "$K/build.sh" --dry-run --variant debug --tag REGISTRY/k8s-toolbox:1.2.3 2>&1)"
if [[ "$out" == *"--target debug"* &&
      "$out" == *"REGISTRY/k8s-toolbox:1.2.3"* ]]; then
  ok "build.sh --tag wins over the debug default and still passes --target debug"
else
  err "build.sh --variant debug --tag did not keep --target debug or the explicit tag"
fi

out="$(guard "$K/build.sh" --dry-run --pull 2>&1)"
if [[ "$out" == *"--pull"* ]]; then
  ok "build.sh --pull reaches buildx"
else
  err "build.sh --pull was not included in the buildx command"
fi

out="$(guard "$K/debug_pod.sh" --dry-run --pod demo --image custom:1 2>&1)"
if [[ "$out" == *"kubectl"* && "$out" == *"debug"* && "$out" == *"custom:1"* ]]; then
  ok "debug_pod.sh --dry-run names the kubectl debug command and the image"
else
  err "debug_pod.sh --dry-run does not show the kubectl command it would run"
fi

out="$(guard "$K/debug_pod.sh" --dry-run --pod demo -- sh -c 'id && ps' 2>&1)"
if [[ "$out" == *"sh"* && "$out" == *"id\\ \\&\\&\\ ps"* ]]; then
  ok "debug_pod.sh passes a custom command after --"
else
  err "debug_pod.sh did not preserve the custom debug command"
fi

out="$(guard "$K/debug_pod.sh" --dry-run --pod demo --no-tty -- sh -c 'id && ps' 2>&1)"
if [[ "$out" == *"kubectl debug"* && "$out" != *"-it"* &&
      "$out" == *"id\\ \\&\\&\\ ps"* ]]; then
  ok "debug_pod.sh --no-tty preserves a non-interactive custom command"
else
  err "debug_pod.sh --no-tty still allocates a TTY or lost the custom command"
fi

guard "$K/kubectl_pod_diag.sh" --since yesterday >/dev/null 2>&1
assert_rc "kubectl_pod_diag.sh rejects invalid --since" 3 "$?"

# Exercise the valid lookback path with a fake cluster: a 30-minute window
# must include the recent warning and exclude the two-hour-old warning, while
# a wider window includes both. This reaches the Python timestamp filter rather
# than merely checking that argument parsing accepts the value.
mock_bin="$(mktemp -d)"
cat > "$mock_bin/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -u
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get pods "*|*" get pvc "*|*" get nodes "*) printf '{"items":[]}' ;;
  *" get events "*)
    printf '{"items":[%s,%s]}' \
      "{\"metadata\":{\"namespace\":\"demo\"},\"involvedObject\":{\"name\":\"recent\"},\"reason\":\"RecentWarning\",\"message\":\"recent-warning\",\"eventTime\":\"$MOCK_RECENT_EVENT\"}" \
      "{\"metadata\":{\"namespace\":\"demo\"},\"involvedObject\":{\"name\":\"old\"},\"reason\":\"OldWarning\",\"message\":\"old-warning\",\"eventTime\":\"$MOCK_OLD_EVENT\"}"
    ;;
  *) printf 'unexpected mock kubectl command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK_KUBECTL
chmod +x "$mock_bin/kubectl"
MOCK_RECENT_EVENT="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=5)).isoformat().replace("+00:00","Z"))')"
MOCK_OLD_EVENT="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).isoformat().replace("+00:00","Z"))')"
export MOCK_RECENT_EVENT MOCK_OLD_EVENT

out="$(PATH="$mock_bin:$PATH" guard "$K/kubectl_pod_diag.sh" --since 30m 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$out" == *"recent-warning"* &&
                       "$out" != *"old-warning"* &&
                       "$out" == *"last 30m"* ]]; then
  ok "kubectl_pod_diag.sh --since filters mocked warning events"
else
  err "kubectl_pod_diag.sh --since 30m did not enforce the mocked lookback (exit $rc)"
fi

out="$(PATH="$mock_bin:$PATH" guard "$K/kubectl_pod_diag.sh" --since 3h 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$out" == *"recent-warning"* && "$out" == *"old-warning"* ]]; then
  ok "kubectl_pod_diag.sh --since accepts a wider mocked lookback"
else
  err "kubectl_pod_diag.sh --since 3h did not include both mocked events (exit $rc)"
fi
rm -rf "$mock_bin"

# A partial kubectl failure must be exit 1, not a successful "finding". The
# previous path discarded every get exit status with || true and counted the
# empty result as a finding, then exited 0.
fail_bin="$(mktemp -d)"
cat > "$fail_bin/kubectl" <<'MOCK_FAIL'
#!/usr/bin/env bash
set -u
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" get pods "*) exit 1 ;;
  *" get events "*|*" get pvc "*|*" get nodes "*) printf '{"items":[]}'; exit 0 ;;
  *) printf 'unexpected mock kubectl command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK_FAIL
chmod +x "$fail_bin/kubectl"
out="$(PATH="$fail_bin:$PATH" guard "$K/kubectl_pod_diag.sh" --since 30m 2>&1)"
rc=$?
if (( rc == 1 )) && [[ "$out" == *"could not list pods"* ]]; then
  ok "kubectl_pod_diag.sh treats a failed get as exit 1"
else
  err "kubectl_pod_diag.sh did not exit 1 on a failed get (exit $rc)"
fi
rm -rf "$fail_bin"

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
    'automountServiceAccountToken: false'
  do
    if grep -q "$want" "$manifest"; then
      ok "$name sets '$want'"
    else
      err "$name is missing '$want'"
    fi
  done
  # Capability names also appear in comments; match YAML list items only.
  for cap in NET_RAW NET_ADMIN SYS_PTRACE; do
    if grep -Eq "^[[:space:]]+- ${cap}$" "$manifest"; then
      ok "$name adds $cap"
    else
      err "$name is missing YAML list item - $cap"
    fi
  done
  if grep -q 'drop:' "$manifest" && grep -Eq '^[[:space:]]+- ALL$' "$manifest"; then
    ok "$name drops ALL before adding capabilities"
  else
    err "$name is missing drop: ALL"
  fi
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

# --------------------------------------------------------------------------
head_ "optional image smoke test"
if [[ "${K8S_IMAGE_SMOKE:-0}" == "1" ]]; then
  printf '[info] K8S_IMAGE_SMOKE=1 — building toolbox and debug images (slow, needs network)\n'
  # Image downloads legitimately take longer than the 20-second guard used for
  # CLI contract checks. buildx has its own network/process failure reporting.
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

    gcloud_smoke="$(mktemp -d)"
    printf '[core]\nproject = fixture-project\n' > "$gcloud_smoke/config"
    chmod 600 "$gcloud_smoke/config"
    before_gcloud="$(snapshot "$gcloud_smoke" "$gcloud_smoke")"
    if "$K/run.sh" --tag k8s-toolbox:ci-smoke --no-kubeconfig --no-tty \
         --gcloud-config "$gcloud_smoke" -- bash -lc '
           set -euo pipefail
           test -r "$CLOUDSDK_CONFIG/config"
           test -w "$CLOUDSDK_CONFIG"
           grep -q fixture-project "$CLOUDSDK_CONFIG/config"
           printf runtime-only > "$CLOUDSDK_CONFIG/runtime-write"
         '; then
      after_gcloud="$(snapshot "$gcloud_smoke" "$gcloud_smoke")"
      if [[ "$before_gcloud" == "$after_gcloud" && ! -e "$gcloud_smoke/runtime-write" ]]; then
        ok "gcloud config is writable in-container while the host source stays unchanged"
      else
        err "gcloud staging wrote through to the host source"
      fi
    else
      err "gcloud writable staging smoke check failed"
    fi
    rm -rf "$gcloud_smoke"
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

# --------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
  printf '%d k8s-toolbox check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all k8s-toolbox checks passed (%d scripts) ===\n' "${#scripts[@]}"
exit 0

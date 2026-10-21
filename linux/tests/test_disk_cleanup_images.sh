#!/usr/bin/env bash
# disk_cleanup.sh --include-docker-images and --include-snap-revisions against
# stubbed docker, podman and snap: nothing here reaches a real engine or snapd.
set -uo pipefail

# Both are read by disk_cleanup.sh; neither may aim this suite at the host.
unset OS_RELEASE XDG_CACHE_HOME

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLEAN="$REPO_ROOT/linux/disk_cleanup.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/tmp" "$fixture/bin" "$fixture/nosnap" || exit 1
STUB_DIR="$fixture"
export STUB_DIR
checks=0
failures=0
assert_eq() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (expected %s, got %s)\n' "$1" "$2" "$3" >&2
    failures=$((failures + 1))
  fi
}
assert_contains() {
  checks=$((checks + 1))
  if [[ "$2" == *"$3"* ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (missing %s)\n' "$1" "$3" >&2
    printf '%s\n' "$2" | head -20 >&2
    failures=$((failures + 1))
  fi
}
assert_not_contains() {
  checks=$((checks + 1))
  if [[ "$2" == *"$3"* ]]; then
    printf '[fail] %s (unexpected %s)\n' "$1" "$3" >&2
    printf '%s\n' "$2" | head -20 >&2
    failures=$((failures + 1))
  else
    printf '[ ok ] %s\n' "$1"
  fi
}

# docker answers `info` (DOCKER_INFO_RC fails it) and `system df`, and records
# everything else. podman records into its own file.
for engine in docker podman; do
  cat > "$fixture/bin/$engine" <<'STUB'
#!/usr/bin/env bash
engine="${0##*/}"
case "${1:-}" in
  info) exit "${DOCKER_INFO_RC:-0}" ;;
  system)
    printf 'TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\n'
    printf 'Images          5         1         2.1GB     1.8GB (85%%)\n'
    exit 0
    ;;
esac
printf '%s\n' "$*" >> "$STUB_DIR/$engine.calls"
STUB
done
# Two active revisions and two disabled ones; only the disabled may go.
cat > "$fixture/snap.list" <<'LIST'
Name    Version   Rev    Tracking       Publisher   Notes
core20  20230801  1974   latest/stable  canonical** base,disabled
core20  20240111  2182   latest/stable  canonical** base
lxd     5.21.1    28460  5.21/stable    canonical** disabled
lxd     5.21.2    29351  5.21/stable    canonical** -
LIST
cat > "$fixture/bin/snap" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list) cat "$STUB_DIR/snap.list"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$STUB_DIR/snap.calls"
exit "${SNAP_RC:-0}"
STUB
# sudo must never reach the real tools, whoever runs the suite.
cat > "$fixture/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
chmod +x "$fixture/bin/"*

reset_calls() {
  : > "$fixture/docker.calls"
  : > "$fixture/podman.calls"
  : > "$fixture/snap.calls"
}
run_clean() {
  reset_calls
  out="$(PATH="$fixture/bin:$PATH" "$CLEAN" --home "$fixture/home" --tmp "$fixture/tmp" "$@" 2>&1)"
  rc=$?
  docker_calls="$(cat "$fixture/docker.calls")"
  podman_calls="$(cat "$fixture/podman.calls")"
  snap_calls="$(cat "$fixture/snap.calls")"
}

run_clean --include-docker-images --days 2 --yes
assert_eq 'images --yes exits 0' 0 "$rc"
assert_eq 'docker pruned once' 1 "$(grep -c . <<<"$docker_calls")"
assert_eq 'docker prunes unused images older than 48h' 'image prune -a -f --filter until=48h' "$docker_calls"
assert_eq 'podman prunes the same way' 'image prune -a -f --filter until=48h' "$podman_calls"
assert_not_contains 'docker is never asked about volumes' "$docker_calls" 'volume'
assert_not_contains 'podman is never asked about volumes' "$podman_calls" 'volume'
assert_not_contains '--include-docker-images is not --include-docker' "$docker_calls" 'system prune'

run_clean --include-docker-images --days 2 --dry-run
assert_eq 'images dry run exits 0' 0 "$rc"
assert_contains 'dry run previews the prune' "$out" '(dry-run) docker image prune -a -f --filter until=48h'
assert_contains 'dry run says volumes are untouched' "$out" 'volumes untouched'
assert_contains 'dry run shows system df' "$out" 'RECLAIMABLE'
assert_contains 'dry run closes with the summary' "$out" 'dry-run complete; no changes written'
assert_eq 'dry run prunes nothing with docker' '' "$docker_calls"
assert_eq 'dry run prunes nothing with podman' '' "$podman_calls"

run_clean --include-docker-images --days 0 --yes
assert_eq 'images --days 0 exits 0' 0 "$rc"
assert_contains '--days 0 warns that every unused image goes' "$out" 'removes every unused image'
assert_eq '--days 0 prunes without an age filter' 'image prune -a -f' "$docker_calls"

DOCKER_INFO_RC=1 run_clean --include-docker-images --days 2 --yes
assert_eq 'a stopped docker exits 0' 0 "$rc"
assert_contains 'a stopped docker is a warning' "$out" 'docker not running'
assert_eq 'a stopped docker is not pruned' '' "$docker_calls"

run_clean --days 2 --yes
assert_eq 'without the flags the run exits 0' 0 "$rc"
assert_contains 'without the flag images are skipped' "$out" 'skipped: container images (pass --include-docker-images)'
assert_contains 'without the flag snap revisions are skipped' "$out" 'skipped: snap revisions (pass --include-snap-revisions)'
assert_eq 'without the flags nothing is pruned' '' "$docker_calls$podman_calls$snap_calls"

run_clean --include-snap-revisions --yes --no-sudo
assert_eq 'snap under --no-sudo exits 0' 0 "$rc"
assert_contains 'snap under --no-sudo is skipped' "$out" 'skipped (needs root)'
assert_eq 'snap under --no-sudo removes nothing' '' "$snap_calls"

run_clean --include-snap-revisions --yes
assert_eq 'snap --yes exits 0' 0 "$rc"
assert_eq 'exactly the two disabled revisions are removed' 2 "$(grep -c . <<<"$snap_calls")"
assert_contains 'the disabled core20 revision goes' "$snap_calls" 'remove core20 --revision=1974'
assert_contains 'the disabled lxd revision goes' "$snap_calls" 'remove lxd --revision=28460'
assert_not_contains 'the active core20 revision stays' "$snap_calls" '2182'
assert_not_contains 'the active lxd revision stays' "$snap_calls" '29351'
assert_contains 'the retain setting is suggested' "$out" 'refresh.retain=2'

run_clean --include-snap-revisions --dry-run
assert_eq 'snap dry run exits 0' 0 "$rc"
assert_contains 'snap dry run lists the first removal' "$out" 'snap remove core20 --revision=1974'
assert_contains 'snap dry run lists the second removal' "$out" 'snap remove lxd --revision=28460'
assert_eq 'snap dry run removes nothing' '' "$snap_calls"

SNAP_RC=1 run_clean --include-snap-revisions --yes
assert_eq 'a failed snap remove -> 1' 1 "$rc"
assert_contains 'a failed snap remove is reported' "$out" 'failed'

# No snap at all: a PATH with the stubs but without snap. If the host itself
# has a real snap in /usr/bin or /bin, the absence cannot be staged here.
for tool in docker podman sudo; do
  ln -sf "$fixture/bin/$tool" "$fixture/nosnap/$tool"
done
if PATH="/usr/bin:/bin" command -v snap >/dev/null 2>&1; then
  assert_eq 'snap absence cannot be staged on this host; skipped' 1 1
else
  out="$(PATH="$fixture/nosnap:/usr/bin:/bin" "$CLEAN" --home "$fixture/home" --tmp "$fixture/tmp" \
    --include-snap-revisions --dry-run 2>&1)"; rc=$?
  assert_eq 'no snap exits 0' 0 "$rc"
  assert_contains 'no snap says so' "$out" 'snap not installed'
fi

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s disk cleanup image checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s disk cleanup image checks passed ===\n' "$checks"

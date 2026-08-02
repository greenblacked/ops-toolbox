#!/usr/bin/env bash
# Run the MikroTik script integration tests against RouterOS CHR 7.22 in Docker.
# Host requirement: Docker (with compose v2). No host Python or pip needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$HERE/docker-compose.yml"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-pretty-useful-mikrotik}"
export COMPOSE_PROJECT_NAME

# CHR boots under QEMU. With /dev/kvm it takes a minute; without it, TCG
# emulation takes many. The device cannot be declared conditionally in compose
# and naming a missing one is fatal, so it lives in an overlay we add only when
# the host actually has it — Linux CI does, macOS and Docker Desktop do not.
COMPOSE_FILES=(-f "$COMPOSE_FILE")
if [ "${CHR_KVM:-1}" = "1" ] && [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  COMPOSE_FILES+=(-f "$HERE/docker-compose.kvm.yml")
  echo "=== /dev/kvm present — enabling hardware acceleration ==="
fi

cd "$HERE"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose v2 plugin is required" >&2
  exit 1
fi

# --- Local port pre-flight: fail fast if 8728/2222/8080 are taken on the loopback. ---
port_busy() {
  local p="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  else
    (echo > "/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}
busy=()
for p in 8728 2222 8080; do
  port_busy "$p" && busy+=("$p")
done
if [ ${#busy[@]} -gt 0 ]; then
  echo "Ports already in use on 127.0.0.1: ${busy[*]}" >&2
  echo "Stop the conflicting service or override ports in docker-compose.yml." >&2
  exit 1
fi

trap_cleanup() {
  local exit_code=$?
  if [ "${KEEP_CHR:-0}" != "1" ]; then
    if [ "$exit_code" -ne 0 ]; then
      echo "=== docker compose logs (last 200 lines) ==="
      docker compose "${COMPOSE_FILES[@]}" logs --no-color --tail=200 || true
    fi
    echo "=== Stopping stack ==="
    docker compose "${COMPOSE_FILES[@]}" down -v --remove-orphans || true
  else
    echo "KEEP_CHR=1 — leaving the chr container running."
  fi
  exit "$exit_code"
}
trap trap_cleanup EXIT INT TERM

echo "=== Building images (downloads CHR 7.22 on first build) ==="
docker compose "${COMPOSE_FILES[@]}" build

echo "=== Starting CHR (waiting for healthy state)… ==="
# --wait blocks until all started services are healthy or it times out.
docker compose "${COMPOSE_FILES[@]}" up -d --wait --wait-timeout 1800 chr

echo "=== Running pytest (in tester container) ==="
docker compose "${COMPOSE_FILES[@]}" run --rm tester "$@"

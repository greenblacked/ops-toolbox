#!/usr/bin/env bash
# Run Go tooling inside Docker. Host only needs Docker + Compose v2.
#
# Long-running model (fast: reuses one container, cached modules + build):
#   ./run.sh up                       # start dev container in the background
#   ./run.sh go test ./...            # exec inside the running container
#   ./run.sh golangci-lint run
#   ./run.sh govulncheck ./...
#   ./run.sh shell                    # interactive bash
#   ./run.sh logs
#   ./run.sh down
#
# One-shot:
#   ./run.sh --once go test ./...
#   ./run.sh --once --shell
#
# Maintenance:
#   ./run.sh --rebuild                # rebuild image (after Dockerfile change)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
COMPOSE=(docker compose -f "$ROOT/docker/docker-compose.yml")
SERVICE=dev

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 is required" >&2; exit 1; }

once=0
rebuild=0
shell_flag=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)            once=1;        shift ;;
    --rebuild|--build) rebuild=1;     shift ;;
    --shell)           shell_flag=1;  shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if (( rebuild )); then
  "${COMPOSE[@]}" build --pull
fi

case "${1:-}" in
  up)
    shift || true
    exec "${COMPOSE[@]}" up -d --remove-orphans "$SERVICE"
    ;;
  down)
    shift || true
    exec "${COMPOSE[@]}" down --remove-orphans "$@"
    ;;
  logs)
    shift || true
    exec "${COMPOSE[@]}" logs -f "$SERVICE"
    ;;
  ps|status)
    exec "${COMPOSE[@]}" ps
    ;;
  shell)
    shift || true
    "${COMPOSE[@]}" up -d "$SERVICE" >/dev/null
    exec "${COMPOSE[@]}" exec "$SERVICE" bash "$@"
    ;;
esac

if (( once )); then
  if (( shell_flag )) || [[ "${1:-}" == "" ]]; then
    exec "${COMPOSE[@]}" run --rm --entrypoint bash "$SERVICE" "$@"
  fi
  exec "${COMPOSE[@]}" run --rm "$SERVICE" "$@"
fi

if ! "${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx "$SERVICE"; then
  "${COMPOSE[@]}" up -d "$SERVICE" >/dev/null
fi

if (( shell_flag )) || [[ $# -eq 0 ]]; then
  exec "${COMPOSE[@]}" exec "$SERVICE" bash "$@"
fi
exec "${COMPOSE[@]}" exec "$SERVICE" "$@"

#!/usr/bin/env bash
# Build the tester images and run the linux/ script checks in Docker.
#
# Only the debian service runs by default so the suite stays fast enough for
# the default selection. LINUX_DISTROS=all adds fedora and arch; a
# space-separated list picks specific ones.
#
#   ./run.sh                      # debian
#   LINUX_DISTROS=all ./run.sh    # debian fedora arch
#   LINUX_DISTROS="arch" ./run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$HERE/docker-compose.yml"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-pretty-useful-linux-scripts}"
export COMPOSE_PROJECT_NAME

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose v2 plugin is required" >&2
  exit 1
fi

case "${LINUX_DISTROS:-debian}" in
  all) services="debian fedora arch" ;;
  *)   services="${LINUX_DISTROS:-debian}" ;;
esac

cd "$HERE"

overall=0
for service in $services; do
  echo
  echo "=== Building $service tester image ==="
  docker compose -f "$COMPOSE_FILE" build "$service"

  echo "=== Running tests in $service container ==="
  # Each distro runs independently: a failure on arch should not hide whether
  # debian passed, and arch is the one most likely to break for reasons that
  # have nothing to do with this repository.
  if ! docker compose -f "$COMPOSE_FILE" run --rm "$service"; then
    echo "=== $service FAILED ===" >&2
    overall=1
  fi
done

docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true

exit "$overall"

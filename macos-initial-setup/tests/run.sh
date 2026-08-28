#!/usr/bin/env bash
# Build the tester image and run every macos-initial-setup suite in Docker.
# Requires Docker with Compose v2. No host shellcheck, zsh or python required.
#
# Every suite runs even if an earlier one fails, so a single invocation reports
# everything that is broken rather than only the first thing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$HERE/docker-compose.yml"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-pretty-useful-macos-setup}"
export COMPOSE_PROJECT_NAME

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose v2 plugin is required" >&2
  exit 1
fi

cd "$HERE" || exit 1

# One suite, or a subset, e.g. ./run.sh steps
SUITES=("$@")
if (( ${#SUITES[@]} == 0 )); then
  SUITES=(tester steps unprivileged)
fi

echo "=== Building macos-initial-setup tester image ==="
if ! docker compose -f "$COMPOSE_FILE" build; then
  echo "image build failed" >&2
  exit 1
fi

failed=()
for suite in "${SUITES[@]}"; do
  echo
  echo "=== Running suite: $suite ==="
  # -T is load-bearing for the steps suite: `compose run` allocates a TTY when
  # the host has one, and that is exactly the state the cask-skip and keep-alive
  # assertions exist to cover. A launchd job has no controlling terminal.
  if ! docker compose -f "$COMPOSE_FILE" run --rm -T "$suite"; then
    failed+=("$suite")
  fi
done

echo
if (( ${#failed[@]} > 0 )); then
  echo "=== FAILED suites: ${failed[*]} ===" >&2
  exit 1
fi
echo "=== all macos-initial-setup suites passed (${SUITES[*]}) ==="

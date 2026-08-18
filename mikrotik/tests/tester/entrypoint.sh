#!/bin/sh
# Run inside the `tester` container: wait for RouterOS API, then run pytest.
# All extra args are forwarded to pytest, e.g.
#   docker compose run --rm tester -k routeros_version_matches
set -eu

if [ ! -d /repo/mikrotik/tests ]; then
  echo "[tester] /repo/mikrotik/tests not mounted — refusing to run." >&2
  exit 1
fi

echo "[tester] Waiting for RouterOS API at ${ROUTEROS_HOST:-chr}:${ROUTEROS_PORT:-8728}…"
python /repo/mikrotik/tests/wait_for_api.py

echo "[tester] Running pytest."
exec python -m pytest \
  -o "cache_dir=${PYTEST_CACHE_DIR:-/tmp/.pytest_cache}" \
  --rootdir=/repo \
  /repo/mikrotik/tests \
  "$@"

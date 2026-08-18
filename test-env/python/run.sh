#!/usr/bin/env bash
# Run the Python test suite.
#
# No venv, no pip, no network. The modules under test are called by shell
# scripts with the macOS system interpreter and import nothing outside the
# standard library, so their tests are written for stdlib unittest and run
# anywhere python3 exists. ruff and pytest are used when present and skipped
# when not — neither is required to get a verdict.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# On macOS, prefer /usr/bin/python3 explicitly. A bare `python3` on a developer
# machine routinely resolves to a pyenv shim or an activated virtualenv, which
# is not the interpreter stay_fresh.sh will actually use at runtime.
if [[ -n "${PRETTY_USEFUL_PYTHON:-}" ]]; then
  PY="$PRETTY_USEFUL_PYTHON"
elif [[ "$(uname -s)" == "Darwin" && -x /usr/bin/python3 ]]; then
  PY=/usr/bin/python3
else
  PY="$(command -v python3 || true)"
fi

if [[ -z "$PY" ]] || ! "$PY" -c 'import sys' >/dev/null 2>&1; then
  echo "no usable python3 found (set PRETTY_USEFUL_PYTHON to override)" >&2
  exit 1
fi

echo "interpreter: $PY ($("$PY" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))'))"

fail=0

echo
echo "--- unittest ---"
if ! "$PY" -m unittest discover -s "$HERE/tests" -t "$HERE/tests" -v; then
  fail=1
fi

echo
echo "--- ruff ---"
if command -v ruff >/dev/null 2>&1; then
  if ! ruff check "$REPO_ROOT"; then
    fail=1
  fi
else
  echo "ruff not installed — skipped (pip install ruff, or brew install ruff)"
fi

exit "$fail"

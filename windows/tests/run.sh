#!/usr/bin/env bash
# Run the Windows PowerShell contract checks.
#
# Unlike the git/, macos/ and mikrotik/ suites this one needs no Docker. A
# container would buy nothing: the checks need pwsh, and the only assertions
# that survive contact with Linux are static ones, so pulling a ~300 MB
# PowerShell image to run them would be cost without coverage.
#
# PSScriptAnalyzer runs separately in CI's lint job over every tracked *.ps1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
  # Degrades the same way test-env/python/run.sh does for a missing ruff: say
  # what is skipped and how to get it, and do not fail the run.
  echo "pwsh not installed — skipped"
  echo "  macOS:  brew install --cask powershell"
  echo "  Linux:  https://learn.microsoft.com/powershell/scripting/install/install-ubuntu"
  exit 0
fi

echo "=== Running Windows contract checks ==="
exec pwsh -NoProfile -File "$HERE/contract.ps1"

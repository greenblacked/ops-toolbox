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
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

echo "=== Running Windows Git Bash contract checks ==="
bash -n \
  "$REPO_ROOT/windows/git-bash/install_dotfiles.sh" \
  "$REPO_ROOT/windows/git-bash/.aliases" \
  "$REPO_ROOT/windows/git-bash/.bashrc" \
  "$REPO_ROOT/windows/git-bash/.bash_profile"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home"

set +e
status_out="$("$REPO_ROOT/windows/git-bash/install_dotfiles.sh" \
  --status --source "$REPO_ROOT/windows/git-bash" --home "$scratch/home" 2>&1)"
status_rc=$?
set -e
if [[ "$status_rc" != "4" || "$status_out" != *"MISSING"* ]]; then
  echo "[fail] install_dotfiles --status did not report missing targets with exit 4" >&2
  exit 1
fi

cp "$REPO_ROOT/windows/git-bash/.bashrc" "$scratch/home/.bashrc"
cp "$REPO_ROOT/windows/git-bash/.bash_profile" "$scratch/home/.bash_profile"
cp "$REPO_ROOT/windows/git-bash/.aliases" "$scratch/home/.aliases"
"$REPO_ROOT/windows/git-bash/install_dotfiles.sh" \
  --status --source "$REPO_ROOT/windows/git-bash" --home "$scratch/home" >/dev/null

printf '\n# test drift\n' >> "$scratch/home/.aliases"
set +e
status_out="$("$REPO_ROOT/windows/git-bash/install_dotfiles.sh" \
  --status --source "$REPO_ROOT/windows/git-bash" --home "$scratch/home" 2>&1)"
status_rc=$?
set -e
if [[ "$status_rc" != "4" || "$status_out" != *"DRIFT"* ]]; then
  echo "[fail] install_dotfiles --status did not report changed targets with exit 4" >&2
  exit 1
fi

namespace_out="$(bash -c '
  kubectl() {
    if [[ "$*" == "config view --minify --output=jsonpath={..namespace}" ]]; then
      printf "team-a"
    else
      printf "%s\n" "$*"
    fi
  }
  . "$1"
  kns
  kns team-b
' bash "$REPO_ROOT/windows/git-bash/.aliases")"
if [[ "$namespace_out" != $'team-a\nconfig set-context --current --namespace=team-b' ]]; then
  echo "[fail] kns did not read and change the current-context namespace" >&2
  exit 1
fi
echo "[ ok ] Git Bash status and namespace helpers"

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

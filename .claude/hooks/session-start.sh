#!/usr/bin/env bash
# session-start.sh
# Prepare a fresh remote coding session so every suite and linter in this
# repository runs the way CI runs them, without a person installing tools by
# hand first.
#
# A remote session starts from a bare clone in a throwaway container. What it
# lacked, measured over real sessions on this repository:
#   - zsh, so the macOS contract suite died at its last check
#   - ShellCheck and ruff at the versions ci.yml pins, so a local pass could
#     still be a CI failure
#   - markdownlint-cli2 at the version the CI action bundles
#   - the layout the macOS Docker suites expect when there is no Docker daemon
#     to run them in: /repo, /.dockerenv, and the two root-owned fixture
#     directories the unprivileged suite points TMPDIR at
#   - the attribution guard that keeps tooling footers out of commits and pull
#     requests, which lives outside the repository and is gone after every
#     container reclaim
#
# Everything here is idempotent and non-interactive. A step that cannot run
# (no network, no root) is reported and skipped; the session still starts.
#
# Usage:
#   ./session-start.sh [--check] [--force] [--help]
#
# Options:
#   --check    Report what is in place and what is missing; change nothing.
#              Exits 1 when something is missing.
#   --force    Run outside a remote session too (by default the script is a
#              no-op unless CLAUDE_CODE_REMOTE=true, so it never touches a
#              developer's own machine)
#
# Exit codes:
#   0   done (or nothing to do)
#   1   --check found something missing, or the script could not read ci.yml
#   3   bad CLI arguments
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CI_FILE="$REPO_ROOT/.github/workflows/ci.yml"

# The one tool version ci.yml does not carry as a variable: the markdownlint
# action is pinned by SHA there, and this is the markdownlint-cli2 release that
# action bundles. Bump it with the action.
MARKDOWNLINT_CLI2_VERSION="0.23.2"

CHECK=0
FORCE=0

err()  { printf '[err ] %s\n' "$*" >&2; }
info() { printf '[info] %s\n' "$*"; }
ok()   { printf '[ ok ] %s\n' "$*"; }
skip() { printf '[skip] %s\n' "$*"; }

usage() {
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

while (( $# > 0 )); do
  case "$1" in
    --check)   CHECK=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; echo >&2; usage >&2; exit 3 ;;
  esac
  shift
done

if (( FORCE == 0 && CHECK == 0 )) && [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  info "not a remote session; nothing to do (pass --force to run anyway)"
  exit 0
fi

# Versions come from ci.yml so this script cannot drift from what CI checks.
ci_version() {
  sed -n "s/^  $1: '\([^']*\)'.*/\1/p" "$CI_FILE" | head -n 1
}
if [[ ! -r "$CI_FILE" ]]; then
  err "cannot read $CI_FILE"
  exit 1
fi
SHELLCHECK_VERSION="$(ci_version SHELLCHECK_VERSION)"
RUFF_VERSION="$(ci_version RUFF_VERSION)"
if [[ -z "$SHELLCHECK_VERSION" || -z "$RUFF_VERSION" ]]; then
  err "could not read SHELLCHECK_VERSION / RUFF_VERSION from ci.yml"
  exit 1
fi

# Root, or sudo without a prompt, is what package installs and the fixture
# directories need. Without either, those steps are reported and skipped.
SUDO=""
if [[ "$(id -u)" != "0" ]]; then
  if sudo -n true 2>/dev/null; then SUDO="sudo -n"; else SUDO="none"; fi
fi
as_root() {
  case "$SUDO" in
    "")     "$@" ;;
    none)   return 1 ;;
    *)      $SUDO "$@" ;;
  esac
}

MISSING=0
missing() { MISSING=$(( MISSING + 1 )); printf '[miss] %s\n' "$*"; }

fetch() {
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --retry-connrefused \
    --connect-timeout 10 --max-time 120 "$1" -o "$2"
}

# Order matters, and it is local-first. This hook gets Claude Code's default
# 60s unless settings.json says otherwise, and steps 1-4 are an apt-get, two
# curls each allowed --max-time 120 with retries, and an npx fetch - minutes
# on the cold container this exists for. The two steps that need no network
# and cannot fail slowly used to be last, so a timeout killed the hook
# mid-fetch and neither ever ran. They run first now, and settings.json sets
# an explicit timeout besides.

# --- 1. the layout the macOS Docker suites expect -------------------------
# There is no Docker daemon in a remote session, so the macos suites cannot
# build their tester image. They can run directly: the steps and unprivileged
# suites refuse to start unless /.dockerenv exists (they clear absolute system
# paths, and that guard is what keeps them off a real machine), they read the
# repository at /repo, and the unprivileged one needs /rootonly (700) and
# /rootlocked (755) exactly as tester/Dockerfile creates them.
# -d /repo is not enough: on a container where /repo is already a bind-mount
# or a symlink to a different checkout, the suites would run against the wrong
# repository while this reported the layout "in place".
if [[ -e /.dockerenv && -d /repo && -d /rootonly && -d /rootlocked ]] \
   && [[ "$(readlink -f /repo)" == "$(readlink -f "$REPO_ROOT")" ]]; then
  ok "macOS suite layout in place (/repo, /.dockerenv, /rootonly, /rootlocked)"
elif (( CHECK )); then
  missing "macOS suite layout (/repo, /.dockerenv, /rootonly, /rootlocked)"
elif [[ "$SUDO" == "none" ]]; then
  skip "macOS suite layout: no root"
else
  layout_ok=1
  as_root touch /.dockerenv || layout_ok=0
  if [[ ! -e /repo ]]; then
    as_root ln -s "$REPO_ROOT" /repo || layout_ok=0
  elif [[ "$(readlink -f /repo)" != "$(readlink -f "$REPO_ROOT")" ]]; then
    # Not ours to repoint, but not a success either: without clearing the flag
    # the block below still announced "macOS suite layout created".
    layout_ok=0
    skip "/repo exists and points elsewhere ($(readlink -f /repo)); left alone"
  fi
  as_root mkdir -p /rootonly /rootlocked && as_root chmod 700 /rootonly && as_root chmod 755 /rootlocked || layout_ok=0
  if (( layout_ok )); then
    ok "macOS suite layout created; run the suites with: bash macos-initial-setup/tests/test_stay_fresh_steps.sh </dev/null"
  else
    skip "macOS suite layout: could not create every piece"
  fi
fi

# --- 2. the attribution guard --------------------------------------------
# Lives in the user's home, not in this repository, and is what a fresh
# container loses. Its installer merges into the existing settings and is safe
# to re-run.
guard_install=""
for candidate in "$HOME"/.claude/skills/*/no-tooling-attribution/scripts/install.sh \
                 "$HOME"/.claude/skills/synced/*/no-tooling-attribution/scripts/install.sh; do
  [[ -f "$candidate" ]] && { guard_install="$candidate"; break; }
done
if [[ -z "$guard_install" ]]; then
  skip "attribution guard: installer not found under ~/.claude/skills"
elif (( CHECK )); then
  if bash "$guard_install" --check >/dev/null 2>&1; then
    ok "attribution guard in place"
  else
    missing "attribution guard (bash '$guard_install')"
  fi
elif bash "$guard_install" >/dev/null 2>&1 && bash "$guard_install" --check >/dev/null 2>&1; then
  ok "attribution guard installed and verified"
else
  skip "attribution guard: installer failed — run: bash '$guard_install'"
fi

# --- 3. packages ----------------------------------------------------------
# zsh: the macOS contract suite sources zsh_aliases.zsh with it.
if command -v zsh >/dev/null 2>&1; then
  ok "zsh present"
elif (( CHECK )); then
  missing "zsh (macOS contract suite needs it)"
elif command -v apt-get >/dev/null 2>&1 && [[ "$SUDO" != "none" ]]; then
  info "installing zsh"
  # Through `env`, not as a prefix assignment: as_root runs `sudo -n`, and
  # sudo's env_reset drops the variable before apt-get ever sees it, so a
  # package that raises a debconf prompt blocked the hook until it was killed.
  # stdin from /dev/null so nothing can wait on an answer either.
  if as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh </dev/null >/dev/null 2>&1; then
    ok "zsh installed"
  else
    skip "zsh: apt-get failed (offline?)"
  fi
else
  skip "zsh: no apt-get or no root"
fi

# --- 4. ShellCheck at the CI version -------------------------------------
have_shellcheck="$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }')"
if [[ "$have_shellcheck" == "$SHELLCHECK_VERSION" ]]; then
  ok "shellcheck $SHELLCHECK_VERSION"
elif (( CHECK )); then
  missing "shellcheck $SHELLCHECK_VERSION (have: ${have_shellcheck:-none})"
elif [[ "$SUDO" == "none" ]]; then
  skip "shellcheck: no root to install into /usr/local/bin (have: ${have_shellcheck:-none})"
else
  info "installing shellcheck $SHELLCHECK_VERSION (have: ${have_shellcheck:-none})"
  tmp="$(mktemp -d)"
  arch="$(uname -m)"
  url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${arch}.tar.xz"
  if fetch "$url" "$tmp/sc.tar.xz" && tar -xJf "$tmp/sc.tar.xz" -C "$tmp" \
     && as_root install -m 0755 "$tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; then
    ok "shellcheck $SHELLCHECK_VERSION installed"
  else
    skip "shellcheck: download or install failed"
  fi
  rm -rf "$tmp"
fi

# --- 5. ruff at the CI version -------------------------------------------
have_ruff="$(ruff --version 2>/dev/null | awk '{ print $2 }')"
if [[ "$have_ruff" == "$RUFF_VERSION" ]]; then
  ok "ruff $RUFF_VERSION"
elif (( CHECK )); then
  missing "ruff $RUFF_VERSION (have: ${have_ruff:-none})"
elif [[ "$SUDO" == "none" ]]; then
  skip "ruff: no root to install into /usr/local/bin (have: ${have_ruff:-none})"
else
  info "installing ruff $RUFF_VERSION (have: ${have_ruff:-none})"
  tmp="$(mktemp -d)"
  case "$(uname -m)" in
    aarch64|arm64) triple="aarch64-unknown-linux-gnu" ;;
    *)             triple="x86_64-unknown-linux-gnu" ;;
  esac
  url="https://github.com/astral-sh/ruff/releases/download/${RUFF_VERSION}/ruff-${triple}.tar.gz"
  if fetch "$url" "$tmp/ruff.tar.gz" && tar -xzf "$tmp/ruff.tar.gz" -C "$tmp" \
     && as_root install -m 0755 "$tmp/ruff-${triple}/ruff" /usr/local/bin/ruff; then
    ok "ruff $RUFF_VERSION installed"
  else
    skip "ruff: download or install failed"
  fi
  rm -rf "$tmp"
fi

# --- 6. markdownlint-cli2, warmed into the npx cache ---------------------
# markdownlint-cli2 has no --help or --version flag, and with no arguments
# it prints usage and exits 1. A glob that matches nothing in an empty
# directory lints zero files and exits 0, which is the probe.
mdl_probe() {
  local d; d="$(mktemp -d)"
  ( cd "$d" && npx "$@" "markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}" '*.md' ) >/dev/null 2>&1
  local rc=$?
  rm -rf "$d"
  return "$rc"
}
if command -v npx >/dev/null 2>&1; then
  if (( CHECK )); then
    if mdl_probe --no-install; then
      ok "markdownlint-cli2 $MARKDOWNLINT_CLI2_VERSION cached"
    else
      missing "markdownlint-cli2 $MARKDOWNLINT_CLI2_VERSION in the npx cache"
    fi
  elif mdl_probe -y; then
    ok "markdownlint-cli2 $MARKDOWNLINT_CLI2_VERSION cached"
  else
    skip "markdownlint-cli2: npx fetch failed (offline?)"
  fi
else
  skip "markdownlint-cli2: no npx"
fi

if (( CHECK )); then
  if (( MISSING > 0 )); then
    err "$MISSING item(s) missing; run without --check to install them"
    exit 1
  fi
  ok "everything in place"
fi
exit 0

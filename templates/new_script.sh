#!/usr/bin/env bash
# Starting point for a new Bash helper in this repository. Copy it, rename it,
# and delete what you do not need. It is a working no-op as it stands, so the
# test suites exercise this file directly — if the template ever stops meeting
# the conventions in CONTRIBUTING.md, CI says so.
#
# Pick the `set` line that matches the package you are writing in:
#   set -euo pipefail            short, single-purpose scripts (git/)
#   set -u; set -o pipefail      long maintenance runs (macos-initial-setup/, linux/)
set -euo pipefail

# --- output ----------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# --- defaults --------------------------------------------------------------
DRY_RUN=0
TARGET=""

usage() {
  cat <<EOF
$(basename "$0") - one-line summary of what this script does

Usage:
  $(basename "$0") [--target NAME] [--dry-run]

Options:
  --target NAME   What to operate on (default: everything)
  --dry-run       Show what would happen without changing anything
  -h, --help      Show this help

Exit codes: 0 success, 1 failure, 2 wrong environment, 3 usage, 4 nothing to do
EOF
}

# Byte-identical to git/git_sync_default.sh:25-33 — see CONTRIBUTING.md for why
# this is copied rather than sourced from a shared library.
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

# --- arguments -------------------------------------------------------------
# --help is handled here, before any preflight check, so it keeps working on a
# machine this script would otherwise refuse to run on.
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --target)  require_value "$1" "${2:-}"; TARGET="$2"; shift ;;
    --target=*) TARGET="${1#*=}"; require_value "--target" "$TARGET" ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

# --- preflight -------------------------------------------------------------
# Wrong environment is exit 2. Example:
#   if [[ "$(uname -s)" != "Darwin" ]]; then
#     err "this script only runs on macOS"
#     exit 2
#   fi

# --- helpers ---------------------------------------------------------------
run() {
  if (( DRY_RUN == 1 )); then
    printf "dry-run: would run: %s\n" "$*"
  else
    "$@"
  fi
}

# --- main ------------------------------------------------------------------
main() {
  if [[ -n "$TARGET" ]]; then
    info "target: $TARGET"
  else
    info "no target given; operating on everything"
  fi

  run true

  if (( DRY_RUN == 1 )); then
    printf "dry-run complete; no changes written\n"
    return 0
  fi

  ok "done"
}

main

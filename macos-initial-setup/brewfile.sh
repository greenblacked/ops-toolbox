#!/usr/bin/env bash
# brewfile.sh
# Capture and restore the Homebrew side of a machine.
#
# install_apps.sh and install_devtools.sh install a curated list decided in
# advance. This is the other direction: record what a machine actually has now,
# keep that under version control, and reproduce it elsewhere. The two are
# complementary — the curated scripts are the intent, the Brewfile is the fact.
#
# Usage:
#   ./brewfile.sh dump      [--file PATH] [--force]
#   ./brewfile.sh check     [--file PATH]
#   ./brewfile.sh install   [--file PATH] [--dry-run]
#   ./brewfile.sh diff      [--file PATH]
#
# Commands:
#   dump     Write the current formulae/casks/taps/App Store apps to a Brewfile
#   check    Report whether everything in the Brewfile is installed (read-only)
#   install  Install everything the Brewfile lists that is missing
#   diff     Show what dump would change, without writing
#
# Exit codes:
#   0   success (for `check`: everything present)
#   1   command failed (for `check`: something is missing)
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FILE="$SCRIPT_DIR/Brewfile"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# Print the leading comment block, stopping at the first line that is not a
# comment. A hardcoded line range silently starts printing code the moment the
# header grows or shrinks.
usage() {
  awk 'NR == 1 { next }
       /^#/    { sub(/^# ?/, ""); print; next }
       { exit }' "$0"
}

CMD=""
FILE="$DEFAULT_FILE"
FORCE=0
DRY_RUN=0

while (( $# > 0 )); do
  case "$1" in
    dump|check|install|diff)
      if [[ -n "$CMD" ]]; then err "only one command at a time"; exit 3; fi
      CMD="$1"
      ;;
    --file) shift; [[ $# -gt 0 ]] || { err "--file needs a path"; exit 3; }; FILE="$1" ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 3 ;;
  esac
  shift
done

if [[ -z "$CMD" ]]; then usage; exit 3; fi

# --- preflight -------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS"
  exit 2
fi
if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew is not installed or not on PATH"
  exit 2
fi
# `brew bundle` is built into Homebrew now, but an old install may still need
# the tap. Check rather than assume, so the failure is legible.
if ! brew bundle --help >/dev/null 2>&1; then
  err "'brew bundle' is unavailable — update Homebrew (brew update)"
  exit 2
fi

case "$CMD" in
  dump)
    if [[ -e "$FILE" ]] && (( FORCE == 0 )); then
      # brew bundle dump refuses to overwrite too, but its message does not say
      # what to compare against first.
      err "$FILE exists — review changes with '$(basename "$0") diff', then pass --force"
      exit 1
    fi
    tmp="$(mktemp)"
    if ! brew bundle dump --file="$tmp" --force; then
      rm -f "$tmp"; err "brew bundle dump failed"; exit 1
    fi
    mv "$tmp" "$FILE"
    ok "wrote $FILE"
    # `grep -c` already prints 0 when nothing matches; it just exits 1 doing so.
    # A `|| echo 0` fallback therefore appends a *second* zero and the summary
    # reads "0 0 taps".
    count_lines() { grep -c "$1" "$FILE" 2>/dev/null || true; }
    printf "  %s%s taps · %s formulae · %s casks%s\n" "$C_DIM" \
      "$(count_lines '^tap ')" "$(count_lines '^brew ')" "$(count_lines '^cask ')" \
      "$C_RESET"
    ;;

  diff)
    if [[ ! -f "$FILE" ]]; then
      err "$FILE does not exist — run '$(basename "$0") dump' first"
      exit 1
    fi
    tmp="$(mktemp)"
    if ! brew bundle dump --file="$tmp" --force; then
      rm -f "$tmp"; err "brew bundle dump failed"; exit 1
    fi
    if diff -u "$FILE" "$tmp" >/dev/null 2>&1; then
      ok "$FILE matches this machine"
      rm -f "$tmp"
      exit 0
    fi
    printf "%s--- %s (committed)\n+++ this machine%s\n" "$C_BOLD" "$FILE" "$C_RESET"
    diff -u "$FILE" "$tmp" | tail -n +3
    rm -f "$tmp"
    info "run '$(basename "$0") dump --force' to accept these"
    ;;

  check)
    if [[ ! -f "$FILE" ]]; then
      err "$FILE does not exist"
      exit 1
    fi
    if brew bundle check --file="$FILE" --verbose; then
      ok "everything in $FILE is installed"
    else
      warn "some entries are missing — '$(basename "$0") install' will add them"
      exit 1
    fi
    ;;

  install)
    if [[ ! -f "$FILE" ]]; then
      err "$FILE does not exist"
      exit 1
    fi
    if (( DRY_RUN )); then
      info "(dry-run) would install anything missing from $FILE:"
      # `check --verbose` lists what is absent without changing anything.
      brew bundle check --file="$FILE" --verbose || true
      exit 0
    fi
    if brew bundle install --file="$FILE" --no-upgrade; then
      ok "Brewfile applied"
    else
      err "brew bundle install reported errors"
      exit 1
    fi
    ;;
esac

#!/usr/bin/env bash
# install_aliases.sh
# Install, inspect or remove the source line that loads bash_aliases.sh from
# ~/.bashrc.
#
# The counterpart of windows/git-bash/install_dotfiles.sh, for the file this
# package already ships. The README's one-liner — echo ". $PWD/bash_aliases.sh"
# >> ~/.bashrc — has the same two failure modes that script was written to
# close: it appends a second copy on every rerun, and it has no uninstall.
# This writes a marked block once, replaces it if the path changes, and takes
# the block back out on uninstall. ~/.bashrc is otherwise left alone.
#
# Exit codes:
#   0   success (for status: the block is present and current)
#   1   install/uninstall failed
#   2   preflight failed (not Linux, or bash_aliases.sh is not next to this)
#   3   bad CLI arguments
#   4   status found the block missing or pointing at a different file
set -u
set -o pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
STATUS=0
UNINSTALL=0
FORCE=0
HOME_DIR="${HOME:-}"
SOURCE_FILE="$SCRIPT_DIR/bash_aliases.sh"
BASHRC_NAME=".bashrc"

BEGIN_MARK="# >>> ops-toolbox bash_aliases >>>"
END_MARK="# <<< ops-toolbox bash_aliases <<<"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
install_aliases.sh - install bash_aliases.sh into ~/.bashrc

Writes a marked block that sources bash_aliases.sh. Running it twice does not
append a second copy. ~/.bashrc is otherwise left alone.

Usage:
  $(basename "$0") [--dry-run] [--source FILE] [--home DIR]
  $(basename "$0") --status [--source FILE] [--home DIR]
  $(basename "$0") --uninstall [--dry-run] [--home DIR]

Options:
  --dry-run       Show what would be written without touching ~/.bashrc
  --status        Report MATCH / DRIFT / MISSING; write nothing
  --uninstall     Remove the marked block this script installed
  --force         Replace a block that points at a different file
  --source FILE   bash_aliases.sh to source (default: next to this script)
  --home DIR      Install into DIR/.bashrc (default: \$HOME)
  --help, -h      Show this help

Exit codes: 0 success, 1 failed, 2 preflight, 3 usage, 4 status is not current
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

# --help is handled here, before any preflight check, so it keeps working on a
# machine this script would otherwise refuse to run on.
while (( $# > 0 )); do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --dry-run)    DRY_RUN=1 ;;
    --status)     STATUS=1 ;;
    --uninstall)  UNINSTALL=1 ;;
    --force)      FORCE=1 ;;
    --source)     require_value "$1" "${2:-}"; SOURCE_FILE="$2"; shift ;;
    --source=*)   SOURCE_FILE="${1#*=}"; require_value "--source" "$SOURCE_FILE" ;;
    --home)       require_value "$1" "${2:-}"; HOME_DIR="$2"; shift ;;
    --home=*)     HOME_DIR="${1#*=}"; require_value "--home" "$HOME_DIR" ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( STATUS == 1 && UNINSTALL == 1 )); then
  err "--status and --uninstall are separate modes; choose one"
  exit 3
fi
if (( DRY_RUN == 1 && STATUS == 1 )); then
  err "--dry-run and --status are separate read-only modes; choose one"
  exit 3
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

if [[ -z "$HOME_DIR" ]]; then
  err "\$HOME is not set; pass --home DIR"
  exit 2
fi
if [[ ! -d "$HOME_DIR" ]]; then
  err "target directory does not exist: $HOME_DIR"
  exit 2
fi

bashrc="$HOME_DIR/$BASHRC_NAME"

abs_source() {
  local path="$1"
  if [[ "$path" != /* ]]; then
    path="$(pwd)/$path"
  fi
  if [[ -e "$path" ]]; then
    (cd -P "$(dirname "$path")" && printf '%s/%s\n' "$(pwd)" "$(basename "$path")")
  else
    printf '%s\n' "$path"
  fi
}

SOURCE_FILE="$(abs_source "$SOURCE_FILE")"

block_text() {
  printf '%s\n' "$BEGIN_MARK"
  printf '. "%s"\n' "$SOURCE_FILE"
  printf '%s\n' "$END_MARK"
}

has_block() {
  [[ -f "$bashrc" ]] || return 1
  grep -F -q "$BEGIN_MARK" "$bashrc" && grep -F -q "$END_MARK" "$bashrc"
}

block_source_path() {
  [[ -f "$bashrc" ]] || return 1
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
    $0 == begin { inblock=1; next }
    $0 == end { inblock=0; next }
    inblock && $1 == "." {
      src=$0
      sub(/^[[:space:]]*\.[[:space:]]+/, "", src)
      gsub(/^"/, "", src); gsub(/"$/, "", src)
      print src
      exit
    }
  ' "$bashrc"
}

strip_block() {
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
    $0 == begin { inblock=1; next }
    $0 == end { inblock=0; next }
    !inblock { print }
  '
}

write_bashrc() {
  local content="$1"
  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s would write %s\n" "$C_DIM" "$C_RESET" "$bashrc"
    printf '%s\n' "$content" | sed 's/^/           /'
    return 0
  fi
  # A managed dotfiles repository usually links ~/.bashrc at a file it owns.
  # `mv` replaces the link rather than following it, so the block landed in a
  # new regular file and the repository quietly stopped being the thing bash
  # read — the block was installed, and every later edit in the repository had
  # no effect. Write to whatever the link resolves to instead, which is the
  # file the user actually maintains.
  local write_to="$bashrc"
  if [[ -L "$bashrc" ]]; then
    write_to="$(readlink -f "$bashrc" 2>/dev/null || printf '%s' "$bashrc")"
    info "$bashrc is a symlink; writing through it to $write_to"
  fi
  local tmp
  tmp="$(mktemp "$(dirname "$write_to")/.bashrc.ops-toolbox.XXXXXX")" || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Preserve the target's own mode; mktemp creates 0600 and the file being
  # replaced is usually 0644.
  if [[ -f "$write_to" ]]; then
    chmod --reference="$write_to" "$tmp" 2>/dev/null || true
  fi
  mv "$tmp" "$write_to"
}

report_status() {
  if ! has_block; then
    printf "MISSING  %s (no ops-toolbox block)\n" "$bashrc"
    return 4
  fi
  local current
  current="$(block_source_path || true)"
  if [[ "$current" == "$SOURCE_FILE" ]]; then
    if [[ -f "$SOURCE_FILE" ]]; then
      printf "MATCH    %s -> %s\n" "$bashrc" "$SOURCE_FILE"
      return 0
    fi
    printf "DRIFT    %s points at missing file: %s\n" "$bashrc" "$SOURCE_FILE"
    return 4
  fi
  printf "DRIFT    %s sources %s (expected %s)\n" "$bashrc" "${current:-unknown}" "$SOURCE_FILE"
  return 4
}

if (( STATUS == 1 )); then
  report_status
  exit $?
fi

if (( UNINSTALL == 1 )); then
  if ! has_block; then
    info "no ops-toolbox block in $bashrc"
    exit 4
  fi
  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s would remove the ops-toolbox block from %s\n" \
      "$C_DIM" "$C_RESET" "$bashrc"
    printf "dry-run complete; no changes written\n"
    exit 0
  fi
  existing="$(cat "$bashrc")"
  stripped="$(printf '%s\n' "$existing" | strip_block)"
  if ! write_bashrc "$stripped"; then
    err "failed to update $bashrc"
    exit 1
  fi
  ok "removed ops-toolbox block from $bashrc"
  exit 0
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
  err "bash_aliases.sh not found at $SOURCE_FILE"
  err "copied on its own into ~/bin, this script has no aliases next to it; pass --source FILE"
  exit 2
fi

new_block="$(block_text)"

if has_block; then
  current="$(block_source_path || true)"
  if [[ "$current" == "$SOURCE_FILE" ]]; then
    ok "already installed: $bashrc -> $SOURCE_FILE"
    exit 0
  fi
  if (( FORCE == 0 )); then
    err "existing block sources ${current:-unknown}; pass --force to replace it"
    exit 1
  fi
  info "replacing block that sourced ${current:-unknown}"
  existing="$(cat "$bashrc")"
  stripped="$(printf '%s\n' "$existing" | strip_block)"
  # Re-append the new block after stripping, with a blank line if needed.
  if [[ -n "$stripped" && "$stripped" != *$'\n' ]]; then
    stripped="$stripped"$'\n'
  fi
  content="${stripped}"$'\n'"$new_block"
else
  if [[ -f "$bashrc" ]]; then
    existing="$(cat "$bashrc")"
    if [[ -n "$existing" && "$existing" != *$'\n' ]]; then
      existing="$existing"$'\n'
    fi
    content="${existing}"$'\n'"$new_block"
  else
    content="$new_block"
  fi
fi

if (( DRY_RUN == 1 )); then
  if [[ ! -f "$bashrc" ]]; then
    printf "  %s(dry-run)%s would create %s\n" "$C_DIM" "$C_RESET" "$bashrc"
  else
    printf "  %s(dry-run)%s would update %s\n" "$C_DIM" "$C_RESET" "$bashrc"
  fi
  printf '%s\n' "$new_block" | sed 's/^/           /'
  printf "dry-run complete; no changes written\n"
  exit 0
fi

if ! write_bashrc "$content"; then
  err "failed to update $bashrc"
  exit 1
fi
ok "installed $SOURCE_FILE into $bashrc"
info "open a new shell, or run: . $bashrc"
exit 0

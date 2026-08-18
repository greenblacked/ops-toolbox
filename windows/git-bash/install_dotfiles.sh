#!/usr/bin/env bash
# Install the Git Bash dotfiles in this folder into $HOME, keeping a backup of
# whatever was there before.
#
# The README's plain `cp` one-liner has two failure modes that are only obvious
# after they have bitten you: it overwrites an existing ~/.bashrc with nothing
# kept, and it will happily install a file with CRLF line endings, which breaks
# backslash line-continuations and throws a syntax error on every prompt redraw
# (README.md, "Troubleshooting", has the full story). This does the same copy
# with those two checks in front of it.

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
FORCE=0
STATUS=0
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-}"

# The three files this repository owns. Anything else in $HOME is left alone.
DOTFILES=".bashrc .bash_profile .aliases"

# One stamp for the whole run, so a set of backups taken together is obvious
# from the names alone.
STAMP="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<EOF
install_dotfiles.sh - install the Git Bash dotfiles into \$HOME

Usage:
  $(basename "$0") [--dry-run | --status] [--force] [--source DIR] [--home DIR]

Options:
  --dry-run       Show what would be copied without writing anything
  --status        Report MATCH / DRIFT / MISSING for each target; write nothing
  --force         Install even if a source file has CRLF line endings
  --source DIR    Copy from DIR (default: the folder holding this script)
  --home DIR      Copy into DIR (default: \$HOME)
  -h, --help      Show this help

Installs: $DOTFILES
An existing file is copied to <name>.backup-<timestamp> before being replaced;
a file that already matches the source is left alone.

Exit codes: 0 success/current, 1 CRLF line endings in a source file, 2 wrong
environment (no source files, or no target directory), 3 usage, 4 status found
one or more missing or different target files
EOF
}

# Byte-identical to git/git_sync_default.sh:25-33 - see CONTRIBUTING.md for why
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
    -h|--help)  usage; exit 0 ;;
    --dry-run)  DRY_RUN=1 ;;
    --status)   STATUS=1 ;;
    --force)    FORCE=1 ;;
    --source)   require_value "$1" "${2:-}"; SOURCE_DIR="$2"; shift ;;
    --source=*) SOURCE_DIR="${1#*=}"; require_value "--source" "$SOURCE_DIR" ;;
    --home)     require_value "$1" "${2:-}"; HOME_DIR="$2"; shift ;;
    --home=*)   HOME_DIR="${1#*=}"; require_value "--home" "$HOME_DIR" ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( DRY_RUN == 1 && STATUS == 1 )); then
  err "--dry-run and --status are separate read-only modes; choose one"
  exit 3
fi

# --- preflight -------------------------------------------------------------
if [[ -z "$HOME_DIR" ]]; then
  err "\$HOME is not set; pass --home DIR"
  exit 2
fi
if [[ ! -d "$HOME_DIR" ]]; then
  err "target directory does not exist: $HOME_DIR"
  exit 2
fi

# Copied on its own into ~/bin, this script has no dotfiles next to it. Say so
# and name the flag that fixes it, rather than reporting three missing files.
missing=""
for name in $DOTFILES; do
  [[ -f "$SOURCE_DIR/$name" ]] || missing="$missing $name"
done
if [[ -n "$missing" ]]; then
  err "no$missing in $SOURCE_DIR - pass --source pointing at a checkout of windows/git-bash"
  exit 2
fi

# --- helpers ---------------------------------------------------------------
# printf %q rather than a bare "$*": Git Bash's $HOME is under C:\Users, which
# routinely contains a space, and a dry-run line you cannot paste is a dry-run
# line that lies about what would happen.
print_cmd() {
  printf "dry-run: would run:"
  for arg in "$@"; do
    printf " %s" "$(printf "%q" "$arg")"
  done
  printf "\n"
}

run() {
  if (( DRY_RUN == 1 )); then
    print_cmd "$@"
  else
    "$@"
  fi
}

# Git Bash reads these files with a real bash, which treats a trailing CR as
# part of the line: `cmd \<CR><LF>` escapes the CR instead of the newline and
# the continuation silently breaks. LC_ALL=C keeps grep from deciding a file is
# binary and answering with a summary line instead of a match.
has_crlf() {
  LC_ALL=C grep -q $'\r' "$1"
}

# --- main ------------------------------------------------------------------
if (( DRY_RUN == 1 )); then
  info "dry run - nothing will be written"
fi
info "source: $SOURCE_DIR"
info "target: $HOME_DIR"

crlf=""
for name in $DOTFILES; do
  if has_crlf "$SOURCE_DIR/$name"; then
    crlf="$crlf $name"
  fi
done
if [[ -n "$crlf" ]]; then
  if (( FORCE == 1 )); then
    warn "CRLF line endings in:$crlf - installing anyway (--force)"
    warn "expect a syntax error on every prompt redraw; see README.md"
  else
    err "CRLF line endings in:$crlf"
    err "these break line continuations in Git Bash. Fix the source files with:"
    # The sed expression goes through as an argument, not as part of the format
    # string, so printf cannot turn the \r in it into an actual carriage return.
    for name in $crlf; do
      printf "  sed -i %s %s\n" "'s/\r\$//'" "$SOURCE_DIR/$name" >&2
    done
    err "or pass --force to install them as they are"
    exit 1
  fi
fi

if (( STATUS == 1 )); then
  drift=0
  for name in $DOTFILES; do
    src="$SOURCE_DIR/$name"
    dest="$HOME_DIR/$name"
    if [[ ! -e "$dest" ]]; then
      printf 'MISSING %s\n' "$dest"
      drift=$((drift + 1))
    elif [[ ! -f "$dest" ]]; then
      printf 'DRIFT   %s (not a regular file)\n' "$dest"
      drift=$((drift + 1))
    elif cmp -s "$src" "$dest"; then
      printf 'MATCH   %s\n' "$dest"
    else
      printf 'DRIFT   %s\n' "$dest"
      drift=$((drift + 1))
    fi
  done
  (( drift == 0 )) && exit 0
  exit 4
fi

installed=0
unchanged=0
for name in $DOTFILES; do
  src="$SOURCE_DIR/$name"
  dest="$HOME_DIR/$name"

  # Re-running this must be a no-op, not three new backups of identical files.
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    ok "$name is already up to date"
    unchanged=$((unchanged + 1))
    continue
  fi

  if [[ -L "$dest" ]]; then
    # A managed dotfiles repository usually links ~/.bashrc at a file it owns.
    # `cp` follows that link, so the write landed inside the repository rather
    # than in $HOME — and `cp -p` copied the resolved *content* into the
    # backup, leaving nothing that could put the link back. Replace the link
    # itself and leave whatever it pointed at alone.
    link_target="$(readlink "$dest")"
    warn "$name in $HOME_DIR is a symlink to $link_target"
    warn "  replacing the link; $link_target is left untouched"
    run cp -P "$dest" "$dest.backup-$STAMP"
    info "backed up the $name symlink to $name.backup-$STAMP"
    run rm -f "$dest"
  elif [[ -e "$dest" ]]; then
    # The file being replaced can carry CRLF of its own, from an earlier copy
    # made through an editor or a chat client. Say so: it is the likeliest
    # reason the shell you are replacing was throwing a syntax error on every
    # prompt, and the backup keeps a copy of it in that state.
    if [[ -f "$dest" ]] && has_crlf "$dest"; then
      warn "the $name already in $HOME_DIR has CRLF line endings; replacing it with the LF copy"
    fi
    run cp -p "$dest" "$dest.backup-$STAMP"
    info "backed up $name to $name.backup-$STAMP"
  fi
  run cp "$src" "$dest"
  installed=$((installed + 1))
done

if (( DRY_RUN == 1 )); then
  printf "dry-run complete; no changes written\n"
  exit 0
fi

if (( installed == 0 )); then
  ok "all $unchanged file(s) already matched the source; nothing to do"
  exit 0
fi

ok "installed $installed file(s) into $HOME_DIR"
info "open a new Git Bash window, or run: source ~/.bash_profile"

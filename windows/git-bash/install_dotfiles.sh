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
#
# --status says whether each installed file matches; --diff shows how it does
# not, so local edits worth keeping can be moved to ~/.bashrc.local before an
# install replaces them.
#
# Every install leaves <name>.backup-<stamp> files behind, so it also offers
# the way back: --list-backups shows the sets, --restore puts one back (saving
# what it replaces as a new set first, so a rollback is itself undoable), and
# --prune-backups deletes all but the newest sets once --yes says so. None of
# the three needs the source files, so they work from a copy in ~/bin alone.

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
DIFF=0
LIST_BACKUPS=0
RESTORE_STAMP=""
PRUNE_KEEP=""
YES=0
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
  $(basename "$0") [--dry-run | --status | --diff] [--force] [--source DIR] [--home DIR]
  $(basename "$0") --list-backups [--home DIR]
  $(basename "$0") --restore STAMP|latest [--dry-run] [--home DIR]
  $(basename "$0") --prune-backups N [--yes | --dry-run] [--home DIR]

Options:
  --dry-run           Show what would be copied without writing anything
  --status            Report MATCH / DRIFT / MISSING for each target; write nothing
  --diff              As --status, plus a unified diff of each drifted target
                      against its source ('-' lines an install would remove);
                      write nothing
  --force             Install even if a source file has CRLF line endings
  --source DIR        Copy from DIR (default: the folder holding this script)
  --home DIR          Copy into DIR (default: \$HOME)
  --list-backups      List the backup sets in the target directory, newest
                      first; write nothing
  --restore STAMP     Put back one backup set (a stamp from --list-backups, or
                      'latest'); the files it replaces are saved as a new set
  --prune-backups N   Delete all backup sets but the newest N; previews unless
                      --yes is given
  --yes               Confirm the deletion --prune-backups previews
  -h, --help          Show this help

Installs: $DOTFILES
An existing file is copied to <name>.backup-<timestamp> before being replaced;
a file that already matches the source is left alone. --status, --diff,
--list-backups, --restore and --prune-backups are separate modes; pass one at
most.

Exit codes: 0 success/current, 1 CRLF line endings in a source file, 2 wrong
environment (no source files, no target directory, or no diff), 3 usage,
4 --status or --diff found one or more missing or different target files, or
there are no backups to list or restore
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
    --diff)     DIFF=1 ;;
    --force)    FORCE=1 ;;
    --source)   require_value "$1" "${2:-}"; SOURCE_DIR="$2"; shift ;;
    --source=*) SOURCE_DIR="${1#*=}"; require_value "--source" "$SOURCE_DIR" ;;
    --home)     require_value "$1" "${2:-}"; HOME_DIR="$2"; shift ;;
    --home=*)   HOME_DIR="${1#*=}"; require_value "--home" "$HOME_DIR" ;;
    --list-backups) LIST_BACKUPS=1 ;;
    --restore)  require_value "$1" "${2:-}"; RESTORE_STAMP="$2"; shift ;;
    --restore=*) RESTORE_STAMP="${1#*=}"; require_value "--restore" "$RESTORE_STAMP" ;;
    --prune-backups) require_value "$1" "${2:-}"; PRUNE_KEEP="$2"; shift ;;
    --prune-backups=*) PRUNE_KEEP="${1#*=}"; require_value "--prune-backups" "$PRUNE_KEEP" ;;
    --yes)      YES=1 ;;
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
if (( DRY_RUN == 1 && DIFF == 1 )); then
  err "--dry-run and --diff are separate read-only modes; choose one"
  exit 3
fi
if (( DRY_RUN == 1 && LIST_BACKUPS == 1 )); then
  err "--dry-run and --list-backups are separate read-only modes; choose one"
  exit 3
fi

# One mode per run. Two at once has no sensible order, and guessing one is how
# a listing turns into a deletion.
modes=()
(( STATUS == 1 )) && modes+=("--status")
(( DIFF == 1 )) && modes+=("--diff")
(( LIST_BACKUPS == 1 )) && modes+=("--list-backups")
[[ -n "$RESTORE_STAMP" ]] && modes+=("--restore")
[[ -n "$PRUNE_KEEP" ]] && modes+=("--prune-backups")
if (( ${#modes[@]} > 1 )); then
  err "${modes[0]} and ${modes[1]} are separate modes; choose one"
  exit 3
fi
if (( YES == 1 )) && [[ -z "$PRUNE_KEEP" ]]; then
  err "--yes only confirms --prune-backups"
  exit 3
fi
if [[ -n "$PRUNE_KEEP" && ! "$PRUNE_KEEP" =~ ^[0-9]+$ ]]; then
  err "--prune-backups takes the number of backup sets to keep, got: $PRUNE_KEEP"
  exit 3
fi
# Base 10 explicitly: 08 is a usage a person types, and bash arithmetic would
# otherwise read it as a malformed octal number.
[[ -z "$PRUNE_KEEP" ]] || PRUNE_KEEP=$((10#$PRUNE_KEEP))

# --- preflight -------------------------------------------------------------
if [[ -z "$HOME_DIR" ]]; then
  err "\$HOME is not set; pass --home DIR"
  exit 2
fi
if [[ ! -d "$HOME_DIR" ]]; then
  err "target directory does not exist: $HOME_DIR"
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
# the continuation silently breaks. Counts the CR bytes with tr: on Git Bash
# (MSYS) grep reads in text mode and drops the CR before matching it.
has_crlf() {
  (( $(LC_ALL=C tr -dc '\r' <"$1" | wc -c) > 0 ))
}

# Every stamp with at least one <name>.backup-<stamp> beside the target, newest
# first. Only the three names this script owns, only directly in $HOME_DIR,
# and only the exact stamp shape this script writes: .bashrc.backup-notes, or
# anything else somebody saved by hand, is never listed, restored or pruned.
backup_stamps() {
  local name f stamp
  for name in $DOTFILES; do
    for f in "$HOME_DIR/$name".backup-*; do
      [[ -e "$f" || -L "$f" ]] || continue
      [[ -d "$f" && ! -L "$f" ]] && continue
      stamp="${f##*.backup-}"
      [[ "$stamp" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] || continue
      printf '%s\n' "$stamp"
    done
  done | sort -u | backup_order
}

# Reads stamps on stdin and prints them newest first: by the timestamp, then
# by the numeric collision suffix (a bare stamp counts as 0), so -10 is newer
# than -9, which a plain text sort gets wrong.
backup_order() {
  local stamp base suffix
  while IFS= read -r stamp; do
    base="${stamp:0:15}"
    suffix="${stamp:16}"
    printf '%s %s %s\n' "$base" "${suffix:-0}" "$stamp"
  done | sort -k1,1r -k2,2nr | while read -r base suffix stamp; do
    printf '%s\n' "$stamp"
  done
}

# The backup files of one set that exist, one path per line.
backup_set_files() {
  local name f
  for name in $DOTFILES; do
    f="$HOME_DIR/$name.backup-$1"
    if [[ -e "$f" || -L "$f" ]]; then
      printf '%s\n' "$f"
    fi
  done
}

# True when $2 already is what restoring $1 would make it: the same link
# target for a symlink backup, the same bytes in a regular file otherwise.
same_as_backup() {
  local backup="$1" dest="$2"
  if [[ -L "$backup" ]]; then
    [[ -L "$dest" && "$(readlink "$backup")" == "$(readlink "$dest")" ]]
  else
    [[ -f "$dest" && ! -L "$dest" ]] && cmp -s "$backup" "$dest"
  fi
}

# --- backup sets -------------------------------------------------------------
# Ahead of the source preflight and the CRLF check on purpose: none of these
# reads the source files, and a rollback is most needed exactly when the copy
# of this script at hand has no checkout beside it.
if (( LIST_BACKUPS == 1 )); then
  stamps="$(backup_stamps)"
  if [[ -z "$stamps" ]]; then
    printf 'no backups in %s\n' "$HOME_DIR"
    exit 4
  fi
  while IFS= read -r stamp; do
    names=""
    for name in $DOTFILES; do
      f="$HOME_DIR/$name.backup-$stamp"
      if [[ -e "$f" || -L "$f" ]]; then
        names="$names $name"
      fi
    done
    printf '%s %s\n' "$stamp" "$names"
  done <<<"$stamps"
  exit 0
fi

if [[ -n "$RESTORE_STAMP" ]]; then
  stamps="$(backup_stamps)"
  if [[ -z "$stamps" ]]; then
    err "no backups in $HOME_DIR to restore"
    exit 4
  fi
  if [[ "$RESTORE_STAMP" == "latest" ]]; then
    stamp="${stamps%%$'\n'*}"
  elif grep -qxF -- "$RESTORE_STAMP" <<<"$stamps"; then
    stamp="$RESTORE_STAMP"
  else
    err "no backup set $RESTORE_STAMP in $HOME_DIR; the sets there are: $(tr '\n' ' ' <<<"$stamps")"
    exit 3
  fi

  # The files being replaced are saved under this run's stamp. If a set with
  # that stamp already exists (restoring a set taken this same second, or an
  # earlier rollback in the same second), saving would overwrite it, so the
  # stamp takes a -1, -2 ... suffix until no managed backup carries it.
  base_stamp="$STAMP"
  suffix=0
  while [[ -n "$(backup_set_files "$STAMP")" ]]; do
    suffix=$((suffix + 1))
    STAMP="$base_stamp-$suffix"
  done
  if (( DRY_RUN == 1 )); then
    info "dry run - nothing will be written"
  fi
  info "restoring the $stamp backup set into $HOME_DIR"
  restored=0
  blocked=0
  for name in $DOTFILES; do
    backup="$HOME_DIR/$name.backup-$stamp"
    dest="$HOME_DIR/$name"
    [[ -e "$backup" || -L "$backup" ]] || continue
    if same_as_backup "$backup" "$dest"; then
      ok "$name already matches the $stamp backup"
      continue
    fi
    if [[ -d "$dest" && ! -L "$dest" ]]; then
      err "$dest is a directory; not replacing it"
      blocked=$((blocked + 1))
      continue
    fi
    # Save what is there now first, the same symlink-aware way an install
    # does, so this rollback can itself be rolled back.
    if [[ -L "$dest" ]]; then
      run cp -P "$dest" "$dest.backup-$STAMP"
      (( DRY_RUN == 1 )) || info "saved the current $name symlink as $name.backup-$STAMP"
    elif [[ -e "$dest" ]]; then
      run cp -p "$dest" "$dest.backup-$STAMP"
      (( DRY_RUN == 1 )) || info "saved the current $name as $name.backup-$STAMP"
    fi
    # Never write through a link: a managed-dotfiles link is replaced, not
    # followed, and a backed-up link comes back as a link.
    if [[ -L "$dest" || -L "$backup" ]]; then
      run rm -f "$dest"
    fi
    if [[ -L "$backup" ]]; then
      run cp -P "$backup" "$dest"
    else
      run cp -p "$backup" "$dest"
    fi
    restored=$((restored + 1))
  done
  # The whole set is processed first, so one blocked file does not keep the
  # others from coming back; the exit status then says the restore was only
  # partial, for a script that checks it.
  if (( DRY_RUN == 1 )); then
    printf "dry-run complete; no changes written\n"
    (( blocked == 0 )) || err "$blocked file(s) in the $stamp set could not be restored"
    (( blocked == 0 )) || exit 1
    exit 0
  fi
  ok "restored $restored file(s) from the $stamp backup set"
  (( restored == 0 )) || info "open a new Git Bash window, or run: source ~/.bash_profile"
  if (( blocked > 0 )); then
    err "partial restore: $blocked file(s) in the $stamp set were not restored because the destination is a directory"
    exit 1
  fi
  exit 0
fi

if [[ -n "$PRUNE_KEEP" ]]; then
  stamps="$(backup_stamps)"
  if [[ -z "$stamps" ]]; then
    ok "no backups in $HOME_DIR; nothing to prune"
    exit 0
  fi
  old="$(tail -n +"$((PRUNE_KEEP + 1))" <<<"$stamps")"
  if [[ -z "$old" ]]; then
    ok "keeping the newest $PRUNE_KEEP backup set(s); nothing older to prune"
    exit 0
  fi
  # Deleting needs --yes. Without it this is a preview, the same one --dry-run
  # prints, so a bare --prune-backups can never delete.
  if (( YES == 0 )); then
    DRY_RUN=1
  fi
  info "keeping the newest $PRUNE_KEEP backup set(s) in $HOME_DIR"
  removed=0
  while IFS= read -r stamp; do
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      run rm -f "$f"
      removed=$((removed + 1))
    done < <(backup_set_files "$stamp")
  done <<<"$old"
  if (( DRY_RUN == 1 )); then
    printf "dry-run complete; no changes written\n"
    (( YES == 1 )) || info "pass --yes to delete these $removed file(s)"
    exit 0
  fi
  ok "removed $removed file(s) from $(wc -l <<<"$old" | tr -d ' ') old backup set(s)"
  exit 0
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

# --status says DRIFT; this says what the drift is, so you can tell your own
# edits worth moving to ~/.bashrc.local from a copy that is simply out of
# date. Read-only like --status, and after the same CRLF check. The diff runs
# installed -> repo: '-' lines are what an install would take out of your
# file, '+' lines what it would put in. No colour: this is piped to pagers.
if (( DIFF == 1 )); then
  if ! command -v diff >/dev/null 2>&1; then
    err "diff not found on PATH"
    exit 2
  fi
  drift=0
  for name in $DOTFILES; do
    src="$SOURCE_DIR/$name"
    dest="$HOME_DIR/$name"
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
      printf 'MISSING %s\n' "$dest"
      drift=$((drift + 1))
    elif [[ ! -f "$dest" ]]; then
      printf 'DRIFT   %s (not a regular file)\n' "$dest"
      drift=$((drift + 1))
    elif cmp -s "$src" "$dest"; then
      printf 'MATCH   %s\n' "$dest"
    else
      printf 'DRIFT   %s\n' "$dest"
      # diff exits 1 when the files differ, which is the expected case here.
      diff -u --label "installed: $dest" --label "repo: $src" "$dest" "$src" || true
      drift=$((drift + 1))
    fi
  done
  printf '%s file(s) differ\n' "$drift"
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

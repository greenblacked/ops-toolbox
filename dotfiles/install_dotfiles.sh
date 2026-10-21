#!/usr/bin/env bash
# install_dotfiles.sh
# Link the tool configuration files in this folder into a home directory, show
# whether the ones already there match, or take the links back out.
#
# Two trees are managed: config/ mirrors ~/.config (XDG_CONFIG_HOME) and home/
# mirrors ~ itself. Every file is linked on its own rather than the directory
# that holds it, so a tool that writes runtime state beside its config - k9s
# clusters, gh hosts.yml, ssh known_hosts - writes it into the home directory
# and never into this repository.
#
# A few files are copied rather than linked, because the tool that owns them
# rewrites the whole file on its own and would strip every comment out of the
# tracked copy: see copy_mode() below. --status reports DRIFT when a copy has
# been edited, which is the reminder to fold the change back into the repo,
# and --diff shows what the edit was.
#
# Nothing here is ever deleted. A file that is already in the way is left
# alone and reported; --force moves it to a timestamped .backup first, the
# same suffix windows/git-bash/install_dotfiles.sh uses. Uninstall removes
# only links that point into this folder, and copies that still match.
# --prune removes the links a renamed or deleted config left behind, and
# nothing else: only links whose text points into this folder.
#
# Exit codes:
#   0   success (for --status: everything matches)
#   1   a link or copy could not be made
#   2   preflight failed (config/ or home/ missing, HOME unset)
#   3   bad CLI arguments
#   4   something was left in place (install: a conflict; status: not current;
#       diff: a file differs)
set -u
set -o pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
STATUS=0
UNINSTALL=0
LIST=0
DIFF=0
PRUNE=0
FORCE=0
QUIET=0
HOME_DIR="${HOME:-}"
HOME_GIVEN=0
CONFIG_DIR=""
ONLY=""

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { (( QUIET )) || printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { (( QUIET )) || printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

usage() {
  cat <<USAGE
install_dotfiles.sh - link the tool configs in config/ and home/ into a home directory

config/ is linked under \$XDG_CONFIG_HOME (default ~/.config) and home/ under ~.
Files are linked one at a time, never whole directories, and nothing that is
already there is deleted or overwritten without --force.

Usage:
  $(basename "$0") [--dry-run] [--force] [--only UNIT ...] [--home DIR] [--config-home DIR]
  $(basename "$0") --status    [--only UNIT ...] [--home DIR] [--config-home DIR]
  $(basename "$0") --uninstall [--dry-run] [--only UNIT ...] [--home DIR] [--config-home DIR]
  $(basename "$0") --list      [--only UNIT ...] [--home DIR] [--config-home DIR]
  $(basename "$0") --diff      [--only UNIT ...] [--home DIR] [--config-home DIR]
  $(basename "$0") --prune     [--dry-run] [--only UNIT ...] [--home DIR] [--config-home DIR]

Options:
  --dry-run          Show what would change; write nothing
  --status           One STATE line per file: MATCH, DRIFT, MISSING, FOREIGN,
                     CONFLICT or ORPHAN; write nothing. Exit 4 unless everything
                     is MATCH
  --uninstall        Remove links that point into this folder, and copies that still match
  --list             Print UNIT, MODE (link or copy), SOURCE and TARGET per file, then exit
  --diff             Unified diff, source against what is on disk, for each DRIFT,
                     CONFLICT or FOREIGN file; write nothing. Exit 4 if any differ
  --prune            Remove ORPHAN links: links into this folder at a path no
                     tracked file installs to, left by a rename or a delete
  --force            Move a file that is in the way to NAME.backup-TIMESTAMP, then install
  --only UNIT        Limit to one unit (repeatable, or comma-separated): a tool
                     directory under config/ such as k9s, or a dotfile under home/
                     with its leading dot dropped, such as ssh or terraformrc
  --home DIR         Install into DIR instead of \$HOME; config/ then goes under DIR/.config
  --config-home DIR  Install config/ into DIR instead of \$XDG_CONFIG_HOME or ~/.config
  --quiet            Suppress informational and success output (errors remain)
  -h, --help         Show this help

Exit codes: 0 success, 1 failed, 2 preflight, 3 usage, 4 something left in place
USAGE
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
    -h|--help)        usage; exit 0 ;;
    --dry-run)        DRY_RUN=1 ;;
    --status)         STATUS=1 ;;
    --uninstall)      UNINSTALL=1 ;;
    --list)           LIST=1 ;;
    --diff)           DIFF=1 ;;
    --prune)          PRUNE=1 ;;
    --force)          FORCE=1 ;;
    --quiet)          QUIET=1 ;;
    --only)           require_value "$1" "${2:-}"; ONLY="${ONLY:+$ONLY,}$2"; shift ;;
    --only=*)         v="${1#*=}"; require_value "--only" "$v"; ONLY="${ONLY:+$ONLY,}$v" ;;
    --home)           require_value "$1" "${2:-}"; HOME_DIR="$2"; HOME_GIVEN=1; shift ;;
    --home=*)         HOME_DIR="${1#*=}"; require_value "--home" "$HOME_DIR"; HOME_GIVEN=1 ;;
    --config-home)    require_value "$1" "${2:-}"; CONFIG_DIR="$2"; shift ;;
    --config-home=*)  CONFIG_DIR="${1#*=}"; require_value "--config-home" "$CONFIG_DIR" ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

modes=$(( STATUS + UNINSTALL + LIST + DIFF + PRUNE ))
if (( modes > 1 )); then
  err "the mode flags are separate modes; choose one"
  exit 3
fi
if (( DRY_RUN == 1 && (STATUS == 1 || LIST == 1 || DIFF == 1) )); then
  err "--dry-run only applies to install, --uninstall and --prune"
  exit 3
fi
if (( FORCE == 1 && modes > 0 )); then
  err "--force only applies to install"
  exit 3
fi

# --- preflight -------------------------------------------------------------
if [[ ! -d "$SCRIPT_DIR/config" || ! -d "$SCRIPT_DIR/home" ]]; then
  err "config/ and home/ must sit next to this script ($SCRIPT_DIR)"
  exit 2
fi
if [[ -z "$HOME_DIR" ]]; then
  err "\$HOME is not set; pass --home DIR"
  exit 2
fi
if (( LIST == 0 )) && [[ ! -d "$HOME_DIR" ]]; then
  err "home directory does not exist: $HOME_DIR"
  exit 2
fi
# Strip a trailing slash so targets print and compare the same either way.
HOME_DIR="${HOME_DIR%/}"
[[ -n "$HOME_DIR" ]] || HOME_DIR="/"
if [[ -z "$CONFIG_DIR" ]]; then
  # XDG_CONFIG_HOME applies to the caller's own home only. A caller that
  # points the script at another home directory wants everything under it.
  if (( HOME_GIVEN == 0 )) && [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    CONFIG_DIR="$XDG_CONFIG_HOME"
  else
    CONFIG_DIR="$HOME_DIR/.config"
  fi
fi
CONFIG_DIR="${CONFIG_DIR%/}"

# --- the file table --------------------------------------------------------
# Files whose owning tool rewrites them in full. Linking these would make the
# tool write its comment-free serialisation straight into the repository the
# first time it saved - k9s does so on every exit, gh on `gh config set`, the
# AWS CLI on `aws configure`, docker on every `docker login`. Everything else
# is linked, so an edit in the repository is live immediately. The README
# says "Installed as a copy" under each of these, and the suite checks that
# the two lists agree.
copy_mode() {
  case "$1" in
    config/k9s/config.yaml)   return 0 ;;
    config/gh/config.yml)     return 0 ;;
    home/.aws/config)         return 0 ;;
    home/.docker/config.json) return 0 ;;
    *)                        return 1 ;;
  esac
}

# Directories that must be private for their tool to accept them at all: ssh
# refuses a config in a world-readable ~/.ssh and gpg warns on every call.
# One list, used by install (to set the mode) and by status (to check it).
PRIVATE_DIRS="home/.ssh home/.gnupg"

# The unit a tracked file belongs to, for --only: the first path component with
# any leading dot dropped, or the file's own stem when it sits directly in the
# tree (config/starship.toml -> starship, home/.terraformrc -> terraformrc).
unit_of() {
  local rel="${1#config/}"
  rel="${rel#home/}"
  local first
  if [[ "$rel" == */* ]]; then
    first="${rel%%/*}"
  else
    first="${rel#.}"
    first="${first%%.*}"
  fi
  printf '%s\n' "${first#.}"
}

target_of() {
  case "$1" in
    config/*) printf '%s/%s\n' "$CONFIG_DIR" "${1#config/}" ;;
    home/*)   printf '%s/%s\n' "$HOME_DIR"   "${1#home/}" ;;
  esac
}

# --only, parsed once into an array; empty means everything.
only_units=()
if [[ -n "$ONLY" ]]; then
  while IFS= read -r u; do
    [[ -n "$u" ]] && only_units+=("$u")
  done < <(printf '%s\n' "$ONLY" | tr ',' '\n')
fi

selected() {
  (( ${#only_units[@]} == 0 )) && return 0
  local unit want
  unit="$(unit_of "$1")"
  for want in "${only_units[@]}"; do
    [[ "$want" == "$unit" ]] && return 0
  done
  return 1
}

# Every regular file under config/ and home/, as a path relative to this
# folder. Discovered, not listed, so a config added later is covered by the
# commit that adds it. Finder droppings and Python caches are the two things
# a checkout grows that are not configs. Sorted so output and tests are stable.
files=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  files+=("${f#./}")
done < <(cd "$SCRIPT_DIR" && find ./config ./home -type f \
  -not -name .DS_Store -not -path '*/__pycache__/*' | sort)

if (( ${#files[@]} == 0 )); then
  err "no files found under $SCRIPT_DIR/config or $SCRIPT_DIR/home"
  exit 2
fi

for want in ${only_units[@]+"${only_units[@]}"}; do
  found=0
  for f in "${files[@]}"; do
    [[ "$(unit_of "$f")" == "$want" ]] && { found=1; break; }
  done
  if (( found == 0 )); then
    err "no such unit: $want (see --list)"
    exit 3
  fi
done

# The private directories that hold at least one selected file, so --only
# git never fails on the mode of ~/.ssh.
selected_private_dirs() {
  local d f
  for d in $PRIVATE_DIRS; do
    for f in "${files[@]}"; do
      [[ "$f" == "$d"/* ]] || continue
      selected "$f" || continue
      printf '%s\n' "$d"
      break
    done
  done
}

# --- helpers ---------------------------------------------------------------
run_cmd() {
  local label="$1"; shift
  if (( DRY_RUN )); then
    printf "  %s(dry-run)%s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    return 0
  fi
  "$@"
}

# `readlink` without -f: macOS 12 has no -f, and the unresolved target is what
# is wanted here anyway - a link that points into this folder is ours, whatever
# it resolves to.
link_target() { readlink "$1" 2>/dev/null || true; }

points_here() {
  local t
  t="$(link_target "$1")"
  [[ -n "$t" && "$t" == "$SCRIPT_DIR"/* ]]
}

# GNU stat first: on Linux `stat -f` is the filesystem form and succeeds with
# the wrong answer, while `stat -c` on macOS fails and falls through.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true; }

# MATCH, DRIFT, MISSING, CONFLICT or FOREIGN for one file. --status adds a
# sixth, ORPHAN, for a path that is not a tracked file's target at all: see
# orphans() below.
#   MATCH    linked to this source, or an identical copy
#   DRIFT    a copy whose content differs from the source
#   MISSING  nothing at the target
#   FOREIGN  a link into this folder, but to a different file
#   CONFLICT an unrelated file, link or directory occupies the target
state_of() {
  local rel="$1" target="$2" src="$SCRIPT_DIR/$1"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    printf 'MISSING\n'; return
  fi
  if copy_mode "$rel"; then
    if [[ -L "$target" || ! -f "$target" ]]; then
      printf 'CONFLICT\n'
    elif cmp -s "$src" "$target"; then
      printf 'MATCH\n'
    else
      printf 'DRIFT\n'
    fi
    return
  fi
  if [[ -L "$target" ]]; then
    if [[ "$(link_target "$target")" == "$src" ]]; then
      printf 'MATCH\n'
    elif points_here "$target"; then
      printf 'FOREIGN\n'
    else
      printf 'CONFLICT\n'
    fi
  else
    printf 'CONFLICT\n'
  fi
}

# Links in the install locations whose text points into this folder at a
# path no tracked file installs to: what renaming or deleting a config in the
# repository leaves behind, which install, --status and --uninstall never see
# because they start from the files that exist today. One path per line.
#
# Only these links. A link to /etc, into another repository, or any regular
# file is never reported, so everything --prune removes was made by this
# installer or a copy of it. The scan is bounded - three levels under the
# config directory, the top of the home, two levels inside each home
# directory this folder installs into (.ssh, .aws ...) - so a large home is
# never walked. find does not follow links below its starting points; -H
# follows a starting point that is itself a link, such as a linked ~/.config.
# A repository that was moved is the documented exception: its old links no
# longer start with this folder's path, so --status calls them CONFLICT.
link_candidates() {
  local d
  if [[ -d "$CONFIG_DIR" ]]; then find -H "$CONFIG_DIR" -maxdepth 3 -type l 2>/dev/null; fi
  find -H "$HOME_DIR" -maxdepth 1 -type l 2>/dev/null
  while IFS= read -r d; do
    d="${d##*/}"
    if [[ -d "$HOME_DIR/$d" ]]; then find -H "$HOME_DIR/$d" -maxdepth 2 -type l 2>/dev/null; fi
  done < <(find "$SCRIPT_DIR/home" -mindepth 1 -maxdepth 1 -type d)
  return 0
}

orphans() {
  local f l rel tracked=""
  for f in "${files[@]}"; do
    tracked="$tracked$(target_of "$f")"$'\n'
  done
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    grep -Fxq -- "$l" <<<"$tracked" && continue
    points_here "$l" || continue
    # A link that --force moved aside is a backup, and backups are never
    # removed.
    case "$l" in *.backup-[0-9]*) continue ;; esac
    if [[ "$l" == "$CONFIG_DIR"/* ]]; then
      rel="config/${l#"$CONFIG_DIR"/}"
    else
      rel="home/${l#"$HOME_DIR"/}"
    fi
    selected "$rel" || continue
    printf '%s\n' "$l"
  done < <(link_candidates | sort -u)
}

# --- modes -----------------------------------------------------------------
do_list() {
  local f mode
  printf '%-14s %-6s %-28s %s\n' "UNIT" "MODE" "SOURCE" "TARGET"
  for f in "${files[@]}"; do
    selected "$f" || continue
    mode='link'
    copy_mode "$f" && mode='copy'
    printf '%-14s %-6s %-28s %s\n' "$(unit_of "$f")" "$mode" "$f" "$(target_of "$f")"
  done
}

# Bare `STATE   path` lines, the shape windows/git-bash/install_dotfiles.sh
# already prints, so `--status | grep '^DRIFT'` means the same for both.
do_status() {
  local f d target st perm not_current=0
  for f in "${files[@]}"; do
    selected "$f" || continue
    target="$(target_of "$f")"
    st="$(state_of "$f" "$target")"
    printf '%-7s %s\n' "$st" "$target"
    [[ "$st" == "MATCH" ]] || not_current=$((not_current + 1))
  done
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    printf '%-7s %s\n' "ORPHAN" "$target"
    not_current=$((not_current + 1))
  done < <(orphans)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    target="$(target_of "$d")"
    [[ -d "$target" ]] || continue
    perm="$(mode_of "$target")"
    if [[ "$perm" != "700" ]]; then
      warn "$target is mode ${perm:-?}; ssh and gpg want 700"
      not_current=$((not_current + 1))
    fi
  done < <(selected_private_dirs)
  (( not_current == 0 )) && return 0
  return 4
}

# Credential values a drifted copy may hold by now - docker login writes
# base64 auths into ~/.docker/config.json, aws configure can write keys - are
# replaced by <redacted> before a line is printed. The key names are matched
# by how they end (auth, token, password, secret, aws_secret_access_key), so
# identitytoken, registrytoken, _authToken and aws_session_token are covered,
# in the JSON "key": "value", the key = value and the key: value forms. BSD
# sed has no case-insensitive flag, hence the bracket classes. Token shapes,
# a password in a URL and private key blocks are redacted wherever they sit.
REDACT_KEYS='[Aa][Uu][Tt][Hh]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Ww][Ss]_[Ss][Ee][Cc][Rr][Ee][Tt]_[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy]'
redact() {
  sed -E \
    -e 's/("[^"]*('"$REDACT_KEYS"')"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"<redacted>"/g' \
    -e 's/('"$REDACT_KEYS"')([[:space:]]*=[[:space:]]*)[^[:space:]].*$/\1\2<redacted>/' \
    -e 's/('"$REDACT_KEYS"')(:[[:space:]]+)[^[:space:]].*$/\1\2<redacted>/' \
    -e 's#(://[^/@[:space:]:]+:)[^/@[:space:]]+@#\1<redacted>@#g' \
    -e 's/AKIA[0-9A-Z]{16}/<redacted>/g' \
    -e 's/ghp_[A-Za-z0-9]{20,}/<redacted>/g' \
    -e 's/glpat-[A-Za-z0-9_-]{20,}/<redacted>/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/<redacted>/g' \
    -e '/BEGIN [A-Z ]*PRIVATE KEY/,/END [A-Z ]*PRIVATE KEY/s/^(.).*$/\1<redacted>/'
}

# The same header line --status prints, then what the file differs by. Only
# DRIFT, CONFLICT and FOREIGN have anything to show; MATCH and MISSING print
# nothing. diff reads both files directly, so nothing is written, not even a
# temp file. Its two path-and-timestamp header lines are dropped so the output
# is stable; plain diff -u, because macOS diff has no --label. A link that
# leads out of this folder is named, never followed and read.
do_diff() {
  local f src target st d shown=0
  for f in "${files[@]}"; do
    selected "$f" || continue
    src="$SCRIPT_DIR/$f"
    target="$(target_of "$f")"
    st="$(state_of "$f" "$target")"
    case "$st" in
      DRIFT|CONFLICT|FOREIGN) ;;
      *) continue ;;
    esac
    printf '%-8s %s\n' "$st" "$target"
    shown=$((shown + 1))
    if [[ -L "$target" ]] && ! points_here "$target"; then
      printf '  links to %s\n' "$(link_target "$target")"
      continue
    fi
    if [[ -d "$target" ]]; then
      if [[ -L "$target" ]]; then printf '  links to %s\n' "$(link_target "$target")"; else printf '  is a directory\n'; fi
      continue
    fi
    if [[ ! -f "$target" ]]; then
      if [[ -L "$target" ]]; then printf '  links to %s\n' "$(link_target "$target")"; else printf '  is not a regular file\n'; fi
      continue
    fi
    if cmp -s "$src" "$target"; then
      printf '  same content as %s\n' "$f"
      continue
    fi
    # Captured first and printed after, so diff's own exit status (1 when the
    # files differ) never meets pipefail.
    d="$(diff -u "$src" "$target")"
    printf '%s\n' "$d" | sed '1,2d' | redact
  done
  (( shown == 0 )) && return 0
  return 4
}

do_install() {
  local f d src target st dir stamp failed=0 conflicts=0 installed=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  for f in "${files[@]}"; do
    selected "$f" || continue
    src="$SCRIPT_DIR/$f"
    target="$(target_of "$f")"
    st="$(state_of "$f" "$target")"

    if [[ "$st" == "MATCH" ]]; then
      ok "already current: $target"
      continue
    fi

    if [[ "$st" != "MISSING" ]]; then
      if (( FORCE == 0 )); then
        warn "$st, left in place: $target (use --force to move it to .backup-$stamp)"
        conflicts=$((conflicts + 1))
        continue
      fi
      run_cmd "back up $st file" mv "$target" "$target.backup-$stamp" || { err "could not move $target aside"; failed=$((failed + 1)); continue; }
    fi

    dir="$(dirname "$target")"
    if [[ ! -d "$dir" ]]; then
      run_cmd "create directory" mkdir -p "$dir" || { err "could not create $dir"; failed=$((failed + 1)); continue; }
    fi

    if copy_mode "$f"; then
      run_cmd "copy $f" cp "$src" "$target" || { err "could not copy to $target"; failed=$((failed + 1)); continue; }
      (( DRY_RUN )) || { chmod 600 "$target" 2>/dev/null || true; }
    else
      run_cmd "link $f" ln -s "$src" "$target" || { err "could not link $target"; failed=$((failed + 1)); continue; }
    fi
    (( DRY_RUN )) || ok "installed: $target"
    installed=$((installed + 1))
  done

  # Private directories are set to 700 whether or not a file was installed
  # into them on this run, so a directory that drifted to 755 is repaired by
  # the next install and not only reported by --status.
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    target="$(target_of "$d")"
    [[ -d "$target" ]] || continue
    [[ "$(mode_of "$target")" == "700" ]] && continue
    run_cmd "private directory" chmod 700 "$target" || warn "could not chmod 700 $target"
  done < <(selected_private_dirs)

  if (( DRY_RUN )); then
    printf "dry-run complete; no changes written\n"
  else
    info "$installed file(s) installed"
  fi
  (( failed > 0 )) && return 1
  (( conflicts > 0 )) && return 4
  return 0
}

do_uninstall() {
  local f target st removed=0 kept=0 failed=0
  for f in "${files[@]}"; do
    selected "$f" || continue
    target="$(target_of "$f")"
    st="$(state_of "$f" "$target")"
    case "$st" in
      MISSING) continue ;;
      MATCH|FOREIGN)
        run_cmd "remove $st" rm "$target" || { err "could not remove $target"; failed=$((failed + 1)); continue; }
        (( DRY_RUN )) || ok "removed: $target"
        removed=$((removed + 1))
        ;;
      DRIFT)
        warn "DRIFT, kept: $target has local edits; move them into $f first"
        kept=$((kept + 1))
        ;;
      CONFLICT)
        warn "CONFLICT, kept: $target is not ours"
        kept=$((kept + 1))
        ;;
    esac
  done
  if (( DRY_RUN )); then
    printf "dry-run complete; no changes written\n"
  else
    info "$removed file(s) removed, $kept kept"
  fi
  (( failed > 0 )) && return 1
  return 0
}

# rm of the link itself: never rm -r, never rmdir. A directory the last
# orphan leaves empty is mentioned and kept; it may be the tool's own.
do_prune() {
  local o parent removed=0 failed=0 emptied=""
  while IFS= read -r o; do
    [[ -n "$o" ]] || continue
    run_cmd "remove ORPHAN" rm "$o" || { err "could not remove $o"; failed=$((failed + 1)); continue; }
    (( DRY_RUN )) && continue
    ok "removed: $o"
    removed=$((removed + 1))
    parent="$(dirname "$o")"
    if [[ -z "$(ls -A "$parent" 2>/dev/null)" ]] && ! grep -Fxq -- "$parent" <<<"$emptied"; then
      emptied="$emptied$parent"$'\n'
      info "left in place, now empty: $parent"
    fi
  done < <(orphans)
  if (( DRY_RUN )); then
    printf "dry-run complete; no changes written\n"
  else
    info "$removed orphan link(s) removed"
  fi
  (( failed > 0 )) && return 1
  return 0
}

# --- main ------------------------------------------------------------------
if (( LIST )); then
  do_list
elif (( STATUS )); then
  do_status
elif (( DIFF )); then
  do_diff
elif (( UNINSTALL )); then
  do_uninstall
elif (( PRUNE )); then
  do_prune
else
  do_install
fi

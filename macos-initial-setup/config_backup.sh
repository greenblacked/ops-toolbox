#!/usr/bin/env bash
# config_backup.sh
# Dated, verified, rotated archive of this Mac's non-secret dotfiles and tool
# configuration, kept before an OS upgrade, a wipe or a risky edit.
#
# brewfile.sh records the software and macos_defaults.sh the preferences. The
# third part of "rebuild this laptop in an hour" is ~/.zshrc, ~/.gitconfig,
# ~/.ssh/config, ~/.aws/config and friends, and nothing snapshotted those.
# The macOS counterpart of linux/config_backup.sh, aimed at the home directory
# rather than /etc: a copy you can keep, not a restore tool. It never writes
# into the paths it archives.
#
# Secrets stay out unless you opt in: a path that holds credentials (private
# keys, ~/.aws/credentials, kubeconfig, Docker and npm auth, the Keychains,
# ~/.gnupg) is refused without --include-secrets. The archive is created 0600,
# in a 0700 directory when the script creates --dest; an existing --dest keeps
# its mode, and a group- or world-accessible one is reported.
#
# Preview first, as everywhere in this package: --dry-run writes nothing, not
# even the destination directory, and a real run needs --yes. Rotation is the
# only deletion, and it touches only PREFIX-YYYYmmdd-HHMMSS.tar.gz files in
# --dest, after the new archive has been verified and published.
#
# Usage:
#   ./config_backup.sh --dry-run
#   ./config_backup.sh --yes
#   ./config_backup.sh --list
#   ./config_backup.sh --yes --paths "$HOME/.config/nvim,$HOME/.kube/kubie.yaml" --keep 14
#
# Exit codes:
#   0   archive written, listed, or previewed
#   1   tar, verification, publication or rotation failed
#   2   preflight failed (not macOS, HOME unset, or tar missing) for a real run
#   3   bad CLI arguments, a refused path or --dest (one other users can
#       write to), or a real run without --yes
#   4   nothing to archive, or nothing to list
set -u
set -o pipefail

DRY_RUN=0
ASSUME_YES=0
LIST=0
LIST_FILE=""
DEST=""
KEEP=7
PREFIX="config"
INCLUDE_SECRETS=0
PATHS=()
TMP_ARCHIVE=""

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
preview() { printf "  %s(dry-run)%s %s\n" "$C_DIM" "$C_RESET" "$*"; }

# Relative to HOME. Each is archived only if it exists.
DEFAULT_SOURCES=".zshrc .zprofile .zshenv .bash_profile .bashrc .gitconfig
.gitignore_global .config/git .ssh/config .aws/config .terraformrc
.tool-versions .config/starship.toml Library/LaunchAgents"

# Relative to HOME. A requested path that is one of these, lies inside one,
# or contains one is refused without --include-secrets. Everything under
# ~/.ssh except config, known_hosts* and public keys, and a ~/.terraformrc
# with a credentials block, and a ~/.aws/config with static keys, are
# matched separately in holds_secret.
SECRET_PATHS=".aws/credentials .kube/config .docker/config.json .netrc .npmrc
.git-credentials .config/git/credentials .config/gh/hosts.yml Library/Keychains
.gnupg .terraform.d/credentials.tfrc.json .pypirc
.config/gcloud/application_default_credentials.json .config/gcloud/credentials.db
.config/gcloud/legacy_credentials"

usage() {
  local defaults
  # shellcheck disable=SC2086  # the source list is split on purpose
  defaults="$(printf '%s\n' $DEFAULT_SOURCES | sed 's|^|  ~/|')"
  cat <<EOF
${C_BOLD}config_backup.sh${C_RESET} — dated archive of this Mac's dotfiles and tool config

Archives the default sources below (or --paths) from your home directory into
a gzip tar in --dest, verifies it, then rotates older copies. Paths that hold
credentials are refused unless --include-secrets. A dry run writes nothing;
a real run requires --yes. This is a copy, not a restore.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") --dry-run [options]
  $(basename "$0") --yes [options]
  $(basename "$0") --list [FILE]

${C_BOLD}Options:${C_RESET}
  --dry-run          Print what would be archived and rotated; write nothing
  --yes, -y          Required for a run that writes
  --list [FILE]      List the members of FILE, or of the newest archive in --dest
  --paths LIST       Comma-separated absolute paths under \$HOME (repeatable;
                     replaces the default sources)
  --dest DIR         Directory for archives (default: ~/ops-toolbox-backups)
  --keep N           Archives to keep, newest first (default: $KEEP; 0 = all)
  --prefix NAME      Filename prefix (default: $PREFIX)
  --include-secrets  Allow paths that hold credentials, with a warning
  -h, --help         Show this help

${C_BOLD}Default sources (each only if it exists):${C_RESET}
$defaults

${C_BOLD}Exit codes:${C_RESET}
  0  archive written, listed, or previewed
  1  tar, verification, publication or rotation failed
  2  preflight failed (not macOS, HOME unset, or tar missing)
  3  bad arguments, a refused path, or a real run without --yes
  4  nothing to archive, or nothing to list
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

add_paths() {
  local item parts
  IFS=',' read -r -a parts <<< "$1"
  for item in ${parts[@]+"${parts[@]}"}; do
    [[ -n "$item" ]] || continue
    PATHS+=("$item")
  done
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    --yes|-y)          ASSUME_YES=1 ;;
    --list)
      LIST=1
      if [[ -n "${2:-}" && "$2" != -* ]]; then
        LIST_FILE="$2"
        shift
      fi
      ;;
    --list=*)          LIST=1; LIST_FILE="${1#*=}"; require_value "--list" "$LIST_FILE" ;;
    --paths)           require_value "$1" "${2:-}"; add_paths "$2"; shift ;;
    --paths=*)         require_value "--paths" "${1#*=}"; add_paths "${1#*=}" ;;
    --dest)            require_value "$1" "${2:-}"; DEST="$2"; shift ;;
    --dest=*)          DEST="${1#*=}"; require_value "--dest" "$DEST" ;;
    --keep)            require_value "$1" "${2:-}"; KEEP="$2"; shift ;;
    --keep=*)          KEEP="${1#*=}"; require_value "--keep" "$KEEP" ;;
    --prefix)          require_value "$1" "${2:-}"; PREFIX="$2"; shift ;;
    --prefix=*)        PREFIX="${1#*=}"; require_value "--prefix" "$PREFIX" ;;
    --include-secrets) INCLUDE_SECRETS=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || (( 10#$KEEP > 3650 )); then
  err "--keep must be an integer between 0 and 3650, got: $KEEP"
  exit 3
fi
KEEP=$((10#$KEEP))

if [[ ! "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
  err "--prefix may contain letters, digits, dot, underscore and hyphen only, got: $PREFIX"
  exit 3
fi

if (( LIST == 0 && DRY_RUN == 0 && ASSUME_YES == 0 )); then
  err "refusing to write an archive without --yes; preview with --dry-run"
  exit 3
fi

# Every path below is built from HOME; an empty one would address /.
if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  err "HOME is not set or not a directory"
  exit 2
fi
HOME_DIR="${HOME%/}"
if [[ -z "$HOME_DIR" ]]; then
  err "HOME is /; refusing to treat the whole disk as a home directory"
  exit 2
fi

if [[ -z "$DEST" ]]; then
  DEST="$HOME_DIR/ops-toolbox-backups"
fi
case "$DEST" in
  /*) ;;
  *)  DEST="$(pwd)/$DEST" ;;
esac
DEST="${DEST%/}"

# Archives this script wrote: PREFIX-YYYYmmdd-HHMMSS.tar.gz, with -N when two
# runs share a second. Nothing else in --dest is listed or rotated.
is_ours() {
  local name="$1" rest
  [[ "$name" == "$PREFIX"-* ]] || return 1
  rest="${name#"$PREFIX"-}"
  [[ "$rest" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?\.tar\.gz$ ]]
}

# Our archives in --dest, newest first. The timestamp in the name orders them,
# then the -N a same-second run adds, so no mtime is consulted; symlinks and
# anything else are left out. Names hold no spaces: the prefix is validated.
our_archives() {
  local f name rest stamp_part seq_part
  [[ -d "$DEST" ]] || return 0
  for f in "$DEST"/"$PREFIX"-*.tar.gz; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    name="${f##*/}"
    is_ours "$name" || continue
    rest="${name#"$PREFIX"-}"
    rest="${rest%.tar.gz}"
    stamp_part="${rest:0:15}"
    seq_part="${rest:16}"
    printf '%s %s %s\n' "$stamp_part" "${seq_part:-1}" "$name"
  done | sort -k1,1r -k2,2nr | cut -d' ' -f3
}

# --- list ------------------------------------------------------------------
if (( LIST )); then
  if [[ -z "$LIST_FILE" ]]; then
    newest="$(our_archives | head -n 1)"
    if [[ -z "$newest" ]]; then
      info "no $PREFIX-*.tar.gz archives in $DEST"
      exit 4
    fi
    LIST_FILE="$DEST/$newest"
  elif [[ ! -f "$LIST_FILE" ]]; then
    err "not an archive: $LIST_FILE"
    exit 3
  fi
  if ! command -v tar >/dev/null 2>&1; then
    err "tar is required"
    exit 2
  fi
  info "listing $LIST_FILE"
  tar -tzf "$LIST_FILE" || exit 1
  exit 0
fi

# --- sources ---------------------------------------------------------------
# Is REL, or anything under it, a place credentials live?
holds_secret() {
  local rel="$1" d
  for d in $SECRET_PATHS; do
    if [[ "$rel" == "$d" || "$rel" == "$d"/* || "$d" == "$rel"/* ]]; then
      return 0
    fi
  done
  # ~/.ssh as a whole holds the private keys, whatever they are named, and a
  # key may sit in a sub-folder. Only the client config, known hosts and
  # public keys are safe. The Terraform CLI config holds API tokens only in
  # a credentials block; the check never prints the file.
  case "$rel" in
    .ssh)                                  return 0 ;;
    .ssh/config|.ssh/known_hosts*|.ssh/*.pub) return 1 ;;
    .ssh/*)                                return 0 ;;
    .terraformrc)
      grep -Eq '^[[:space:]]*credentials[[:space:]]' "$HOME_DIR/.terraformrc" 2>/dev/null \
        && return 0
      ;;
    .aws/config)
      # AWS documents static keys and session tokens in the config file too,
      # in any profile section; key names are case-insensitive.
      grep -Eiq '^[[:space:]]*aws_(access_key_id|secret_access_key|session_token)[[:space:]]*=' \
        "$HOME_DIR/.aws/config" 2>/dev/null && return 0
      ;;
  esac
  return 1
}

# Physical path of $1 (symlinks resolved, BSD-safe: cd -P and pwd -P). A path
# that does not exist yet is resolved through its deepest existing directory
# and the missing tail is appended as written.
canon_path() {
  local p="$1" tail="" base d
  while [[ "$p" != "/" && "$p" == */ ]]; do p="${p%/}"; done
  while :; do
    if [[ -d "$p" ]]; then
      d="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || d=""
      if [[ -n "$d" ]]; then
        if [[ -z "$tail" ]]; then
          printf '%s\n' "$d"
        elif [[ "$d" == "/" ]]; then
          printf '/%s\n' "$tail"
        else
          printf '%s/%s\n' "$d" "$tail"
        fi
        return 0
      fi
    fi
    [[ "$p" == "/" || "$p" != */* ]] && break
    base="${p##*/}"
    tail="${tail:+$base/$tail}"
    tail="${tail:-$base}"
    p="${p%/*}"
    [[ -n "$p" ]] || p="/"
  done
  printf '%s\n' "$1"
}

# Fully resolved path of $1: every directory component through cd -P and
# pwd -P, and a final component that is itself a symlink followed by a
# readlink loop (readlink without -f, which Bash 3.2 / BSD lack). A link loop
# or a chain longer than 40 hops prints nothing and fails, so the caller can
# refuse.
canon_full() {
  local p="$1" n=0 parent t
  while [[ -L "$p" ]]; do
    n=$((n + 1))
    (( n <= 40 )) || return 1
    t="$(readlink "$p")" || return 1
    [[ -n "$t" ]] || return 1
    parent="${p%/*}"
    [[ -n "$parent" ]] || parent="/"
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(canon_path "$parent")/$t" ;;
    esac
  done
  canon_path "$p"
}

# Does the physical location of the absolute path $1 hold credentials,
# although its written form may not look like it? An alias such as
# ~/alias -> ~/.aws makes ~/alias/credentials the same file as
# ~/.aws/credentials, and tar archives it by content. The resolved path is
# judged by holds_secret relative to the resolved HOME, and also against the
# resolved location of every secret path, in case a secret folder is itself
# a link to somewhere else. A path that cannot be resolved is refused.
resolves_to_secret() {
  local c ch rel d cdir
  c="$(canon_full "$1")" || return 0
  [[ -n "$c" ]] || return 0
  ch="$(canon_path "$HOME_DIR")"
  if [[ "$c" == "$ch"/* ]]; then
    rel="${c#"$ch"/}"
    holds_secret "$rel" && return 0
  fi
  for d in $SECRET_PATHS .ssh; do
    cdir="$(canon_full "$HOME_DIR/$d" 2>/dev/null)" || continue
    [[ -n "$cdir" ]] || continue
    if [[ "$d" == ".ssh" ]]; then
      # Only the client config, known hosts and public keys are safe in it,
      # so a path inside the resolved folder is judged by its name there.
      if [[ "$c" == "$cdir" ]]; then
        return 0
      elif [[ "$c" == "$cdir"/* ]]; then
        holds_secret ".ssh/${c#"$cdir"/}" && return 0
      elif [[ "$cdir" == "$c"/* ]]; then
        return 0
      fi
    elif [[ "$c" == "$cdir" || "$c" == "$cdir"/* || "$cdir" == "$c"/* ]]; then
      return 0
    fi
  done
  return 1
}

RELS=()
MISSING=()
# Tar exclusions that keep credentials out of a default run.
EXCLUDES=()
if (( ${#PATHS[@]} > 0 )); then
  for p in "${PATHS[@]}"; do
    p="${p%/}"
    case "$p" in
      /*) ;;
      *) err "--paths takes absolute paths under \$HOME, got: $p"; exit 3 ;;
    esac
    case "$p/" in
      */../*|*/./*|*//*)
        err "refusing $p: it has a '.', '..' or empty component"
        exit 3
        ;;
    esac
    if [[ "$p" == "$HOME_DIR" ]]; then
      err "refusing to archive the whole home directory: $p"
      exit 3
    fi
    if [[ "$p" != "$HOME_DIR"/* ]]; then
      err "refusing $p: it is not under $HOME_DIR"
      exit 3
    fi
    rel="${p#"$HOME_DIR"/}"
    # Judged by the written path and by where it really points.
    if holds_secret "$rel" || resolves_to_secret "$p"; then
      if (( INCLUDE_SECRETS == 0 )); then
        err "refusing to archive $p: it holds credentials (use --include-secrets to override)"
        exit 3
      fi
      warn "--include-secrets: $p holds credentials, and the archive now does too"
    fi
    if [[ -e "$p" || -L "$p" ]]; then
      RELS+=("$rel")
    else
      MISSING+=("$rel")
    fi
  done
else
  for rel in $DEFAULT_SOURCES; do
    if [[ -e "$HOME_DIR/$rel" || -L "$HOME_DIR/$rel" ]]; then
      if (( INCLUDE_SECRETS == 0 )) && [[ "$rel" == ".terraformrc" || "$rel" == ".aws/config" ]] \
         && holds_secret "$rel"; then
        warn "skipped ~/$rel: it holds credentials (use --include-secrets to keep it)"
        continue
      fi
      RELS+=("$rel")
    else
      MISSING+=("$rel")
    fi
  done
fi

if (( INCLUDE_SECRETS == 0 )); then
  # git-credential-store keeps passwords here, inside a default source.
  EXCLUDES+=(--exclude=.config/git/credentials)
fi

# The archive must not land inside something it archives, or each run would
# carry the previous ones. Compared lexically and again by physical path, so
# a --dest reached through a symlink into a source is refused too.
CANON_DEST="$(canon_path "$DEST")"
for rel in ${RELS[@]+"${RELS[@]}"}; do
  canon_src="$(canon_path "$HOME_DIR/$rel")"
  if [[ "$DEST" == "$HOME_DIR/$rel" || "$DEST" == "$HOME_DIR/$rel"/* \
        || "$CANON_DEST" == "$canon_src" || "$CANON_DEST" == "$canon_src"/* ]]; then
    err "--dest $DEST is inside ~/$rel, which is being archived"
    exit 3
  fi
done

# --- preflight -------------------------------------------------------------
# A dry run writes nothing, so like --help it answers on a machine that could
# not do the real work; only a real run needs a Mac with tar on it.
preflight_fail() {
  if (( DRY_RUN == 1 )); then
    warn "$1"
    warn "  (dry-run) previewing anyway; a real run would stop here"
    return 0
  fi
  err "$1"
  exit 2
}
if [[ "$(uname -s)" != "Darwin" ]]; then
  preflight_fail "this script targets macOS (detected: $(uname -s))"
fi
if ! command -v tar >/dev/null 2>&1; then
  preflight_fail "tar is required"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
name="$PREFIX-$stamp.tar.gz"
seq=1
while [[ -e "$DEST/$name" ]]; do
  seq=$((seq + 1))
  name="$PREFIX-$stamp-$seq.tar.gz"
done
ARCHIVE="$DEST/$name"

# Rotation victims if a new archive is published now: everything ours beyond
# the newest KEEP, counting the new one.
rotation_victims() {
  local n=1 old
  (( KEEP == 0 )) && return 0
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    [[ "$old" == "$name" ]] && continue
    n=$((n + 1))
    (( n > KEEP )) && printf '%s\n' "$DEST/$old"
  done <<< "$(our_archives)"
  return 0
}

for m in ${MISSING[@]+"${MISSING[@]}"}; do
  info "not present, skipped: ~/$m"
done

if (( DRY_RUN )); then
  if (( ${#RELS[@]} == 0 )); then
    preview "nothing to archive: none of the sources exist (a real run exits 4)"
  else
    [[ -d "$DEST" ]] || preview "would create $DEST (mode 700)"
    preview "would create $ARCHIVE"
    for rel in "${RELS[@]}"; do
      preview "would archive ~/$rel"
    done
    while IFS= read -r victim; do
      [[ -n "$victim" ]] && preview "would remove $victim"
    done <<< "$(rotation_victims)"
  fi
  printf "dry-run complete; no changes written\n"
  exit 0
fi

if (( ${#RELS[@]} == 0 )); then
  info "nothing to archive: none of the sources exist under $HOME_DIR"
  exit 4
fi

# --- write -----------------------------------------------------------------
# shellcheck disable=SC2329  # run by the EXIT trap below
cleanup() {
  if [[ -n "$TMP_ARCHIVE" && -e "$TMP_ARCHIVE" ]]; then
    rm -f -- "$TMP_ARCHIVE"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Every existing ancestor of the physical --dest must belong to root or this
# user and not be writable by group or other, unless it is sticky (like /tmp):
# anyone who can write to an ancestor can rename the destination away and put
# their own directory in its place.
dir_mode_of() {
  local m
  m="$(stat -f '%Mp%Lp' "$1" 2>/dev/null)"
  [[ "$m" =~ ^[0-7]{3,4}$ ]] || m="$(stat -c %a "$1" 2>/dev/null)"
  printf '%s\n' "$m"
}
dir_owner_of() {
  local o
  o="$(stat -f %u "$1" 2>/dev/null)"
  [[ "$o" =~ ^[0-9]+$ ]] || o="$(stat -c %u "$1" 2>/dev/null)"
  printf '%s\n' "$o"
}
anc="$CANON_DEST"
while [[ "$anc" != "/" && "$anc" == */* ]]; do
  anc="${anc%/*}"
  [[ -n "$anc" ]] || anc="/"
  [[ -d "$anc" ]] || continue
  a_mode="$(dir_mode_of "$anc")"
  a_owner="$(dir_owner_of "$anc")"
  if [[ ! "$a_mode" =~ ^[0-7]{3,4}$ || ! "$a_owner" =~ ^[0-9]+$ ]]; then
    err "refusing --dest $DEST: cannot read the owner and mode of $anc"
    exit 3
  fi
  if [[ "$a_owner" != "0" && "$a_owner" != "$(id -u)" ]]; then
    err "refusing --dest $DEST: $anc is owned by uid $a_owner, not root or you"
    exit 3
  fi
  a_bits=$((8#$a_mode))
  if (( (a_bits & 18) != 0 && (a_bits & 512) == 0 )); then
    err "refusing --dest $DEST: $anc (mode $a_mode) lets other users write to it and rename the destination"
    exit 3
  fi
done

if [[ ! -d "$DEST" ]]; then
  if ! (umask 077 && mkdir -p -- "$DEST"); then
    err "could not create $DEST"
    exit 1
  fi
fi

# An existing --dest keeps the mode it has; say so when others can read it.
# BSD %Lp drops the sticky bit, so ask for the file-type-free 4-digit mode
# (%Mp%Lp: special bits, then permissions); GNU stat -c %a keeps it already.
dest_mode="$(stat -f '%Mp%Lp' "$DEST" 2>/dev/null)"
[[ "$dest_mode" =~ ^[0-7]{3,4}$ ]] || dest_mode="$(stat -c %a "$DEST" 2>/dev/null)"
dest_owner="$(stat -f %u "$DEST" 2>/dev/null)"
[[ "$dest_owner" =~ ^[0-9]+$ ]] || dest_owner="$(stat -c %u "$DEST" 2>/dev/null)"
if [[ ! "$dest_mode" =~ ^[0-7]{3,4}$ ]]; then
  dest_mode=""
fi

# Does an extended ACL on directory $1 let anyone but its owner (or root)
# list it or change its contents? macOS `ls -led` lists the entries under
# the mode line ("0: user:bob allow list,add_file"). Only an allow entry
# counts, with one of the rights that read or modify the directory: list, add_file, add_subdirectory, delete_child, write, append,
# delete, writeattr, writeextattr, writesecurity, chown. The owner's own
# entry, root and wheel are not foreign. Where ls has no -e (GNU ls) or the
# directory has no ACL the answer is no, silently. Prints the principal.
dest_acl_grant() {
  local listing
  listing="$(ls -led -- "$1" 2>/dev/null)" || return 1
  awk '
    NR == 1 { owner = $3; next }
    /^[[:space:]]*[0-9]+: / {
      line = $0
      sub(/^[[:space:]]*[0-9]+: /, "", line)
      i = index(line, " allow ")
      if (i == 0) next
      subject = substr(line, 1, i - 1)
      sub(/ inherited$/, "", subject)
      if (subject == ("user:" owner) || subject == "user:root" || subject == "group:wheel") next
      n = split(substr(line, i + 7), perm, /[ ,]+/)
      for (k = 1; k <= n; k++) {
        if (perm[k] ~ /^(list|write|append|delete|add_file|add_subdirectory|delete_child|writeattr|writeextattr|writesecurity|chown)$/) {
          print subject
          found = 1
          exit
        }
      }
    }
    END { exit !found }
  ' <<<"$listing"
}

# Another user who can write to --dest can plant or swap files in it. Refuse a
# group- or other-writable --dest, except a sticky one (like /tmp) that this
# user owns, where others cannot remove or rename what we create.
if [[ -n "$dest_mode" ]]; then
  dest_bits=$((8#$dest_mode))
  if (( (dest_bits & 18) != 0 )); then      # 022: group or other write
    if (( (dest_bits & 512) != 0 )) && [[ "$dest_owner" == "$(id -u)" ]]; then   # 01000: sticky
      :
    else
      err "refusing --dest $DEST: mode $dest_mode lets other users write to it (chmod go-w, or pick another directory)"
      exit 3
    fi
  fi
  if [[ "${dest_mode: -2}" != "00" ]]; then
    warn "$DEST is mode $dest_mode, readable by others; the archive itself is 0600"
  fi
fi

if acl_who="$(dest_acl_grant "$DEST")"; then
  err "refusing --dest $DEST: an ACL entry for $acl_who lets another principal list or change it (chmod -N, or pick another directory)"
  exit 3
fi

# mktemp creates the file exclusively (O_EXCL) with an unpredictable name and
# mode 0600, and never follows a symlink planted at that name, so tar cannot
# be made to truncate some other file. tar then rewrites our own empty file.
TMP_ARCHIVE="$(mktemp "$DEST/.config_backup.XXXXXX" 2>/dev/null)" || TMP_ARCHIVE=""
if [[ -z "$TMP_ARCHIVE" || ! -f "$TMP_ARCHIVE" || -L "$TMP_ARCHIVE" ]]; then
  TMP_ARCHIVE=""
  err "could not create a temporary archive in $DEST"
  exit 1
fi
# umask 077 keeps the archive 0600 throughout. COPYFILE_DISABLE stops
# macOS tar from adding ._ AppleDouble members for extended attributes. The
# relative names follow --, so none can be read as an option.
if ! (umask 077 && COPYFILE_DISABLE=1 tar -czf "$TMP_ARCHIVE" --exclude=.DS_Store \
      ${EXCLUDES[@]+"${EXCLUDES[@]}"} -C "$HOME_DIR" -- "${RELS[@]}"); then
  err "tar failed; no archive written, previous archives kept"
  exit 1
fi

# A gzip stream tar can read, with at least one member, or it is not a backup.
members="$(tar -tzf "$TMP_ARCHIVE" 2>/dev/null)" || members=""
if [[ -z "$members" ]]; then
  err "the new archive failed verification; previous archives kept"
  exit 1
fi

# mv -n never replaces an existing file; the name was free a moment ago, and
# if it is not now, the temporary file is still there and the run fails.
mv -n -- "$TMP_ARCHIVE" "$ARCHIVE" 2>/dev/null
if [[ -e "$TMP_ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  err "could not publish $ARCHIVE; previous archives kept"
  exit 1
fi
TMP_ARCHIVE=""
ok "wrote $ARCHIVE ($(printf '%s\n' "$members" | wc -l | tr -d ' ') members)"

failed=0
while IFS= read -r victim; do
  [[ -n "$victim" ]] || continue
  if rm -f -- "$victim"; then
    ok "rotated $victim"
  else
    err "could not remove $victim"
    failed=1
  fi
done <<< "$(rotation_victims)"

exit "$failed"

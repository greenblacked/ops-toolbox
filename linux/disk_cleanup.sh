#!/usr/bin/env bash
# disk_cleanup.sh
# Free space on a Linux machine by deleting data that is genuinely safe to
# lose. The counterpart of windows/cleanup/clean_disk_c.ps1.
#
# stay_fresh.sh is recurring maintenance and will upgrade packages; this is
# "I need space now". It never upgrades, never prunes container volumes, and
# never touches documents, downloads or anything under the home directory
# except designated cache and trash locations. Default targets are age-filtered
# temp files the current user owns. Everything else is behind an --include-*
# flag, because those have side effects you should choose knowingly.
#
# A dry run writes nothing. A real run requires --yes, the same gate
# install_devtools.sh uses for anything that changes the machine.
#
# Exit codes:
#   0   success
#   1   one or more deletions failed
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
set -u
set -o pipefail

DRY_RUN=0
ASSUME_YES=0
NO_SUDO=0
DAYS=7
HOME_DIR="${HOME:-}"
TMP_DIR="${TMPDIR:-}"
TMP_OVERRIDE=0
INCLUDE_TRASH=0
INCLUDE_JOURNAL=0
INCLUDE_PKG_CACHE=0
INCLUDE_DEV_CACHES=0
INCLUDE_DOCKER=0
INCLUDE_COREDUMPS=0
COREDUMP_DIR=""
COREDUMP_OVERRIDE=0

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

FAIL_COUNT=0
FREED_BYTES=0
WOULD_BYTES=0

usage() {
  cat <<EOF
disk_cleanup.sh - free space by deleting data that is safe to lose

Default targets are user-owned temp files older than --days, plus thumbnail
caches. Recurring upgrades belong in stay_fresh.sh; this script never installs
or upgrades anything, and docker/podman volumes are never pruned.

Usage:
  $(basename "$0") --dry-run
  $(basename "$0") --yes
  $(basename "$0") --dry-run --include-trash --include-dev-caches

Options:
  --dry-run              Print every deletion without running it
  --yes, -y              Required for a run that actually deletes
  --days N               Only files older than N days (default: $DAYS; 0 = all)
  --home DIR             User profile to clean (default: \$HOME)
  --tmp DIR              Extra temp directory to clean (default: \$TMPDIR)
  --no-sudo              Skip every step that needs root
  --include-trash        Empty ~/.local/share/Trash
  --include-journal      journalctl --vacuum-time matching --days (needs root)
  --include-pkg-cache    apt-get clean / dnf clean / pacman -Sc (needs root)
  --include-dev-caches   pip, npm, yarn, go module caches
  --include-docker       docker/podman system prune -f (volumes untouched)
  --include-coredumps    Age-filtered files in systemd-coredump and apport dirs
  --coredump-dir DIR     Replace the default coredump list (needs --include-coredumps)
  --help, -h             Show this help

Exit codes: 0 success, 1 one or more deletions failed, 2 not Linux, 3 usage
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

# Duplicated in each linux/ script on purpose (see CONTRIBUTING.md). OS_RELEASE
# is honoured so the unsupported-distro path can actually be tested.
detect_pkg_mgr() {
  local os_release="${OS_RELEASE:-/etc/os-release}"
  local id="" id_like=""
  if [[ -r "$os_release" ]]; then
    id="$(sed -n 's/^ID=//p' "$os_release" | tr -d '"' | head -n 1)"
    id_like="$(sed -n 's/^ID_LIKE=//p' "$os_release" | tr -d '"' | head -n 1)"
  fi
  case " $id $id_like " in
    *" debian "*|*" ubuntu "*)             printf 'apt\n' ;;
    *" fedora "*|*" rhel "*|*" centos "*)  printf 'dnf\n' ;;
    *" arch "*|*" archlinux "*)            printf 'pacman\n' ;;
    *) printf 'unsupported:%s\n' "${id:-unknown}" ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)             DRY_RUN=1 ;;
    --yes|-y)              ASSUME_YES=1 ;;
    --no-sudo)             NO_SUDO=1 ;;
    --days)                require_value "$1" "${2:-}"; DAYS="$2"; shift ;;
    --days=*)              DAYS="${1#*=}"; require_value "--days" "$DAYS" ;;
    --home)                require_value "$1" "${2:-}"; HOME_DIR="$2"; shift ;;
    --home=*)              HOME_DIR="${1#*=}"; require_value "--home" "$HOME_DIR" ;;
    --tmp)                 require_value "$1" "${2:-}"; TMP_DIR="$2"; TMP_OVERRIDE=1; shift ;;
    --tmp=*)               TMP_DIR="${1#*=}"; require_value "--tmp" "$TMP_DIR"; TMP_OVERRIDE=1 ;;
    --include-trash)       INCLUDE_TRASH=1 ;;
    --include-journal)     INCLUDE_JOURNAL=1 ;;
    --include-pkg-cache)   INCLUDE_PKG_CACHE=1 ;;
    --include-dev-caches)  INCLUDE_DEV_CACHES=1 ;;
    --include-docker)      INCLUDE_DOCKER=1 ;;
    --include-coredumps)   INCLUDE_COREDUMPS=1 ;;
    --coredump-dir)        require_value "$1" "${2:-}"; COREDUMP_DIR="$2"; COREDUMP_OVERRIDE=1; shift ;;
    --coredump-dir=*)      COREDUMP_DIR="${1#*=}"; require_value "--coredump-dir" "$COREDUMP_DIR"; COREDUMP_OVERRIDE=1 ;;
    -h|--help)             usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || (( DAYS > 3650 )); then
  err "--days must be an integer between 0 and 3650, got: $DAYS"
  exit 3
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

if (( DRY_RUN == 0 && ASSUME_YES == 0 )); then
  err "refusing to delete without --yes; preview with --dry-run"
  exit 3
fi

if [[ -z "$HOME_DIR" ]]; then
  err "\$HOME is not set; pass --home DIR"
  exit 2
fi

if (( COREDUMP_OVERRIDE == 1 )); then
  # Compare the resolved path, not the string. '//', '/.', '/../' and
  # '/var/..' all name root, and an exact match on '/' lets every one of them
  # through to clean_aged_dir — which runs `find -type f` over the directory
  # and deletes each hit, escalating to sudo. With --days 0 the age filter is
  # skipped too, so the mistake costs the whole root filesystem.
  coredump_resolved="$(realpath -m -- "$COREDUMP_DIR" 2>/dev/null || printf '%s' "$COREDUMP_DIR")"
  if [[ "$coredump_resolved" == "/" ]]; then
    err "--coredump-dir refuses / (resolved from '$COREDUMP_DIR')"
    exit 3
  fi
  COREDUMP_DIR="$coredump_resolved"
fi

have() { command -v "$1" >/dev/null 2>&1; }

human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1099511627776) printf "%.1fT", b / 1099511627776;
    else if (b >= 1073741824) printf "%.1fG", b / 1073741824;
    else if (b >= 1048576) printf "%.0fM", b / 1048576;
    else if (b >= 1024) printf "%dK", b / 1024;
    else printf "%dB", b
  }'
}

file_size() {
  stat -c '%s' "$1" 2>/dev/null || printf '0'
}

file_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || printf '0'
}

CUTOFF=$(( $(date +%s) - DAYS * 86400 ))
OWNER="$(id -un)"

step() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# Root already has everything; treating that as "sudo missing" is the mistake
# that breaks this script inside a container, which is exactly where the tests
# run it.
SUDO=""
# --no-sudo is checked before the uid, not inside the non-root branch. It used
# to sit inside it, so running the script *as* root — `sudo disk_cleanup.sh
# --no-sudo`, or from a root shell — left SUDO empty, which means "run these
# directly", and every root-owned step ran anyway. The flag asks to skip
# root-owned work; who you happen to be is not the question it answers.
if (( NO_SUDO == 1 )); then
  SUDO="skip"
elif [[ "$(id -u)" != "0" ]]; then
  if have sudo; then
    SUDO="sudo"
  else
    SUDO="skip"
    warn "sudo is not available; root-owned steps will be skipped"
  fi
fi

run_root() {
  local label="$1"; shift
  if [[ "$SUDO" == "skip" ]]; then
    warn "skipped (needs root): $label"
    return 0
  fi
  if (( DRY_RUN == 1 )); then
    if [[ -n "$SUDO" ]]; then
      printf "  %s(dry-run)%s %s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$SUDO" "$*" "$C_DIM" "$label" "$C_RESET"
    else
      printf "  %s(dry-run)%s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    fi
    return 0
  fi
  local rc
  if [[ -n "$SUDO" ]]; then
    "$SUDO" "$@"
    rc=$?
  else
    "$@"
    rc=$?
  fi
  if (( rc != 0 )); then
    err "$label failed (exit $rc)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    ok "$label"
  fi
  return 0
}

delete_file() {
  local path="$1"
  local size="$2"
  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s would remove %s (%s)\n" "$C_DIM" "$C_RESET" "$path" "$(human_bytes "$size")"
    WOULD_BYTES=$((WOULD_BYTES + size))
    return 0
  fi
  if rm -f -- "$path" 2>/dev/null; then
    FREED_BYTES=$((FREED_BYTES + size))
  else
    warn "could not remove $path (in use?)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Coredumps are usually root-owned. Retry with sudo when a plain rm cannot
# unlink them; skip the directory entirely when this run was asked not to
# become root.
delete_file_maybe_root() {
  local path="$1"
  local size="$2"
  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s would remove %s (%s)\n" "$C_DIM" "$C_RESET" "$path" "$(human_bytes "$size")"
    WOULD_BYTES=$((WOULD_BYTES + size))
    return 0
  fi
  if rm -f -- "$path" 2>/dev/null; then
    FREED_BYTES=$((FREED_BYTES + size))
    return 0
  fi
  if [[ -n "$SUDO" && "$SUDO" != "skip" ]]; then
    if "$SUDO" rm -f -- "$path" 2>/dev/null; then
      FREED_BYTES=$((FREED_BYTES + size))
      return 0
    fi
  fi
  warn "could not remove $path (in use?)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# find -print0 cannot be stored in a bash variable (NUL is the terminator).
list_aged_files() {
  local dir="$1"
  if [[ -r "$dir" ]]; then
    find "$dir" -xdev -type f -print0 2>/dev/null
  elif [[ -n "$SUDO" && "$SUDO" != "skip" ]]; then
    "$SUDO" find "$dir" -xdev -type f -print0 2>/dev/null
  else
    find "$dir" -xdev -type f -print0 2>/dev/null
  fi
}

# Age-filtered files, any owner. Used for crash dumps rather than /tmp: those
# are not "this user's leftover wget" and live in root-owned directories.
clean_aged_dir() {
  local dir="$1"
  local count=0
  local bytes=0
  [[ -d "$dir" ]] || { info "no directory: $dir"; return 0; }

  if [[ ! -r "$dir" && "$SUDO" == "skip" ]]; then
    warn "skipped (needs root): $dir"
    return 0
  fi

  while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    local mtime size
    mtime="$(stat -c '%Y' "$path" 2>/dev/null || printf '')"
    size="$(stat -c '%s' "$path" 2>/dev/null || printf '')"
    if [[ -z "$mtime" || -z "$size" ]] && [[ -n "$SUDO" && "$SUDO" != "skip" ]]; then
      mtime="$("$SUDO" stat -c '%Y' "$path" 2>/dev/null || printf '')"
      size="$("$SUDO" stat -c '%s' "$path" 2>/dev/null || printf '')"
    fi
    [[ "$mtime" =~ ^[0-9]+$ ]] || continue
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    if (( DAYS > 0 && mtime > CUTOFF )); then
      continue
    fi
    delete_file_maybe_root "$path" "$size"
    count=$((count + 1))
    bytes=$((bytes + size))
  done < <(list_aged_files "$dir")

  if (( count == 0 )); then
    info "nothing older than ${DAYS}d in $dir"
  else
    info "$count file(s) in $dir ($(human_bytes "$bytes"))"
  fi
}

# Age-filtered files owned by this user. -xdev stays on one filesystem so a
# bind-mounted /tmp/something-precious is not walked. Symlinks are not
# followed; only regular files are candidates.
clean_temp_dir() {
  local dir="$1"
  local count=0
  local bytes=0
  [[ -d "$dir" ]] || { info "no directory: $dir"; return 0; }

  while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    [[ -f "$path" ]] || continue
    local mtime size
    mtime="$(file_mtime "$path")"
    size="$(file_size "$path")"
    if (( DAYS > 0 && mtime > CUTOFF )); then
      continue
    fi
    delete_file "$path" "$size"
    count=$((count + 1))
    bytes=$((bytes + size))
  done < <(find "$dir" -xdev -type f -user "$OWNER" -print0 2>/dev/null)

  if (( count == 0 )); then
    info "nothing older than ${DAYS}d in $dir"
  else
    info "$count file(s) in $dir ($(human_bytes "$bytes"))"
  fi
}

clean_dir_contents() {
  local dir="$1"
  local label="$2"
  local count=0
  local bytes=0
  [[ -d "$dir" ]] || { info "no $label ($dir)"; return 0; }

  while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    [[ -f "$path" ]] || continue
    local size
    size="$(file_size "$path")"
    delete_file "$path" "$size"
    count=$((count + 1))
    bytes=$((bytes + size))
  done < <(find "$dir" -xdev -type f -print0 2>/dev/null)

  if (( count == 0 )); then
    info "nothing in $label"
  else
    info "$count file(s) from $label ($(human_bytes "$bytes"))"
  fi
}

info "owner: $OWNER · older than ${DAYS}d · home $HOME_DIR"

# --- temp ------------------------------------------------------------------
step "temp"
# --tmp replaces the default list so a test (or a machine whose /tmp is not
# disposable) can point at one directory and leave the rest alone. Without it,
# /tmp and $TMPDIR are both considered, once each.
temp_dirs=()
if (( TMP_OVERRIDE == 1 )); then
  temp_dirs+=("$TMP_DIR")
else
  temp_dirs+=("/tmp")
  if [[ -n "$TMP_DIR" && "$TMP_DIR" != "/tmp" ]]; then
    temp_dirs+=("$TMP_DIR")
  fi
fi
seen_tmp=""
for dir in "${temp_dirs[@]}"; do
  [[ -n "$dir" ]] || continue
  case " $seen_tmp " in *" $dir "*) continue ;; esac
  seen_tmp="$seen_tmp $dir"
  clean_temp_dir "$dir"
done

# --- thumbnails ------------------------------------------------------------
step "thumbnails"
clean_dir_contents "$HOME_DIR/.cache/thumbnails" "thumbnail cache"
if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
  clean_dir_contents "$XDG_CACHE_HOME/thumbnails" "XDG thumbnail cache"
fi

# --- trash -----------------------------------------------------------------
if (( INCLUDE_TRASH == 1 )); then
  step "trash"
  clean_dir_contents "$HOME_DIR/.local/share/Trash/files" "trash files"
  clean_dir_contents "$HOME_DIR/.local/share/Trash/info" "trash info"
else
  info "skipped: trash (pass --include-trash)"
fi

# --- journal ---------------------------------------------------------------
if (( INCLUDE_JOURNAL == 1 )); then
  step "journal"
  if have journalctl; then
    # --days 0 means "no age filter" everywhere else in this script, which for
    # the journal is the whole journal: --vacuum-time=0d removes every entry,
    # including the ones describing whatever filled the disk you are cleaning.
    # It stays possible — the combination is deliberate and already behind
    # --include-journal and --yes — but it should not be a surprise.
    if (( DAYS == 0 )); then
      warn "--days 0 with --include-journal removes the entire journal,"
      warn "  including the logs describing what filled the disk"
    fi
    run_root "vacuum journal to ${DAYS}d" journalctl --vacuum-time="${DAYS}d"
  else
    warn "journalctl not present — skipping (normal in a container)"
  fi
else
  info "skipped: journal (pass --include-journal)"
fi

# --- package caches --------------------------------------------------------
if (( INCLUDE_PKG_CACHE == 1 )); then
  step "package caches"
  PKG_MGR="$(detect_pkg_mgr)"
  case "$PKG_MGR" in
    unsupported:*)
      warn "no known package manager for '${PKG_MGR#unsupported:}' — skipping package caches"
      ;;
    apt)
      run_root "apt-get clean" apt-get clean
      ;;
    dnf)
      run_root "dnf clean packages" dnf clean packages
      ;;
    pacman)
      run_root "pacman cache clean" pacman -Sc --noconfirm
      ;;
  esac
else
  info "skipped: package caches (pass --include-pkg-cache)"
fi

# --- dev caches ------------------------------------------------------------
if (( INCLUDE_DEV_CACHES == 1 )); then
  step "dev caches"
  have pip3 && {
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s pip3 cache purge\n" "$C_DIM" "$C_RESET"
    else
      pip3 cache purge >/dev/null 2>&1 || warn "pip3 cache purge failed"
    fi
  }
  have npm && {
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s npm cache clean --force\n" "$C_DIM" "$C_RESET"
    else
      npm cache clean --force >/dev/null 2>&1 || warn "npm cache clean failed"
    fi
  }
  have yarn && {
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s yarn cache clean\n" "$C_DIM" "$C_RESET"
    else
      yarn cache clean >/dev/null 2>&1 || warn "yarn cache clean failed"
    fi
  }
  have go && {
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s go clean -cache -modcache\n" "$C_DIM" "$C_RESET"
    else
      go clean -cache -modcache >/dev/null 2>&1 || warn "go clean failed"
    fi
  }
  for dir in "$HOME_DIR/.cache/pip" "$HOME_DIR/.cache/yarn" "$HOME_DIR/.cache/go-build"; do
    [[ -d "$dir" ]] || continue
    clean_dir_contents "$dir" "$(basename "$dir") cache"
  done
else
  info "skipped: dev caches (pass --include-dev-caches)"
fi

# --- containers ------------------------------------------------------------
if (( INCLUDE_DOCKER == 1 )); then
  step "containers"
  # Volumes are never pruned: that is data, and this script must not be the
  # reason a database disappears. Same rule as stay_fresh.sh.
  if have docker && docker info >/dev/null 2>&1; then
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s docker system prune -f %s[volumes untouched]%s\n" \
        "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    else
      docker system prune -f >/dev/null 2>&1 || {
        err "docker prune failed"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      }
    fi
  else
    warn "docker not running — skipping"
  fi
  if have podman; then
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s podman system prune -f %s[volumes untouched]%s\n" \
        "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    else
      podman system prune -f >/dev/null 2>&1 || {
        err "podman prune failed"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      }
    fi
  fi
else
  info "skipped: containers (pass --include-docker)"
fi

# --- coredumps -------------------------------------------------------------
# systemd-coredump and apport leave files that are safe to delete once they
# are old enough to have been collected. The default directories are skipped
# unless asked, the same gate as trash and docker: a fresh crash dump is
# evidence, not clutter, until you say otherwise.
if (( INCLUDE_COREDUMPS == 1 )); then
  step "coredumps"
  coredump_dirs=()
  if (( COREDUMP_OVERRIDE == 1 )); then
    coredump_dirs+=("$COREDUMP_DIR")
  else
    coredump_dirs+=("/var/lib/systemd/coredump" "/var/crash")
  fi
  seen_core=""
  for dir in "${coredump_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    case " $seen_core " in *" $dir "*) continue ;; esac
    seen_core="$seen_core $dir"
    clean_aged_dir "$dir"
  done
else
  info "skipped: coredumps (pass --include-coredumps)"
fi

# --- report ----------------------------------------------------------------
step "report"
if have df; then
  df -h / 2>/dev/null | sed 's/^/  /'
fi

printf "\n"
if (( DRY_RUN == 1 )); then
  info "would free at least $(human_bytes "$WOULD_BYTES") from age-filtered files"
  printf "dry-run complete; no changes written\n"
  exit 0
fi
info "freed at least $(human_bytes "$FREED_BYTES") from age-filtered files"
if (( FAIL_COUNT > 0 )); then
  err "$FAIL_COUNT deletion(s) failed"
  exit 1
fi
ok "done"
exit 0

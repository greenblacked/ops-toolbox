#!/usr/bin/env bash
# stay_fresh.sh
# Recurring maintenance for a Linux machine: package upgrades, cache and log
# pruning, container cleanup, and a report of what still needs a reboot.
#
# The counterpart of macos-initial-setup/stay_fresh.sh. Same shape: every step
# is skippable, a missing tool is a note rather than a failure, and --dry-run
# shows the whole run without touching anything.
#
# Exit codes:
#   0   success
#   1   one or more steps failed
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
NO_SUDO=0

SKIP_PACKAGES=0
SKIP_JOURNAL=0
SKIP_CACHES=0
SKIP_CONTAINERS=0
SKIP_FLATPAK=0
SKIP_SNAP=0

LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/linux_stay_fresh-$(date +%Y%m%d-%H%M%S).log"

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

STEP_FAIL_COUNT=0

usage() {
  cat <<EOF
stay_fresh.sh - recurring maintenance for a Linux machine

Usage:
  $(basename "$0") [--dry-run] [--yes] [--verbose] [--no-sudo] [--skip-* ...]

Options:
  --dry-run          Print every command without running it
  --yes, -y          Do not prompt; required for a non-interactive upgrade
  --verbose, -v      Stream command output instead of only logging it
  --no-sudo          Skip every step that needs root
  --skip-packages    Skip the package upgrade and autoremove
  --skip-journal     Skip journald vacuum
  --skip-caches      Skip user caches (pip, npm, yarn, go, ~/.cache)
  --skip-containers  Skip docker/podman prune
  --skip-flatpak     Skip flatpak
  --skip-snap        Skip snap
  --help, -h         Show this help

Log file: ${LOG_DIR}/linux_stay_fresh-<timestamp>.log

Exit codes: 0 success, 1 one or more steps failed, 2 preflight failed, 3 usage
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
    --dry-run)         DRY_RUN=1 ;;
    --yes|-y)          ASSUME_YES=1 ;;
    --verbose|-v)      VERBOSE=1 ;;
    --no-sudo)         NO_SUDO=1 ;;
    --skip-packages)   SKIP_PACKAGES=1 ;;
    --skip-journal)    SKIP_JOURNAL=1 ;;
    --skip-caches)     SKIP_CACHES=1 ;;
    --skip-containers) SKIP_CONTAINERS=1 ;;
    --skip-flatpak)    SKIP_FLATPAK=1 ;;
    --skip-snap)       SKIP_SNAP=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

PKG_MGR="$(detect_pkg_mgr)"
case "$PKG_MGR" in
  unsupported:*)
    err "unsupported distribution: ${PKG_MGR#unsupported:} (need apt, dnf or pacman)"
    exit 2
    ;;
esac

# A dry run writes nothing — including this script's own log. See the same
# guard in install_devtools.sh; run_cmd() already skips the appends.
if (( DRY_RUN == 1 )); then
  info "package manager: $PKG_MGR"
  info "dry-run: would write log: $C_DIM$LOG_FILE$C_RESET"
else
  : > "$LOG_FILE"
  printf 'linux stay_fresh.sh log - %s\n' "$(date)" >> "$LOG_FILE"
  info "package manager: $PKG_MGR"
  info "log file: $C_DIM$LOG_FILE$C_RESET"
fi

# Root already has everything; treating that as "sudo missing" is the mistake
# that breaks this script inside a container, which is exactly where the tests
# run it.
SUDO=""
if [[ "$(id -u)" != "0" ]]; then
  if (( NO_SUDO == 1 )); then
    SUDO="skip"
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    SUDO="skip"
    warn "sudo is not available; root-owned steps will be skipped"
  fi
fi

step() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# A step that fails counts against the exit status. A step whose tool is simply
# absent does not — that is the documented split, and it is why journald being
# missing in a container must not turn the run red.
run_cmd() {
  local label="$1"; shift
  if (( DRY_RUN == 1 )); then
    printf "  %s(dry-run)%s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    return 0
  fi
  printf "  %s->%s %s\n" "$C_CYAN" "$C_RESET" "$label"
  echo "# $(date '+%H:%M:%S') [$label] >> $*" >> "$LOG_FILE"
  local rc
  if (( VERBOSE == 1 )); then
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  else
    "$@" >>"$LOG_FILE" 2>&1
    rc=$?
  fi
  if (( rc != 0 )); then
    err "$label failed (exit $rc; see $LOG_FILE)"
    STEP_FAIL_COUNT=$((STEP_FAIL_COUNT + 1))
  fi
  return 0
}

run_root() {
  local label="$1"; shift
  if [[ "$SUDO" == "skip" ]]; then
    warn "skipped (needs root): $label"
    return 0
  fi
  if [[ -n "$SUDO" ]]; then
    run_cmd "$label" "$SUDO" "$@"
  else
    run_cmd "$label" "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- packages --------------------------------------------------------------
if (( SKIP_PACKAGES == 0 )); then
  step "packages ($PKG_MGR)"
  if (( ASSUME_YES == 0 )) && (( DRY_RUN == 0 )); then
    warn "skipping upgrades: pass --yes to run them unattended"
  else
    case "$PKG_MGR" in
      apt)
        run_root "apt update" apt-get update
        # Packages held with apt-mark hold are left alone by design; upgrade
        # respects holds where dist-upgrade would fight them.
        run_root "apt upgrade" apt-get upgrade --yes
        run_root "apt autoremove" apt-get autoremove --yes
        run_root "apt autoclean" apt-get autoclean --yes
        ;;
      dnf)
        run_root "dnf upgrade" dnf upgrade -y
        run_root "dnf autoremove" dnf autoremove -y
        run_root "dnf clean" dnf clean packages
        ;;
      pacman)
        run_root "pacman sync" pacman -Syu --noconfirm
        ;;
    esac
  fi
else
  info "skipped: packages"
fi

# --- journal ---------------------------------------------------------------
if (( SKIP_JOURNAL == 0 )); then
  step "journal"
  if have journalctl; then
    run_root "vacuum journal to 14 days" journalctl --vacuum-time=14d
  else
    warn "journalctl not present — skipping (normal in a container)"
  fi
else
  info "skipped: journal"
fi

# --- user caches -----------------------------------------------------------
if (( SKIP_CACHES == 0 )); then
  step "user caches"
  have pip3 && run_cmd "pip cache purge" pip3 cache purge
  have npm  && run_cmd "npm cache clean" npm cache clean --force
  have yarn && run_cmd "yarn cache clean" yarn cache clean
  have go   && run_cmd "go clean cache" go clean -cache -modcache
  for dir in "$HOME/.cache/pip" "$HOME/.cache/yarn" "$HOME/.cache/go-build"; do
    [[ -d "$dir" ]] || continue
    run_cmd "remove $dir" rm -rf "$dir"
  done
  trash="$HOME/.local/share/Trash/files"
  if [[ -d "$trash" ]]; then
    run_cmd "empty trash" rm -rf "$trash"
  fi
else
  info "skipped: caches"
fi

# --- containers ------------------------------------------------------------
if (( SKIP_CONTAINERS == 0 )); then
  step "containers"
  # Volumes are never pruned: that is data, and this script must not be the
  # reason a database disappears.
  if have docker && docker info >/dev/null 2>&1; then
    run_cmd "docker prune (volumes untouched)" docker system prune -f
  else
    warn "docker not running — skipping"
  fi
  if have podman; then
    run_cmd "podman prune (volumes untouched)" podman system prune -f
  fi
else
  info "skipped: containers"
fi

# --- flatpak / snap --------------------------------------------------------
if (( SKIP_FLATPAK == 0 )); then
  step "flatpak"
  if have flatpak; then
    run_cmd "flatpak update" flatpak update -y
    run_cmd "flatpak remove unused" flatpak uninstall --unused -y
  else
    warn "flatpak not installed — skipping"
  fi
fi

if (( SKIP_SNAP == 0 )); then
  step "snap"
  if have snap; then
    run_cmd "snap refresh" snap refresh
  else
    warn "snap not installed — skipping"
  fi
fi

# --- report ----------------------------------------------------------------
step "report"
if [[ -f /var/run/reboot-required ]]; then
  warn "a reboot is required"
  [[ -f /var/run/reboot-required.pkgs ]] && sed 's/^/        /' /var/run/reboot-required.pkgs
elif have needs-restarting; then
  if ! needs-restarting -r >/dev/null 2>&1; then
    warn "a reboot is required"
  else
    ok "no reboot required"
  fi
else
  info "no reboot marker found"
fi

if have df; then
  printf "\n%sdisk%s\n" "$C_BOLD" "$C_RESET"
  df -h / 2>/dev/null | sed 's/^/  /'
fi

printf "\n"
if (( DRY_RUN == 1 )); then
  printf "dry-run complete; no changes written\n"
  exit 0
fi
info "full log: $LOG_FILE"
if (( STEP_FAIL_COUNT > 0 )); then
  err "$STEP_FAIL_COUNT step(s) failed"
  exit 1
fi
ok "done"

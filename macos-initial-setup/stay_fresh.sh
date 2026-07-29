#!/usr/bin/env bash
# stay_fresh.sh
# Keep your macOS clean and up-to-date:
#   - purge inactive memory
#   - flush DNS caches
#   - clear /Library/Caches and writable /System/Library/Caches
#   - clear ~/Library caches (Caches, Logs, Saved State, Xcode DerivedData, ...)
#   - clear per-app caches missed by the above: Chromium/Electron dirs under
#     Application Support, sandboxed app caches in ~/Library/Containers,
#     cached extension .vsix archives, aerial wallpaper videos
#   - prune VS Code / Cursor workspaceStorage for projects that no longer exist
#   - empty ~/.Trash
#   - clean developer tool caches (npm, yarn, pnpm, pip, gem, go)
#   - prune Docker / OrbStack (images, containers, volumes, builder cache)
#   - clean Xcode extras (Archives, DeviceSupport, stale simulators)
#   - clean diagnostic / crash reports (as user; system dirs if sudo)
#   - Homebrew: update, upgrade (formulae + casks), cleanup -s, autoremove
#   - refresh dev toolchains (helm plugins, gcloud components) installed by
#     install_apps.sh / install_devtools.sh
#
# Usage:
#   ./stay_fresh.sh [--dry-run] [--yes] [--verbose]
#                   [--skip-memory] [--skip-dns] [--skip-syscaches]
#                   [--skip-usercaches] [--skip-appcaches] [--skip-trash]
#                   [--skip-brew] [--skip-devcaches] [--skip-docker]
#                   [--skip-xcode] [--skip-diagnostics]
#                   [--no-sudo] [--help]
#
# Exit codes:
#   0   housekeeping finished (possibly with non-fatal warnings)
#   1   one or more steps hard-failed
#   2   preflight checks failed
#   3   bad CLI arguments

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# output helpers (TTY-aware colors)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_MAGENTA=$'\033[1;35m'
  C_CYAN=$'\033[1;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

bold()  { printf "%s%s%s\n" "$C_BOLD"    "$*" "$C_RESET"; }
info()  { printf "%s[info]%s %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf "%s[ ok ]%s %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf "%s[warn]%s %s\n"  "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf "%s[err ]%s %s\n"  "$C_RED"    "$C_RESET" "$*" 1>&2; }
step()  { printf "\n%s==>%s %s%s%s\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
hr()    { printf "%s%s%s\n" "$C_DIM" "--------------------------------------------------------------" "$C_RESET"; }

# ---------------------------------------------------------------------------
# defaults / CLI parsing
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
USE_SUDO=1

SKIP_MEMORY=0
SKIP_DNS=0
SKIP_SYSCACHES=0
SKIP_USERCACHES=0
SKIP_APPCACHES=0
SKIP_WORKSPACESTORAGE=0
SKIP_TRASH=0
SKIP_BREW=0
SKIP_DEVCACHES=0
SKIP_DEVTOOLS=0
SKIP_HELM_PLUGINS=0
SKIP_GCLOUD=0
SKIP_VERSIONS=0
SKIP_DOCKER=0
SKIP_XCODE=0
SKIP_DIAGNOSTICS=0
BREW_GREEDY=0

LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/stay_fresh-$(date +%Y%m%d-%H%M%S).log"

# step accounting
STEPS_OK=()
STEPS_WARN=()
STEPS_FAIL=()
STEPS_SKIP=()

# accumulated bytes freed (best-effort, measured by clear_dir / step helpers).
# STEP_FREED_B is reset per step by do_step; TOTAL_FREED_B is the sum across steps.
STEP_FREED_B=0
TOTAL_FREED_B=0
# Count of non-zero run_cmd invocations in the current step. Reset by do_step.
STEP_WARN_COUNT=0

usage() {
  cat <<EOF
${C_BOLD}stay_fresh.sh${C_RESET} — macOS housekeeping in one script.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [options]

${C_BOLD}General options:${C_RESET}
  --dry-run              Preview actions, change nothing
  --yes, -y              Don't prompt for confirmation
  --verbose, -v          Stream command output (default: captured to log)
  --no-sudo              Skip steps that require sudo
  --help, -h             Show this help

${C_BOLD}Step toggles (skip individual steps):${C_RESET}
  --skip-memory          Don't run 'sudo purge'
  --skip-dns             Don't flush DNS caches
  --skip-syscaches       Don't touch /Library/Caches or /System/Library/Caches
  --skip-usercaches      Don't clear ~/Library/Caches et al.
  --skip-appcaches       Don't clear per-app caches (see Notes)
  --skip-workspacestorage
                         Don't prune stale VS Code / Cursor workspace storage
  --skip-trash           Don't empty ~/.Trash
  --skip-brew            Don't run Homebrew maintenance (see Notes)
  --brew-greedy          Also upgrade casks with 'auto_updates true' / 'version :latest'
                         (may prompt for sudo during cask postinstalls)
  --skip-devcaches       Don't clean npm/yarn/pnpm/pip/gem/go caches
  --skip-devtools        Shorthand: skip all dev-tool refresh steps below
                         (--skip-helm-plugins --skip-gcloud --skip-versions)
  --skip-helm-plugins    Don't run 'helm plugin update' for installed plugins
  --skip-gcloud          Don't run 'gcloud components update'
  --skip-versions        Don't print active pyenv/goenv/tfenv/tenv/helm/gcloud
                         versions
  --skip-docker          Don't prune Docker / OrbStack
  --skip-xcode           Don't clean Xcode Archives/DeviceSupport/simulators
  --skip-diagnostics     Don't remove crash / diagnostic reports (see Notes)

${C_BOLD}Notes:${C_RESET}
  Per-app caches: covers the disposable data that lives outside ~/Library/Caches
  and so is missed by --skip-usercaches' step — Chromium-internal dirs (Cache,
  Code Cache, GPUCache, Service Worker, blob_storage) under Application Support,
  the private Caches dir inside each sandboxed app's container, cached extension
  .vsix archives, and the aerial-wallpaper videos. All of it regenerates, but
  quit the apps first — a running app rewrites its caches mid-sweep.

  Workspace storage: VS Code and its forks keep a workspaceStorage entry per
  folder ever opened and never garbage-collect them. Only entries whose recorded
  path no longer exists are removed; remote workspaces and anything unparsable
  are kept.

  Diagnostic / crash reports: always runs as your user (clears
  ~/Library/Logs/DiagnosticReports and ~/Library/DiagnosticReports). With sudo
  (default), also clears /Library/Logs/DiagnosticReports and
  /Library/Logs/CrashReporter. --no-sudo skips only those system paths.

  Homebrew: runs brew update; brew upgrade (formulae, then casks); brew cleanup -s;
  brew autoremove; brew doctor only when --verbose. Casks may prompt for sudo during
  postinstall (--brew-greedy changes which casks upgrade).

Log file: $LOG_FILE
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    -y|--yes)          ASSUME_YES=1 ;;
    -v|--verbose)      VERBOSE=1 ;;
    --no-sudo)         USE_SUDO=0 ;;
    --skip-memory)     SKIP_MEMORY=1 ;;
    --skip-dns)        SKIP_DNS=1 ;;
    --skip-syscaches)  SKIP_SYSCACHES=1 ;;
    --skip-usercaches) SKIP_USERCACHES=1 ;;
    --skip-appcaches)  SKIP_APPCACHES=1 ;;
    --skip-workspacestorage) SKIP_WORKSPACESTORAGE=1 ;;`
    --skip-trash)      SKIP_TRASH=1 ;;
    --skip-brew)       SKIP_BREW=1 ;;
    --brew-greedy)     BREW_GREEDY=1 ;;
    --skip-devcaches)  SKIP_DEVCACHES=1 ;;
    --skip-devtools)   SKIP_DEVTOOLS=1 ;;
    --skip-helm-plugins) SKIP_HELM_PLUGINS=1 ;;
    --skip-gcloud)     SKIP_GCLOUD=1 ;;
    --skip-versions)   SKIP_VERSIONS=1 ;;
    --skip-docker)     SKIP_DOCKER=1 ;;
    --skip-xcode)      SKIP_XCODE=1 ;;
    --skip-diagnostics)SKIP_DIAGNOSTICS=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 err "unknown option: $1"; echo; usage; exit 3 ;;
  esac
  shift
done

# --skip-devtools is a convenience; fan it out across the individual
# dev-tool refresh steps so the plan/summary accurately reflects what runs.
if (( SKIP_DEVTOOLS )); then
  SKIP_HELM_PLUGINS=1
  SKIP_GCLOUD=1
  SKIP_VERSIONS=1
fi

# VS Code forks all inherit the same Application Support layout
# (CachedExtensionVSIXs, User/workspaceStorage, ...), so the cache steps below
# iterate this list rather than special-casing each editor.
VSCODE_FAMILY=(
  "Code"
  "Code - Insiders"
  "VSCodium"
  "Cursor"
  "Windsurf"
  "Void"
  "Trae"
  "Positron"
)

# ---------------------------------------------------------------------------
# utility helpers
# ---------------------------------------------------------------------------
human_duration() {
  local s="$1"
  if (( s < 60 )); then printf "%ds" "$s"
  else printf "%dm%02ds" $((s/60)) $((s%60))
  fi
}

# Convert a byte delta to a signed human-readable size (KB/MB/GB).
human_bytes() {
  local b="$1" sign=""
  if (( b < 0 )); then sign="-"; b=$(( -b )); fi
  if   (( b >= 1073741824 )); then printf "%s%.2fG" "$sign" "$(awk -v b="$b" 'BEGIN{printf "%.2f", b/1073741824}')"
  elif (( b >= 1048576    )); then printf "%s%.2fM" "$sign" "$(awk -v b="$b" 'BEGIN{printf "%.2f", b/1048576}')"
  elif (( b >= 1024       )); then printf "%s%.2fK" "$sign" "$(awk -v b="$b" 'BEGIN{printf "%.2f", b/1024}')"
  else                            printf "%s%dB"    "$sign" "$b"
  fi
}

# Disk free in bytes on /.
disk_free_bytes() {
  # df -k prints 1024-byte blocks
  df -k / | awk 'NR==2 {printf "%.0f", $4 * 1024}'
}

# Size of a path in bytes (0 if missing). Best-effort (ignores permission errors).
path_bytes() {
  local p="$1"
  [[ -e "$p" ]] || { echo 0; return; }
  du -sk "$p" 2>/dev/null | awk '{printf "%.0f", $1 * 1024}'
}

# Run a command; honor --dry-run and --verbose; log output to $LOG_FILE.
# Prints the human label so the console matches the log. Bumps STEP_WARN_COUNT
# on a non-zero exit so do_step can route to OK/WARN/FAIL accurately.
# Usage: run_cmd "human label" cmd args...
run_cmd() {
  local label="$1"; shift
  if (( DRY_RUN )); then
    printf "  %s(dry-run)%s %s %s[%s]%s\n" \
      "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    return 0
  fi
  printf "  %s->%s %s\n" "$C_CYAN" "$C_RESET" "$label"
  echo "# $(date '+%H:%M:%S') [$label] >> $*" >>"$LOG_FILE"
  local rc=0
  if (( VERBOSE )); then
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  else
    "$@" >>"$LOG_FILE" 2>&1
    rc=$?
  fi
  if (( rc != 0 )); then
    STEP_WARN_COUNT=$(( STEP_WARN_COUNT + 1 ))
  fi
  return "$rc"
}

# Like run_cmd, but keeps the command attached to the controlling TTY so
# interactive prompts (e.g. sudo password, cask installer UI) are visible and
# answerable. Output is still teed to the log file.
# Usage: run_cmd_tty "human label" cmd args...
run_cmd_tty() {
  local label="$1"; shift
  if (( DRY_RUN )); then
    printf "  %s(dry-run)%s %s %s[%s]%s\n" \
      "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    return 0
  fi
  printf "  %s->%s %s\n" "$C_CYAN" "$C_RESET" "$label"
  echo "# $(date '+%H:%M:%S') [$label] >> $*" >>"$LOG_FILE"
  local rc=0
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    "$@" </dev/tty 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  else
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  fi
  if (( rc != 0 )); then
    STEP_WARN_COUNT=$(( STEP_WARN_COUNT + 1 ))
  fi
  return "$rc"
}

# Clear contents of a directory (not the dir itself), with before/after size.
# Uses sudo if $2 == "sudo".
# Usage: clear_dir <path> [sudo]
clear_dir() {
  local dir="$1" use_sudo="${2:-}" before_b after_b delta
  if [[ ! -d "$dir" ]]; then
    printf "  %s- %s (missing, skipped)%s\n" "$C_DIM" "$dir" "$C_RESET"
    return 0
  fi
  before_b="$(path_bytes "$dir")"
  printf "  clearing %s %s(%s)%s\n" "$dir" "$C_DIM" "$(human_bytes "$before_b")" "$C_RESET"
  if (( DRY_RUN )); then
    printf "  %s(dry-run) would remove contents of %s%s\n" "$C_DIM" "$dir" "$C_RESET"
    return 0
  fi
  if [[ "$use_sudo" == "sudo" ]]; then
    sudo find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$LOG_FILE" || true
  else
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$LOG_FILE" || true
  fi
  after_b="$(path_bytes "$dir")"
  delta=$(( before_b - after_b ))
  (( delta > 0 )) && STEP_FREED_B=$(( STEP_FREED_B + delta ))
  printf "  %s->%s freed %s from %s\n" "$C_GREEN" "$C_RESET" "$(human_bytes "$delta")" "$dir"
}

# Bulk-remove many paths with a single aggregate size report, honoring
# --dry-run. Per-path sizes are only printed under --verbose; a sweep can match
# a few hundred directories and one line each drowns the summary.
#   mode "dir"      -> remove the directories themselves
#   mode "contents" -> keep each directory, remove what is inside it
# Usage: clear_paths <label> <dir|contents> <path>...
clear_paths() {
  local label="$1" mode="$2"; shift 2
  if (( $# == 0 )); then
    printf "  %s- no %s found%s\n" "$C_DIM" "$label" "$C_RESET"
    return 0
  fi

  local p before_b after_b delta total_b=0 count=$#
  for p in "$@"; do
    before_b="$(path_bytes "$p")"
    total_b=$(( total_b + before_b ))
    if (( VERBOSE )); then
      printf "      %s %s(%s)%s\n" \
        "${p#"$HOME"/}" "$C_DIM" "$(human_bytes "$before_b")" "$C_RESET"
    fi
  done
  printf "  %s: %d path(s), %s%s%s\n" \
    "$label" "$count" "$C_DIM" "$(human_bytes "$total_b")" "$C_RESET"

  if (( DRY_RUN )); then
    printf "  %s(dry-run) would clear %d path(s)%s\n" "$C_DIM" "$count" "$C_RESET"
    return 0
  fi

  if [[ "$mode" == "contents" ]]; then
    for p in "$@"; do
      find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$LOG_FILE" || true
    done
  else
    rm -rf "$@" 2>>"$LOG_FILE" || true
  fi

  after_b=0
  for p in "$@"; do
    after_b=$(( after_b + $(path_bytes "$p") ))
  done
  delta=$(( total_b - after_b ))
  (( delta > 0 )) && STEP_FREED_B=$(( STEP_FREED_B + delta ))
  printf "  %s->%s freed %s %s(%s)%s\n" \
    "$C_GREEN" "$C_RESET" "$(human_bytes "$delta")" "$C_DIM" "$label" "$C_RESET"
}

# ---------------------------------------------------------------------------
# preflight checks
# ---------------------------------------------------------------------------
bold "=== stay_fresh: preflight checks ==="

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
echo "stay_fresh.sh log - $(date)" >> "$LOG_FILE"
info "log file: $C_DIM$LOG_FILE$C_RESET"

# 1. macOS only
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only (detected: $(uname -s))."
  exit 2
fi
OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo '?')"
OS_BUILD="$(sw_vers -buildVersion   2>/dev/null || echo '?')"
ARCH="$(uname -m)"
ok "macOS $OS_VERSION ($OS_BUILD) on $ARCH"

# 2. Not root
if [[ "$(id -u)" == "0" ]]; then
  err "Do NOT run stay_fresh.sh as root. Run as a normal user; it will ask for sudo."
  exit 2
fi
ok "running as user: $(id -un)"

# 3. Disk free before
FREE_BEFORE_B="$(disk_free_bytes)"
ok "disk free on /: $(human_bytes "$FREE_BEFORE_B")"

# 4. Homebrew check (only relevant if we aren't skipping it)
if (( SKIP_BREW == 0 )); then
  if command -v brew >/dev/null 2>&1; then
    ok "$(brew --version | head -n1) (prefix: $(brew --prefix))"
  else
    warn "Homebrew not installed — brew step will be skipped"
    SKIP_BREW=1
    STEPS_SKIP+=("brew (not installed)")
  fi
fi

# 4a. Xcode Command Line Tools check (Homebrew frequently depends on them).
# We can't perfectly predict "too outdated", but we can catch missing CLT and
# flag obvious mismatches (e.g. macOS major != CLT major).
if (( SKIP_BREW == 0 )); then
  if xcode-select -p >/dev/null 2>&1; then
    clt_ver="$(pkgutil --pkg-info com.apple.pkg.CLTools_Executables 2>/dev/null | awk -F': ' '/^version:/ {print $2}' | head -n1)"
    if [[ -n "$clt_ver" ]]; then
      os_major="${OS_VERSION%%.*}"
      clt_major="${clt_ver%%.*}"
      if [[ "$os_major" != "?" ]] && [[ "$clt_major" != "?" ]] && [[ "$os_major" != "$clt_major" ]]; then
        warn "Xcode Command Line Tools version ($clt_ver) does not match macOS major ($OS_VERSION) — brew upgrades may fail; update CLT via Software Update or 'xcode-select --install'"
      else
        ok "Xcode Command Line Tools: $clt_ver"
      fi
    else
      ok "Xcode Command Line Tools: present"
    fi
  else
    warn "Xcode Command Line Tools not detected — Homebrew upgrades may fail (install via 'xcode-select --install')"
  fi
fi

# 4b. Docker check — auto-skip if no docker CLI
if (( SKIP_DOCKER == 0 )); then
  if ! command -v docker >/dev/null 2>&1; then
    info "Docker CLI not found — docker-prune step will be skipped"
    SKIP_DOCKER=1
  elif ! docker info >/dev/null 2>&1; then
    warn "Docker CLI present but daemon unreachable — docker-prune step will be skipped"
    SKIP_DOCKER=1
  else
    ok "Docker daemon reachable"
  fi
fi

# 4c. Xcode check — auto-skip if no ~/Library/Developer/Xcode and no xcrun simctl
if (( SKIP_XCODE == 0 )); then
  if [[ ! -d "$HOME/Library/Developer/Xcode" ]] && ! command -v xcrun >/dev/null 2>&1; then
    info "No Xcode data found — xcode-extras step will be skipped"
    SKIP_XCODE=1
  fi
fi

# 5. sudo availability
SUDO_AVAILABLE=0
NEEDS_SUDO=0
(( SKIP_MEMORY      == 0 )) && NEEDS_SUDO=1
(( SKIP_DNS         == 0 )) && NEEDS_SUDO=1
(( SKIP_SYSCACHES   == 0 )) && NEEDS_SUDO=1
(( SKIP_DIAGNOSTICS == 0 )) && NEEDS_SUDO=1

if (( USE_SUDO == 0 )); then
  warn "--no-sudo set: memory purge, DNS flush, system caches, and system diagnostics will be skipped"
  SKIP_MEMORY=1
  SKIP_DNS=1
  SKIP_SYSCACHES=1
  SKIP_DIAGNOSTICS_SYS=1
  NEEDS_SUDO=0
fi

if (( NEEDS_SUDO == 1 )) && (( DRY_RUN == 0 )); then
  info "some steps need sudo — you may be prompted once"
  if sudo -v; then
    SUDO_AVAILABLE=1
    ok "sudo authenticated"
    # keep-alive (disown so EXIT kill does not print bash job "Terminated: 15" noise)
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
    disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || disown || true
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
          wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
  else
    err "sudo authentication failed — disabling sudo-requiring steps"
    SKIP_MEMORY=1
    SKIP_DNS=1
    SKIP_SYSCACHES=1
    SKIP_DIAGNOSTICS_SYS=1
  fi
elif (( DRY_RUN )); then
  info "(dry-run) would request sudo for memory/DNS/system-caches/diagnostics steps"
fi

SKIP_DIAGNOSTICS_SYS="${SKIP_DIAGNOSTICS_SYS:-0}"

# ---------------------------------------------------------------------------
# plan + confirmation
# ---------------------------------------------------------------------------
hr
bold "Plan:"
printf "  %-34s %s\n" "STEP" "STATUS"
printf "  %-34s %s\n" "----" "------"
plan_line() {
  local name="$1" active="$2" extra="${3:-}"
  if (( active )); then
    printf "  %-34s %brun%b %s\n" "$name" "$C_GREEN" "$C_RESET" "$extra"
  else
    printf "  %-34s %bskip%b %s\n" "$name" "$C_DIM" "$C_RESET" "$extra"
  fi
}
plan_line "purge inactive memory"             "$(( 1 - SKIP_MEMORY      ))" "sudo purge"
plan_line "flush DNS cache"                   "$(( 1 - SKIP_DNS         ))" "dscacheutil + mDNSResponder"
plan_line "clear system caches"               "$(( 1 - SKIP_SYSCACHES   ))" "/Library/Caches, /System/Library/Caches"
plan_line "clear user caches"                 "$(( 1 - SKIP_USERCACHES  ))" "~/Library/Caches, Logs, DerivedData, ..."
plan_line "clear per-app caches"              "$(( 1 - SKIP_APPCACHES   ))" "Chromium, sandboxed, VSIX, wallpapers"
plan_line "prune workspace storage"           "$(( 1 - SKIP_WORKSPACESTORAGE ))" "VS Code / Cursor, deleted projects only"
plan_line "empty trash"                       "$(( 1 - SKIP_TRASH       ))" "~/.Trash"
plan_line "docker / orbstack prune"           "$(( 1 - SKIP_DOCKER      ))" "images, containers, volumes, builder"
plan_line "xcode extras"                      "$(( 1 - SKIP_XCODE       ))" "Archives, DeviceSupport, simulators"
plan_line "diagnostic / crash reports"        "$(( 1 - SKIP_DIAGNOSTICS ))" "user (+ system if sudo)"
plan_line "homebrew update/upgrade/cleanup"   "$(( 1 - SKIP_BREW        ))" "brew update · upgrade · cleanup -s · autoremove"
plan_line "dev-tool caches"                   "$(( 1 - SKIP_DEVCACHES   ))" "npm/yarn/pnpm/pip/gem/go"
plan_line "helm plugin refresh"               "$(( 1 - SKIP_HELM_PLUGINS))" "helm plugin update <name>"
plan_line "gcloud components update"          "$(( 1 - SKIP_GCLOUD      ))" "non-brew gcloud components"
plan_line "report active versions"            "$(( 1 - SKIP_VERSIONS    ))" "pyenv/goenv/tfenv/tenv/helm/gcloud"
hr

if (( DRY_RUN )); then
  bold "Dry run — no changes will be made."
fi

if (( ASSUME_YES == 0 )) && (( DRY_RUN == 0 )); then
  if [[ ! -t 0 ]]; then
    info "non-interactive stdin — auto-proceeding (use --yes to silence)"
  else
    printf "%sProceed? [y/N]%s " "$C_BOLD" "$C_RESET"
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) warn "aborted by user"; exit 0 ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# step wrapper
# ---------------------------------------------------------------------------
# Usage: do_step "Label" step_function
#   rc != 0                      -> STEPS_FAIL
#   rc == 0 && STEP_WARN_COUNT>0 -> STEPS_WARN
#   otherwise                    -> STEPS_OK
# Appends per-step bytes freed to the bookkeeping entry when > 0.
do_step() {
  local label="$1" fn="$2" t_start t_end rc=0 dur freed_str="" entry
  step "$label"
  STEP_WARN_COUNT=0
  STEP_FREED_B=0
  t_start=$(date +%s)
  if "$fn"; then rc=0; else rc=$?; fi
  t_end=$(date +%s)
  dur="$(human_duration $(( t_end - t_start )))"
  if (( STEP_FREED_B > 0 )); then
    freed_str=" · freed $(human_bytes "$STEP_FREED_B")"
    TOTAL_FREED_B=$(( TOTAL_FREED_B + STEP_FREED_B ))
  fi
  entry="$label  (${dur}${freed_str})"
  if (( rc != 0 )); then
    err "$label failed in $dur$freed_str — see log"
    STEPS_FAIL+=("$entry")
  elif (( STEP_WARN_COUNT > 0 )); then
    warn "$label finished with $STEP_WARN_COUNT warning(s) in $dur$freed_str — see log"
    STEPS_WARN+=("$entry")
  else
    ok "$label done in $dur$freed_str"
    STEPS_OK+=("$entry")
  fi
}

# ---------------------------------------------------------------------------
# steps
# ---------------------------------------------------------------------------
step_memory() {
  run_cmd "purge memory" sudo purge
}

step_dns() {
  run_cmd "flush DNS"            sudo dscacheutil -flushcache
  run_cmd "reload mDNSResponder" sudo killall -HUP mDNSResponder
}

step_syscaches() {
  clear_dir "/Library/Caches"        sudo
  if [[ -d /System/Library/Caches ]]; then
    printf "  /System/Library/Caches: removing writable entries only\n"
    if (( DRY_RUN == 0 )); then
      # BSD find on macOS does not consistently support -writable; use -perm instead.
      sudo find /System/Library/Caches -mindepth 1 -maxdepth 2 \
        \( -perm -u+w -o -perm -g+w -o -perm -o+w \) \
        -exec rm -rf {} + 2>>"$LOG_FILE" || true
    else
      printf "  %s(dry-run) would remove writable entries in /System/Library/Caches%s\n" "$C_DIM" "$C_RESET"
    fi
  fi
}

step_usercaches() {
  local targets=(
    "$HOME/Library/Caches"
    "$HOME/Library/Logs"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$HOME/Library/Application Support/Caches"
  )
  for d in "${targets[@]}"; do
    clear_dir "$d"
  done
}

# Electron / Chromium apps (Claude, Slack, VS Code, Cursor, Chrome, Brave, ...)
# keep their disposable caches inside their own Application Support directory,
# not in ~/Library/Caches — so step_usercaches above never touches them. On a
# developer machine this is routinely several GB.
#
# The matched names are Chromium-internal and are recreated on next launch.
# We match by directory name rather than by an app allow-list so that apps not
# yet on anyone's list are covered too; "Cache"/"GPUCache"/"blob_storage" are
# unambiguous enough that a generic sweep is safe.
step_appcaches() {
  local root="$HOME/Library/Application Support"
  if [[ ! -d "$root" ]]; then
    warn "$root not found"
    return 0
  fi

  # A live Chromium process rewrites these dirs while we delete them, which can
  # leave its profile inconsistent. Warn, but don't refuse — the caches rebuild.
  local -a running=()
  local proc
  for proc in "Claude" "Slack" "Code" "Cursor" "Notion" "Obsidian" "Signal" \
              "Discord" "Google Chrome" "Brave Browser" "Vivaldi" "Zed" "Void"; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
      running+=("$proc")
    fi
  done
  if (( ${#running[@]} > 0 )); then
    warn "running now: ${running[*]} — quit them first for a clean sweep"
  fi

  # -prune keeps find from descending into a directory it already matched, so
  # nested hits aren't reported (and re-deleted) twice.
  local -a hits=()
  while IFS= read -r -d '' d; do
    hits+=("$d")
  done < <(find "$root" -maxdepth 5 -type d \( \
             -iname "Cache"              -o \
             -iname "CachedData"         -o \
             -iname "Code Cache"         -o \
             -iname "GPUCache"           -o \
             -iname "Service Worker"     -o \
             -iname "blob_storage"       -o \
             -iname "DawnCache"          -o \
             -iname "DawnGraphiteCache"  -o \
             -iname "DawnWebGPUCache"    -o \
             -iname "ShaderCache"        -o \
             -iname "GrShaderCache"      \
           \) -prune -print0 2>>"$LOG_FILE")

  clear_paths "Electron/Chromium caches" dir ${hits[@]+"${hits[@]}"}

  # Sandboxed apps (Teams, Outlook, Mail, Weather, ...) can't see ~/Library,
  # so macOS gives each one a private Caches dir inside its container. Same
  # disposable data as ~/Library/Caches, invisible to step_usercaches.
  # Contents only: the Caches dir itself carries sandbox ACLs worth keeping.
  local containers="$HOME/Library/Containers"
  local -a ccaches=()
  if [[ -d "$containers" ]]; then
    while IFS= read -r -d '' d; do
      ccaches+=("$d")
    done < <(find "$containers" -maxdepth 4 -type d -path "*/Data/Library/Caches" \
               -print0 2>>"$LOG_FILE")
  fi
  clear_paths "sandboxed app caches" contents ${ccaches[@]+"${ccaches[@]}"}

  # VS Code-family editors keep the downloaded .vsix archive for every extension
  # after installing it. Purely a download cache; the installed extension lives
  # in ~/.vscode/extensions (or the editor's equivalent) and is untouched.
  local ed
  local -a vsix=()
  for ed in "${VSCODE_FAMILY[@]}"; do
    [[ -d "$root/$ed/CachedExtensionVSIXs" ]] && vsix+=("$root/$ed/CachedExtensionVSIXs")
  done
  clear_paths "extension VSIX cache" contents ${vsix[@]+"${vsix[@]}"}

  # Apple's aerial wallpaper videos: pure cache, re-downloaded on demand.
  # Only aerials/ — the sibling Store/Index.plist is the wallpaper *config*,
  # and removing it resets the user's chosen desktop background.
  clear_dir "$root/com.apple.wallpaper/aerials"
}

# VS Code-family editors create workspaceStorage/<hash>/ for every folder ever
# opened and never remove it — state DBs, extension scratch data, language-server
# indexes. Entries outlive the projects they belong to indefinitely.
#
# An entry is only dropped when its workspace.json names a local path that no
# longer exists. Anything we can't positively resolve as gone — remote/virtual
# URIs, missing or unparsable workspace.json, a path that still exists in either
# decoded or raw form — is kept. Errors therefore cost disk, never data.
step_workspacestorage() {
  local root="$HOME/Library/Application Support"
  local ed ws dir f uri raw path
  local live=0 unresolved=0
  local -a stale=()

  for ed in "${VSCODE_FAMILY[@]}"; do
    ws="$root/$ed/User/workspaceStorage"
    [[ -d "$ws" ]] || continue
    for dir in "$ws"/*/; do
      [[ -d "$dir" ]] || continue
      f="${dir}workspace.json"
      if [[ ! -f "$f" ]]; then
        unresolved=$(( unresolved + 1 )); continue
      fi
      uri="$(sed -nE 's/.*"(folder|workspace)": *"([^"]*)".*/\2/p' "$f" 2>/dev/null | head -1)"
      # Only reason about local files; remote/virtual workspaces are left alone.
      if [[ "$uri" != file://* ]]; then
        unresolved=$(( unresolved + 1 )); continue
      fi
      raw="${uri#file://}"
      # Percent-decode (%20 -> space). A path containing a literal '%' can decode
      # to garbage, so the raw form is checked too — a bad decode keeps the entry.
      path="$(printf '%b' "${raw//%/\\x}" 2>/dev/null)"
      if [[ -e "$path" || -e "$raw" ]]; then
        live=$(( live + 1 ))
      else
        stale+=("$dir")
      fi
    done
  done

  if (( live + unresolved + ${#stale[@]} == 0 )); then
    info "no editor workspace storage found"
    return 0
  fi
  printf "  %d live · %d stale · %d unresolved %s(kept)%s\n" \
    "$live" "${#stale[@]}" "$unresolved" "$C_DIM" "$C_RESET"
  clear_paths "stale workspace storage" dir ${stale[@]+"${stale[@]}"}
}

step_trash() {
  local trash="$HOME/.Trash"
  if [[ ! -d "$trash" ]]; then
    warn "~/.Trash not found"
    return 0
  fi
  local before_b after_b delta
  before_b="$(path_bytes "$trash")"
  printf "  %s %s(%s)%s\n" "$trash" "$C_DIM" "$(human_bytes "$before_b")" "$C_RESET"
  if (( DRY_RUN )); then
    printf "  %s(dry-run) would empty ~/.Trash%s\n" "$C_DIM" "$C_RESET"
    return 0
  fi
  # -mindepth 1 skips $trash itself; -delete handles hidden files and avoids the
  # '.' / '..' issues that 'rm -rf "$trash"/.*' produces.
  find "$trash" -mindepth 1 -delete 2>>"$LOG_FILE" || true
  after_b="$(path_bytes "$trash")"
  delta=$(( before_b - after_b ))
  (( delta > 0 )) && STEP_FREED_B=$(( STEP_FREED_B + delta ))
  printf "  %s->%s freed %s from ~/.Trash\n" "$C_GREEN" "$C_RESET" "$(human_bytes "$delta")"
}

step_devcaches() {
  local any=0
  local node_ok=0
  if command -v node >/dev/null 2>&1 && node -v >/dev/null 2>&1; then
    node_ok=1
  fi

  if command -v npm >/dev/null 2>&1; then
    any=1
    local d="$HOME/.npm"
    printf "  npm cache %s(%s)%s\n" "$C_DIM" "$(human_bytes "$(path_bytes "$d")")" "$C_RESET"
    if (( node_ok )); then
      run_cmd "npm cache clean --force" npm cache clean --force || warn "'npm cache clean' failed"
    else
      warn "node is not runnable; skipping npm cache clean (try: brew reinstall node)"
    fi
  fi

  if command -v yarn >/dev/null 2>&1; then
    any=1
    local d="$HOME/Library/Caches/Yarn"
    printf "  yarn cache %s(%s)%s\n" "$C_DIM" "$(human_bytes "$(path_bytes "$d")")" "$C_RESET"
    if (( node_ok )); then
      run_cmd "yarn cache clean" yarn cache clean || warn "'yarn cache clean' failed"
    else
      warn "node is not runnable; skipping yarn cache clean (try: brew reinstall node)"
    fi
  fi

  if command -v pnpm >/dev/null 2>&1; then
    any=1
    if (( node_ok )); then
      run_cmd "pnpm store prune" pnpm store prune || warn "'pnpm store prune' failed"
    else
      warn "node is not runnable; skipping pnpm store prune (try: brew reinstall node)"
    fi
  fi

  if command -v pip3 >/dev/null 2>&1; then
    any=1
    # pip may print "WARNING: No matching packages" even with -q; filter that noise from the
    # terminal while keeping full output in the log.
    if (( DRY_RUN )); then
      run_cmd "pip3 cache purge" pip3 cache purge -q || warn "'pip3 cache purge' failed"
    else
      echo "# $(date '+%H:%M:%S') [pip3 cache purge] >> pip3 cache purge -q" >>"$LOG_FILE"
      local rc=0
      pip3 cache purge -q 2>&1 \
        | tee -a "$LOG_FILE" \
        | awk '!/^WARNING: No matching packages$/'
      rc="${PIPESTATUS[0]}"
      if (( rc != 0 )); then STEP_WARN_COUNT=$(( STEP_WARN_COUNT + 1 )); fi
    fi
  elif command -v pip >/dev/null 2>&1; then
    any=1
    if (( DRY_RUN )); then
      run_cmd "pip cache purge" pip cache purge -q || warn "'pip cache purge' failed"
    else
      echo "# $(date '+%H:%M:%S') [pip cache purge] >> pip cache purge -q" >>"$LOG_FILE"
      local rc=0
      pip cache purge -q 2>&1 \
        | tee -a "$LOG_FILE" \
        | awk '!/^WARNING: No matching packages$/'
      rc="${PIPESTATUS[0]}"
      if (( rc != 0 )); then STEP_WARN_COUNT=$(( STEP_WARN_COUNT + 1 )); fi
    fi
  fi

  if command -v gem >/dev/null 2>&1; then
    any=1
    run_cmd "gem cleanup" gem cleanup || warn "'gem cleanup' failed"
  fi

  if command -v go >/dev/null 2>&1; then
    any=1
    run_cmd "go clean -cache -modcache -testcache" go clean -cache -modcache -testcache \
      || warn "'go clean' failed"
  fi

  if command -v cargo >/dev/null 2>&1 && command -v cargo-cache >/dev/null 2>&1; then
    any=1
    run_cmd "cargo cache --autoclean" cargo cache --autoclean || warn "'cargo cache' failed"
  fi

  if (( any == 0 )); then
    info "no known developer toolchains found — nothing to do"
  fi
}

step_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not on PATH"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    warn "docker daemon not reachable"
    return 1
  fi

  # Safety: avoid pruning a remote Docker context.
  local ctx host
  ctx="$(docker context show 2>/dev/null || true)"
  host="$(docker context inspect "${ctx:-default}" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null || true)"
  if [[ -n "$host" ]] && [[ "$host" != unix://* ]]; then
    warn "docker context '${ctx:-?}' points to non-local host (${host}) — skipping prune"
    return 0
  fi

  # Size before
  local before after
  before="$(docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null | awk -F'\t' '{print $1": "$2}' | paste -sd ', ' - || echo 'unknown')"
  printf "  docker disk usage: %s%s%s\n" "$C_DIM" "$before" "$C_RESET"

  # Keep tagged images, remove only dangling (<none>) ones.
  run_cmd "docker container prune -f" docker container prune -f \
    || warn "'docker container prune' failed"
  run_cmd "docker network prune -f" docker network prune -f \
    || warn "'docker network prune' failed"
  run_cmd "docker volume prune -f" docker volume prune -f \
    || warn "'docker volume prune' failed"
  run_cmd "docker image prune -f" docker image prune -f \
    || warn "'docker image prune' failed"
  run_cmd "docker builder prune -af"          docker builder prune -af \
    || warn "'docker builder prune' failed"

  after="$(docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null | awk -F'\t' '{print $1": "$2}' | paste -sd ', ' - || echo 'unknown')"
  printf "  docker disk usage after: %s%s%s\n" "$C_DIM" "$after" "$C_RESET"
}

step_xcode() {
  local any=0
  local targets=(
    "$HOME/Library/Developer/Xcode/Archives"
    "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
    "$HOME/Library/Developer/Xcode/watchOS DeviceSupport"
    "$HOME/Library/Developer/Xcode/tvOS DeviceSupport"
    "$HOME/Library/Developer/CoreSimulator/Caches"
  )
  for d in "${targets[@]}"; do
    if [[ -d "$d" ]]; then
      any=1
      clear_dir "$d"
    fi
  done

  if command -v xcrun >/dev/null 2>&1 && xcrun simctl help >/dev/null 2>&1; then
    any=1
    run_cmd "xcrun simctl delete unavailable" xcrun simctl delete unavailable \
      || warn "'simctl delete unavailable' failed"
  fi

  if (( any == 0 )); then
    info "no Xcode data to clean"
  fi
}

step_diagnostics() {
  # User diagnostic / crash reports
  local user_dirs=(
    "$HOME/Library/Logs/DiagnosticReports"
    "$HOME/Library/DiagnosticReports"
  )
  for d in "${user_dirs[@]}"; do
    clear_dir "$d"
  done

  # System diagnostic reports (sudo)
  if (( SKIP_DIAGNOSTICS_SYS == 0 )); then
    local sys_dirs=(
      "/Library/Logs/DiagnosticReports"
      "/Library/Logs/CrashReporter"
    )
    for d in "${sys_dirs[@]}"; do
      clear_dir "$d" sudo
    done
  else
    info "skipping system diagnostic reports (--no-sudo or sudo unavailable)"
  fi
}

step_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    warn "brew not on PATH"
    return 1
  fi

  # Some casks (Docker, Karabiner, VirtualBox, ...) invoke sudo during their
  # postinstall. Re-prime the sudo timestamp right before we start so brew's
  # internal `sudo -n` calls find a valid credential.
  if (( USE_SUDO )) && (( SUDO_AVAILABLE )) && (( DRY_RUN == 0 )); then
    sudo -v 2>/dev/null || true
  fi

  # Avoid brew kicking off an extra `brew update` under each subcommand —
  # we call it explicitly below.
  export HOMEBREW_NO_AUTO_UPDATE=1
  # Make cask installs less chatty and less likely to open GUIs mid-run.
  export HOMEBREW_NO_ENV_HINTS=1

  run_cmd     "brew update"         brew update    || warn "'brew update' had issues"
  # Cask upgrades may prompt for sudo; run attached to the TTY so the prompt
  # is visible and the user can answer it.
  if ! run_cmd_tty "brew upgrade" brew upgrade; then
    warn "'brew upgrade' had issues"
    if grep -q "Command Line Tools are too outdated" "$LOG_FILE" 2>/dev/null; then
      warn "Homebrew reports Xcode Command Line Tools are outdated. Update via System Settings → Software Update, or: sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install"
    fi
  fi

  if (( BREW_GREEDY )); then
    run_cmd_tty "brew upgrade --cask --greedy" brew upgrade --cask --greedy \
      || warn "'brew upgrade --cask --greedy' had issues"
  else
    run_cmd_tty "brew upgrade --cask" brew upgrade --cask \
      || warn "'brew upgrade --cask' had issues"
    info "skipping '--greedy' cask upgrades; pass --brew-greedy to include them"
  fi

  # brew cleanup may emit "Warning: Skipping <formula>: most recent version ... not installed"
  # in verbose mode; it's harmless and noisy, so filter it from the terminal while keeping
  # the full output in the log.
  if (( VERBOSE )); then
    echo "# $(date '+%H:%M:%S') [brew cleanup -s] >> brew cleanup -s" >>"$LOG_FILE"
    local rc=0
    brew cleanup -s 2>&1 \
      | tee -a "$LOG_FILE" \
      | awk '!/^Warning: Skipping .*most recent version .* not installed$/'
    rc="${PIPESTATUS[0]}"
    if (( rc != 0 )); then STEP_WARN_COUNT=$(( STEP_WARN_COUNT + 1 )); fi
  else
    run_cmd "brew cleanup -s" brew cleanup -s || warn "'brew cleanup' had issues"
  fi
  run_cmd "brew autoremove"        brew autoremove             || warn "'brew autoremove' had issues"
  if (( VERBOSE )); then
    run_cmd "brew doctor" brew doctor || warn "'brew doctor' reports issues — see log"
  fi
}

# The version managers themselves (pyenv/tfenv/goenv/tenv/helm,
# gcloud-cli cask) are already upgraded by the brew step above. The steps
# below refresh what sits on top of them; each is intentionally isolated so
# it can be skipped independently (and so failures don't mask each other).
# None of them auto-install new Python/Go/Terraform majors — that's an
# explicit action best left to install_devtools.sh.

# Helm plugins are outside of brew's world, so they go stale quickly.
# 'helm plugin update <name>' pulls the latest release for each one.
step_helm_plugins() {
  if ! command -v helm >/dev/null 2>&1; then
    info "helm not installed — nothing to refresh"
    return 0
  fi
  local plugins
  plugins="$(helm plugin list 2>/dev/null | awk 'NR>1 && NF {print $1}')"
  if [[ -z "$plugins" ]]; then
    info "no helm plugins installed — nothing to refresh"
    return 0
  fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    run_cmd "helm plugin update $p" helm plugin update "$p" \
      || warn "'helm plugin update $p' failed"
  done <<< "$plugins"
}

# gcloud components (e.g. gke-gcloud-auth-plugin, kubectl, beta, alpha) that
# were installed via 'gcloud components install' live under the brew-cask
# SDK dir and aren't refreshed by 'brew upgrade'. Components installed via
# brew directly are already covered by the brew step.
step_gcloud() {
  if ! command -v gcloud >/dev/null 2>&1; then
    info "gcloud not installed — nothing to refresh"
    return 0
  fi
  # Some gcloud builds disable the in-place component manager (e.g. when
  # installed from a distro package); in that case there's nothing to do.
  if ! gcloud components list --quiet >/dev/null 2>&1; then
    info "gcloud present but component manager unavailable — skipping components update"
    return 0
  fi
  run_cmd "gcloud components update --quiet" gcloud components update --quiet \
    || warn "'gcloud components update' had issues"

  # Some gcloud installs on macOS require a separate Python/runtime update step.
  # Best-effort: if it exists, run it to avoid the recurring warning.
  if gcloud help components update-macos-python >/dev/null 2>&1; then
    run_cmd "gcloud components update-macos-python" gcloud components update-macos-python --quiet \
      || warn "'gcloud components update-macos-python' had issues"
  fi
}

# Report currently-active managed versions so the user can see what's in use.
# Read-only: these tools don't self-update their installed language versions;
# the brew step keeps the managers fresh, re-run install_devtools.sh to move
# to a new Python/Go/Terraform minor.
step_versions() {
  local any=0 line
  if command -v pyenv >/dev/null 2>&1; then
    any=1
    line="$(pyenv version-name 2>/dev/null || echo '?')"
    printf "  pyenv active:  %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
  fi
  if command -v goenv >/dev/null 2>&1; then
    any=1
    line="$(goenv version-name 2>/dev/null || echo '?')"
    printf "  goenv active:  %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
  fi
  if command -v tfenv >/dev/null 2>&1; then
    any=1
    line="$(tfenv version-name 2>/dev/null || echo '?')"
    printf "  tfenv active:  %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
  fi
  if command -v tenv >/dev/null 2>&1; then
    any=1
    line="$(tenv tf current 2>/dev/null || echo '?')"
    printf "  tenv   active: %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
  fi
  if command -v helm >/dev/null 2>&1; then
    any=1
    line="$(helm version --short 2>/dev/null | head -n1 || echo '?')"
    printf "  helm:          %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
  fi
  if command -v gcloud >/dev/null 2>&1; then
    any=1
    line="$(gcloud version 2>/dev/null | head -n1 || echo '?')"
    printf "  gcloud:        %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
  fi
  if (( any == 0 )); then
    info "no dev toolchain managers found (pyenv/goenv/tfenv/tenv/helm/gcloud) — nothing to report"
  fi
}

# ---------------------------------------------------------------------------
# execute
# ---------------------------------------------------------------------------
START_ALL=$(date +%s)

run_or_skip() {
  local label="$1" skip_flag="$2" fn="$3"
  if (( skip_flag )); then
    step "$label"
    printf "  %sskipped%s\n" "$C_DIM" "$C_RESET"
    STEPS_SKIP+=("$label")
    return 0
  fi
  do_step "$label" "$fn"
}

run_or_skip "Purge inactive memory"                "$SKIP_MEMORY"      step_memory
run_or_skip "Flush DNS cache"                      "$SKIP_DNS"         step_dns
run_or_skip "Clear system caches"                  "$SKIP_SYSCACHES"   step_syscaches
run_or_skip "Clear user caches"                    "$SKIP_USERCACHES"  step_usercaches
run_or_skip "Clear per-app caches"                 "$SKIP_APPCACHES"   step_appcaches
run_or_skip "Prune stale workspace storage"        "$SKIP_WORKSPACESTORAGE" step_workspacestorage
run_or_skip "Empty trash"                          "$SKIP_TRASH"       step_trash
run_or_skip "Docker / OrbStack prune"              "$SKIP_DOCKER"      step_docker
run_or_skip "Xcode extras"                         "$SKIP_XCODE"       step_xcode
run_or_skip "Diagnostic / crash reports"           "$SKIP_DIAGNOSTICS" step_diagnostics
run_or_skip "Homebrew update / upgrade / cleanup"  "$SKIP_BREW"         step_brew
run_or_skip "Dev-tool caches"                      "$SKIP_DEVCACHES"   step_devcaches
run_or_skip "Helm plugin refresh"                  "$SKIP_HELM_PLUGINS" step_helm_plugins
run_or_skip "gcloud components update"             "$SKIP_GCLOUD"       step_gcloud
run_or_skip "Active tool versions"                 "$SKIP_VERSIONS"     step_versions

ELAPSED=$(( $(date +%s) - START_ALL ))
FREE_AFTER_B="$(disk_free_bytes)"
RECLAIMED_B=$(( FREE_AFTER_B - FREE_BEFORE_B ))

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
hr
bold "=== stay_fresh: summary ==="
printf "  elapsed:     %s\n" "$(human_duration "$ELAPSED")"
printf "  disk free:   %s -> %s  %s(%s reclaimed)%s\n" \
  "$(human_bytes "$FREE_BEFORE_B")" \
  "$(human_bytes "$FREE_AFTER_B")" \
  "$C_GREEN" "$(human_bytes "$RECLAIMED_B")" "$C_RESET"
printf "  steps freed: %s%s%s %s(sum of per-step deltas; more precise than df)%s\n" \
  "$C_GREEN" "$(human_bytes "$TOTAL_FREED_B")" "$C_RESET" "$C_DIM" "$C_RESET"
printf "  ok steps:    %s%d%s\n" "$C_GREEN"  "${#STEPS_OK[@]}"   "$C_RESET"
printf "  warn steps:  %s%d%s\n" "$C_YELLOW" "${#STEPS_WARN[@]}" "$C_RESET"
printf "  skipped:     %s%d%s\n" "$C_DIM"    "${#STEPS_SKIP[@]}" "$C_RESET"
printf "  failed:      %s%d%s\n" "$C_RED"    "${#STEPS_FAIL[@]}" "$C_RESET"

print_group() {
  local title="$1" color="$2"; shift 2
  (( $# == 0 )) && return 0
  printf "\n%s%s:%s\n" "$color" "$title" "$C_RESET"
  for item in "$@"; do printf "  - %s\n" "$item"; done
}

(( ${#STEPS_OK[@]}   > 0 )) && print_group "OK"      "$C_GREEN"  "${STEPS_OK[@]}"
(( ${#STEPS_WARN[@]} > 0 )) && print_group "Warned"  "$C_YELLOW" "${STEPS_WARN[@]}"
(( ${#STEPS_SKIP[@]} > 0 )) && print_group "Skipped" "$C_DIM"    "${STEPS_SKIP[@]}"
(( ${#STEPS_FAIL[@]} > 0 )) && print_group "Failed"  "$C_RED"    "${STEPS_FAIL[@]}"

echo
if (( ${#STEPS_FAIL[@]} > 0 || ${#STEPS_WARN[@]} > 0 )); then
  PERSISTENT_LOG_DIR="$HOME/Library/Logs/stay_fresh"
  mkdir -p "$PERSISTENT_LOG_DIR"
  SAVED_LOG="$PERSISTENT_LOG_DIR/$(basename "$LOG_FILE")"
  if cp "$LOG_FILE" "$SAVED_LOG" 2>/dev/null; then
    rm -f "$LOG_FILE"
  else
    SAVED_LOG="$LOG_FILE"
  fi
  # keep only the 10 most recent logs
  find "$PERSISTENT_LOG_DIR" -name 'stay_fresh-*.log' -type f \
    | sort -r | tail -n +11 | xargs rm -f 2>/dev/null || true
  warn "log saved: $SAVED_LOG"
  printf "  %sTo inspect:%s tail -80 '%s'\n" "$C_DIM" "$C_RESET" "$SAVED_LOG"
else
  rm -f "$LOG_FILE"
  info "run clean — log discarded"
fi

if (( ${#STEPS_FAIL[@]} > 0 )); then
  exit 1
fi

ok "You're fresh. Consider a reboot if things still feel sluggish."

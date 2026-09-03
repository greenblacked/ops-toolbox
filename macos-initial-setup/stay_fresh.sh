#!/usr/bin/env bash
# stay_fresh.sh
# Keep your macOS clean and up-to-date:
#   - optionally purge disk caches for cold-cache troubleshooting
#   - flush DNS caches
#   - clear /Library/Caches and writable /System/Library/Caches
#   - clear ~/Library caches (Caches, Saved State, Xcode DerivedData, ...)
#   - clear per-app caches missed by the above: Chromium/Electron dirs under
#     known Application Support roots and cached extension .vsix archives;
#     sandboxed app caches require an explicit force flag
#   - clear disposable AI desktop/CLI caches while preserving sessions,
#     credentials, projects, extensions, runtimes, and downloaded models
#   - prune VS Code workspaceStorage for projects that no longer exist
#   - empty ~/.Trash
#   - clean developer tool caches (npm, yarn, pnpm, pip, go); uninstall old gem
#     versions only when explicitly requested
#   - prune Docker / OrbStack (images, containers, builder cache; volumes
#     only with --prune-docker-volumes, because volumes hold data)
#   - clean Xcode extras (DeviceSupport, stale simulators, optionally old Archives)
#   - clean diagnostic / crash reports (as user; system dirs if sudo)
#   - Homebrew: update, upgrade (formulae + casks), cleanup -s, autoremove
#   - refresh dev toolchains (helm plugins, gcloud components) installed by
#     install_apps.sh / install_devtools.sh
#
# Usage:
#   ./stay_fresh.sh [--dry-run] [--yes] [--verbose]
#                   [--only STEP1,STEP2] [--list-steps]
#                   [--purge-memory] [--skip-memory] [--skip-dns] [--skip-syscaches]
#                   [--skip-usercaches] [--skip-appcaches]
#                   [--skip-aicaches]
#                   [--skip-workspacestorage] [--skip-trash]
#                   [--skip-brew] [--brew-greedy] [--skip-devcaches]
#                   [--cleanup-old-gems] [--fail-on-warn]
#                   [--skip-devtools] [--skip-helm-plugins] [--skip-gcloud]
#                   [--skip-versions] [--skip-docker] [--prune-docker-volumes]
#                   [--skip-xcode] [--prune-xcode-archives-days N]
#                   [--force-active-app-caches] [--skip-diagnostics]
#                   [--no-sudo] [--help]
#
# Exit codes:
#   0   housekeeping finished (possibly with non-fatal warnings)
#   1   one or more steps hard-failed, or a warning occurred with --fail-on-warn
#   2   preflight checks failed
#   3   bad CLI arguments

set -u
set -o pipefail

# Where this script lives, so it can find lib/ regardless of the caller's cwd or
# whether it was invoked through a symlink on PATH.
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# ---------------------------------------------------------------------------
# output helpers (TTY-aware colors)
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_CYAN=$'\033[1;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

bold()  { printf "%s%s%s\n" "$C_BOLD"    "$*" "$C_RESET"; }
info()  { printf "%s[info]%s %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf "%s[ ok ]%s %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf "%s[warn]%s %s\n"  "$C_YELLOW" "$C_RESET" "$*"; }
# warn() only prints. Inside a step that is not enough: do_step decides OK vs
# WARN from STEP_WARN_COUNT, so a bare warn leaves the step reporting [ ok ] and
# landing in STEPS_OK however loudly it complained.
#
# Use warn_step only when the step could not do the work it was asked to do —
# a broken toolchain, a prune skipped because the target is remote, an upgrade
# that errored. Not for conditions that hold on a perfectly healthy machine:
# a tool that simply is not installed, or apps being open during a cache sweep.
# Those stay plain warn. A step that reports WARN on every ordinary run trains
# you to stop reading the summary, which costs more than it catches.
warn_step() { warn "$*"; STEP_WARN_COUNT=$(( STEP_WARN_COUNT + 1 )); }
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
FAIL_ON_WARN=0

# `purge` approximates a cold-cache boot for performance analysis; it is not
# routine memory maintenance, so it is deliberately opt-in.
SKIP_MEMORY=1
SKIP_DNS=0
SKIP_SYSCACHES=0
SKIP_USERCACHES=0
SKIP_APPCACHES=0
SKIP_AICACHES=0
SKIP_WORKSPACESTORAGE=0
SKIP_TRASH=0
SKIP_BREW=0
SKIP_DEVCACHES=0
SKIP_DEVTOOLS=0
SKIP_HELM_PLUGINS=0
SKIP_GCLOUD=0
SKIP_VERSIONS=0
SKIP_DOCKER=0
PRUNE_DOCKER_VOLUMES=0
SKIP_XCODE=0
SKIP_DIAGNOSTICS=0
BREW_GREEDY=0
CLEANUP_OLD_GEMS=0
FORCE_ACTIVE_APP_CACHES=0
XCODE_ARCHIVE_DAYS=""
ONLY_STEPS=""
# Step ids named by --only, and the subset of those that preflight went on to
# disable. A step the user asked for by name and did not get is a different
# outcome from one they never mentioned, and the summary has to say so.
ONLY_SELECTED=()
AUTO_SKIPPED_IDS=()
AUTO_SKIPPED_WHY=()
LIST_STEPS=0
EXPLICIT_SKIP=0
PURGE_MEMORY_EXPLICIT=0

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

# A manual invocation and the LaunchAgent can otherwise overlap and run package
# upgrades or delete the same cache tree concurrently.
#
# Deliberately NOT under TMPDIR. The LaunchAgent's environment carries only
# PATH, so an agent run resolved "${TMPDIR:-/tmp}" to /tmp while a terminal
# run resolved it to the per-user /var/folders/... directory - two different
# lock directories, and the exact overlap this lock exists to prevent went
# unprevented. HOME is identical in both contexts. Application Support is
# safe from this script's own sweeps: user-caches clears only its four listed
# targets and app-caches walks only known application roots. The override
# exists for tests, which must not share a lock with a real run.
LOCK_PARENT="${STAY_FRESH_LOCK_DIR:-$HOME/Library/Application Support/stay_fresh}"
LOCK_DIR="$LOCK_PARENT/run.lock"
LOCK_HELD=0
SUDO_KEEPALIVE_PID=""

cleanup_on_exit() {
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if (( LOCK_HELD )); then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

acquire_lock() {
  # The parent is created separately: mkdir -p on the lock directory itself
  # would report success for one that already exists, which is exactly the
  # atomicity the bare mkdir below provides.
  if ! mkdir -p "$LOCK_PARENT" 2>/dev/null; then
    err "cannot create $LOCK_PARENT to hold the run lock"
    return 1
  fi
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      err "cannot write run lock metadata at $LOCK_DIR/pid"
      return 1
    fi
    LOCK_HELD=1
    return 0
  fi

  # A failed mkdir is not proof that another run holds the lock — ENOENT and
  # EACCES land here too. The stale-lock recovery below would then announce a
  # lock that never existed and try to delete it, burying the real cause under
  # a fabricated one. Only an existing directory means contention.
  if [[ ! -d "$LOCK_DIR" ]]; then
    err "cannot acquire run lock at $LOCK_DIR"
    return 1
  fi

  local existing_pid=""
  [[ -r "$LOCK_DIR/pid" ]] && read -r existing_pid < "$LOCK_DIR/pid"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    err "another stay_fresh run is active (pid $existing_pid)"
    return 1
  fi

  if [[ -n "$existing_pid" ]]; then
    warn "removing stale stay_fresh lock for pid $existing_pid"
  else
    warn "removing stale stay_fresh lock without a live pid"
  fi
  rm -f "$LOCK_DIR/pid"
  if rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
    if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      err "cannot write run lock metadata at $LOCK_DIR/pid"
      return 1
    fi
    LOCK_HELD=1
    return 0
  fi

  err "cannot acquire run lock at $LOCK_DIR"
  return 1
}

list_steps() {
  cat <<'EOF'
memory            purge inactive memory (also requires --purge-memory)
dns               flush DNS caches
system-caches     clear root-owned macOS caches
user-caches       clear user caches
app-caches        clear disposable per-app caches
ai-caches         clear disposable AI tool caches
workspace-storage prune stale editor workspace storage
trash             empty the user's Trash
docker            prune local Docker / OrbStack resources
xcode             clean safe Xcode extras
diagnostics       remove crash and diagnostic reports
brew              update, upgrade and clean Homebrew
dev-caches        clean language and package-manager caches
helm-plugins      update installed Helm plugins
gcloud            update gcloud components
versions          print active tool versions
EOF
}

usage() {
  cat <<EOF
${C_BOLD}stay_fresh.sh${C_RESET} — macOS housekeeping in one script.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [options]

${C_BOLD}General options:${C_RESET}
  --dry-run              Preview actions, change nothing
  --yes, -y              Authorize non-interactive mutation; suppress prompts
  --verbose, -v          Stream command output (default: captured to log)
  --fail-on-warn         Exit 1 when any step finishes with a real warning
  --no-sudo              Skip root-owned steps and Homebrew cask upgrades
  --only STEP1,STEP2     Run only the named steps (see --list-steps)
  --list-steps           Print stable step ids and exit
  --help, -h             Show this help

${C_BOLD}Step toggles (skip individual steps):${C_RESET}
  --purge-memory         Run 'sudo purge' (cold-cache troubleshooting only)
  --skip-memory          Keep purge disabled (compatibility flag; the default)
  --skip-dns             Don't flush DNS caches
  --skip-syscaches       Don't touch /Library/Caches or /System/Library/Caches
  --skip-usercaches      Don't clear ~/Library/Caches et al.
  --skip-appcaches       Don't clear per-app caches (see Notes)
  --force-active-app-caches
                         Also clear running known-app and sandboxed-app caches
  --skip-aicaches        Don't clear AI desktop/CLI temporary caches
  --skip-workspacestorage
                         Don't prune stale VS Code workspace storage
  --skip-trash           Don't empty ~/.Trash
  --skip-brew            Don't run Homebrew maintenance (see Notes)
  --brew-greedy          Also upgrade casks with 'auto_updates true' / 'version :latest'
                         (may prompt for sudo during cask postinstalls)
  --skip-devcaches       Don't clean npm/yarn/pnpm/pip/go caches
  --cleanup-old-gems     Uninstall old gem versions during dev-cache cleanup
                         (off by default; this changes installed packages)
  --skip-devtools        Shorthand: skip all dev-tool refresh steps below
                         (--skip-helm-plugins --skip-gcloud --skip-versions)
  --skip-helm-plugins    Don't run 'helm plugin update' for installed plugins
  --skip-gcloud          Don't run 'gcloud components update'
  --skip-versions        Don't print active pyenv/goenv/tfenv/tenv/helm/gcloud
                         versions
  --skip-docker          Don't prune Docker / OrbStack
  --prune-docker-volumes Also remove unused Docker volumes (they hold data,
                         not cache, so the default keeps them)
  --skip-xcode           Don't clean Xcode DeviceSupport/simulators/old Archives
  --prune-xcode-archives-days N
                         Remove only .xcarchive bundles older than N days
  --skip-diagnostics     Don't remove crash / diagnostic reports (see Notes)

${C_BOLD}Notes:${C_RESET}
  --only: preflight can still disable a step the machine cannot run (no
  Homebrew, no Docker daemon, no Xcode data, --no-sudo against a root-owned
  step). Such a selection is reported by name; if every id you named is
  disabled the run stops with exit 2 instead of doing nothing quietly.

  Per-app caches: covers Chromium-internal dirs (Cache, Code Cache, GPUCache,
  Service Worker, blob_storage) under known Application Support roots, plus
  cached extension .vsix archives. Roots belonging to running applications are
  kept. Sandboxed-container caches cannot be mapped reliably to process state,
  so they are also kept unless --force-active-app-caches is explicit.

  AI caches: clears disposable caches for Claude, Codex, ChatGPT, Cursor, and
  Windsurf only while the matching tool is confirmed not running. If process
  state cannot be checked, caches are kept. Credentials, settings,
  conversations/sessions, projects, extensions, runtimes, and local models are
  always kept.

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
  postinstall and are skipped with --no-sudo or without a controlling terminal
  (--brew-greedy changes which casks upgrade).

Log file: $LOG_FILE
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    -y|--yes)          ASSUME_YES=1 ;;
    -v|--verbose)      VERBOSE=1 ;;
    --fail-on-warn)    FAIL_ON_WARN=1 ;;
    --no-sudo)         USE_SUDO=0 ;;
    --only)
      shift
      [[ -n "${1:-}" && "$1" != --* ]] || { err "--only needs a value"; exit 3; }
      ONLY_STEPS="$1"
      ;;
    --only=*)
      ONLY_STEPS="${1#*=}"
      [[ -n "$ONLY_STEPS" ]] || { err "--only needs a value"; exit 3; }
      ;;
    --list-steps)      LIST_STEPS=1 ;;
    --purge-memory)    SKIP_MEMORY=0; PURGE_MEMORY_EXPLICIT=1 ;;
    --skip-memory)     SKIP_MEMORY=1; EXPLICIT_SKIP=1 ;;
    --skip-dns)        SKIP_DNS=1; EXPLICIT_SKIP=1 ;;
    --skip-syscaches)  SKIP_SYSCACHES=1; EXPLICIT_SKIP=1 ;;
    --skip-usercaches) SKIP_USERCACHES=1; EXPLICIT_SKIP=1 ;;
    --skip-appcaches)  SKIP_APPCACHES=1; EXPLICIT_SKIP=1 ;;
    --skip-aicaches)   SKIP_AICACHES=1; EXPLICIT_SKIP=1 ;;
    --force-active-app-caches) FORCE_ACTIVE_APP_CACHES=1 ;;
    --skip-workspacestorage) SKIP_WORKSPACESTORAGE=1; EXPLICIT_SKIP=1 ;;
    --skip-trash)      SKIP_TRASH=1; EXPLICIT_SKIP=1 ;;
    --skip-brew)       SKIP_BREW=1; EXPLICIT_SKIP=1 ;;
    --brew-greedy)     BREW_GREEDY=1 ;;
    --skip-devcaches)  SKIP_DEVCACHES=1; EXPLICIT_SKIP=1 ;;
    --cleanup-old-gems) CLEANUP_OLD_GEMS=1 ;;
    --skip-devtools)   SKIP_DEVTOOLS=1; EXPLICIT_SKIP=1 ;;
    --skip-helm-plugins) SKIP_HELM_PLUGINS=1; EXPLICIT_SKIP=1 ;;
    --skip-gcloud)     SKIP_GCLOUD=1; EXPLICIT_SKIP=1 ;;
    --skip-versions)   SKIP_VERSIONS=1; EXPLICIT_SKIP=1 ;;
    --skip-docker)     SKIP_DOCKER=1; EXPLICIT_SKIP=1 ;;
    --prune-docker-volumes) PRUNE_DOCKER_VOLUMES=1 ;;
    --skip-xcode)      SKIP_XCODE=1; EXPLICIT_SKIP=1 ;;
    --prune-xcode-archives-days)
      shift
      [[ $# -gt 0 ]] || { err "--prune-xcode-archives-days needs a value"; exit 3; }
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || {
        err "--prune-xcode-archives-days must be a positive integer"
        exit 3
      }
      XCODE_ARCHIVE_DAYS="$1"
      ;;
    --skip-diagnostics)SKIP_DIAGNOSTICS=1; EXPLICIT_SKIP=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 err "unknown option: $1"; echo; usage; exit 3 ;;
  esac
  shift
done

if (( LIST_STEPS )); then
  list_steps
  exit 0
fi

if [[ -n "$ONLY_STEPS" ]]; then
  (( EXPLICIT_SKIP == 0 )) || {
    err "--only cannot be combined with individual --skip-* flags"
    exit 3
  }
  SKIP_MEMORY=1
  SKIP_DNS=1
  SKIP_SYSCACHES=1
  SKIP_USERCACHES=1
  SKIP_APPCACHES=1
  SKIP_AICACHES=1
  SKIP_WORKSPACESTORAGE=1
  SKIP_TRASH=1
  SKIP_BREW=1
  SKIP_DEVCACHES=1
  SKIP_HELM_PLUGINS=1
  SKIP_GCLOUD=1
  SKIP_VERSIONS=1
  SKIP_DOCKER=1
  SKIP_XCODE=1
  SKIP_DIAGNOSTICS=1
  selected=0
  IFS=',' read -r -a only_items <<< "$ONLY_STEPS"
  for step_id in "${only_items[@]}"; do
    step_id="$(printf '%s' "$step_id" | tr -d '[:space:]')"
    case "$step_id" in
      memory)
        (( PURGE_MEMORY_EXPLICIT )) || {
          err "--only memory also requires --purge-memory"
          exit 3
        }
        SKIP_MEMORY=0
        ;;
      dns)               SKIP_DNS=0 ;;
      system-caches)     SKIP_SYSCACHES=0 ;;
      user-caches)       SKIP_USERCACHES=0 ;;
      app-caches)        SKIP_APPCACHES=0 ;;
      ai-caches)         SKIP_AICACHES=0 ;;
      workspace-storage) SKIP_WORKSPACESTORAGE=0 ;;
      trash)             SKIP_TRASH=0 ;;
      brew)              SKIP_BREW=0 ;;
      dev-caches)        SKIP_DEVCACHES=0 ;;
      helm-plugins)      SKIP_HELM_PLUGINS=0 ;;
      gcloud)            SKIP_GCLOUD=0 ;;
      versions)          SKIP_VERSIONS=0 ;;
      docker)            SKIP_DOCKER=0 ;;
      xcode)             SKIP_XCODE=0 ;;
      diagnostics)       SKIP_DIAGNOSTICS=0 ;;
      "")                continue ;;
      *) err "unknown step in --only: $step_id (see --list-steps)"; exit 3 ;;
    esac
    ONLY_SELECTED+=("$step_id")
    selected=$((selected + 1))
  done
  (( selected > 0 )) || { err "--only needs at least one step id"; exit 3; }
fi

# Read-only probes still redirect diagnostics. Point those at /dev/null during
# a dry run so merely scanning a populated HOME cannot create the promised log.
LOG_SINK="$LOG_FILE"
(( DRY_RUN )) && LOG_SINK=/dev/null

# --skip-devtools is a convenience; fan it out across the individual
# dev-tool refresh steps so the plan/summary accurately reflects what runs.
if (( SKIP_DEVTOOLS )); then
  SKIP_HELM_PLUGINS=1
  SKIP_GCLOUD=1
  SKIP_VERSIONS=1
fi

# Stock VS Code only (stable + Insiders). Both share the same Application
# Support layout (CachedExtensionVSIXs, User/workspaceStorage, ...), so the
# cache steps below iterate this list rather than special-casing each build.
# Third-party forks are deliberately out of scope.
VSCODE_FAMILY=(
  "Code"
  "Code - Insiders"
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
# Always prints a base-10 integer, never the empty string. `du` writes nothing
# to stdout for a path it cannot read (or one that disappears mid-walk), and an
# empty result poisons every `$(( ... ))` this feeds, so END is unconditional.
path_bytes() {
  local p="$1"
  [[ -e "$p" ]] || { echo 0; return; }
  du -sk "$p" 2>/dev/null | awk 'NR==1 { b = $1 * 1024 } END { printf "%.0f", b + 0 }'
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

# Is there a controlling terminal we can actually talk to?
#
# `[[ -r /dev/tty ]]` is the wrong question: it asks access(2) about the device
# node, which exists and is mode 666 even in a session that has no controlling
# terminal. Opening it there fails with ENXIO. That is precisely the state a
# launchd-scheduled run is in, so the access(2) test reported a usable terminal
# and the cask upgrade below went down the interactive path, failed on the
# redirect, and warned — the outcome the guard exists to avoid. Test the open.
have_tty() {
  { : < /dev/tty; } >/dev/null 2>&1 && { : > /dev/tty; } >/dev/null 2>&1
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
  if have_tty; then
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
  local dir="$1" use_sudo="${2:-}" before_b after_b delta rc=0
  local remaining="" verify_rc=0
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
    sudo find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$LOG_FILE" || rc=$?
    remaining="$(sudo find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>>"$LOG_FILE")" \
      || verify_rc=$?
  else
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$LOG_FILE" || rc=$?
    remaining="$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>>"$LOG_FILE")" \
      || verify_rc=$?
  fi
  after_b="$(path_bytes "$dir")"
  delta=$(( before_b - after_b ))
  (( delta > 0 )) && STEP_FREED_B=$(( STEP_FREED_B + delta ))
  printf "  %s->%s freed %s from %s\n" "$C_GREEN" "$C_RESET" "$(human_bytes "$delta")" "$dir"
  if (( rc != 0 || verify_rc != 0 )) || [[ -n "$remaining" ]]; then
    warn_step "could not fully clear $dir — protected or recreated entries remain"
  fi
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

  local p after_b delta total_b=0 count=$#
  # One du for the whole set rather than one per path. This function's own
  # comment says a sweep can match a few hundred directories, and at that size
  # the forks cost far more than the walk they do: 300 paths measured at 0.64s
  # per-path against 0.004s batched, for a byte-identical total.
  #
  # The path comes back from du rather than from the loop variable, so the
  # verbose line stays correct whatever order du reports in. A path containing
  # a tab or a newline would split wrong here and misreport its size; that is a
  # cosmetic loss on a pathological cache name, and the deletion below still
  # uses "$@" and is unaffected.
  local kb rest
  while read -r kb rest; do
    [[ "$kb" =~ ^[0-9]+$ ]] || continue
    total_b=$(( total_b + kb * 1024 ))
    if (( VERBOSE )); then
      printf "      %s %s(%s)%s\n" \
        "${rest#"$HOME"/}" "$C_DIM" "$(human_bytes $(( kb * 1024 )))" "$C_RESET"
    fi
  done < <(du -sk "$@" 2>/dev/null)
  printf "  %s: %d path(s), %s%s%s\n" \
    "$label" "$count" "$C_DIM" "$(human_bytes "$total_b")" "$C_RESET"

  if (( DRY_RUN )); then
    printf "  %s(dry-run) would clear %d path(s)%s\n" "$C_DIM" "$count" "$C_RESET"
    return 0
  fi

  local delete_failures=0 verify_failures=0 remaining_count=0 remaining=""
  if [[ "$mode" == "contents" ]]; then
    for p in "$@"; do
      find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$LOG_FILE" \
        || delete_failures=$(( delete_failures + 1 ))
    done
  else
    rm -rf "$@" 2>>"$LOG_FILE" || delete_failures=1
  fi

  # Batched for the same reason as the sizing above. A path that vanished in
  # the sweep prints no line at all, which the numeric guard drops; the older
  # per-path form had to special-case that, because an empty command
  # substitution turned `after_b + ` into a bash "operand expected" while the
  # freed total silently inflated.
  after_b=0
  while read -r kb rest; do
    [[ "$kb" =~ ^[0-9]+$ ]] || continue
    after_b=$(( after_b + kb * 1024 ))
  done < <(du -sk "$@" 2>/dev/null)

  # Verification stays per path: it asks a different question of each one, and
  # in "dir" mode it is a shell builtin with no fork to save.
  for p in "$@"; do
    if [[ "$mode" == "contents" ]]; then
      remaining="$(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>>"$LOG_FILE")" \
        || verify_failures=$(( verify_failures + 1 ))
      [[ -n "$remaining" ]] && remaining_count=$(( remaining_count + 1 ))
    elif [[ -e "$p" || -L "$p" ]]; then
      remaining_count=$(( remaining_count + 1 ))
    fi
  done
  delta=$(( total_b - after_b ))
  (( delta > 0 )) && STEP_FREED_B=$(( STEP_FREED_B + delta ))
  printf "  %s->%s freed %s %s(%s)%s\n" \
    "$C_GREEN" "$C_RESET" "$(human_bytes "$delta")" "$C_DIM" "$label" "$C_RESET"
  if (( delete_failures > 0 || verify_failures > 0 || remaining_count > 0 )); then
    warn_step "$label cleanup incomplete — $remaining_count path(s) still contain data"
  fi
}

# ---------------------------------------------------------------------------
# preflight checks
# ---------------------------------------------------------------------------
bold "=== stay_fresh: preflight checks ==="

# Record a step that preflight turned off because the machine cannot run it —
# no Homebrew, no Docker daemon, no sudo. Callers still set the SKIP_ flag
# themselves; this only keeps the reason, so the summary and the --only
# reconciliation below can name it.
note_auto_skip() {
  AUTO_SKIPPED_IDS+=("$1")
  AUTO_SKIPPED_WHY+=("$2")
}

# The reason a given step id was auto-skipped, or the empty string.
auto_skip_reason() {
  local want="$1" i
  for (( i=0; i<${#AUTO_SKIPPED_IDS[@]}; i++ )); do
    if [[ "${AUTO_SKIPPED_IDS[$i]}" == "$want" ]]; then
      printf '%s' "${AUTO_SKIPPED_WHY[$i]}"
      return 0
    fi
  done
  printf ''
}

# A dry run writes nothing, so like --help it answers on a machine that could
# not do the real work — which is what makes the plan reviewable from wherever
# you happen to be. A real run still exits 2 at each of these. The
# non-interactive and lock guards below were already dry-run-aware.
preflight_fail() {
  if (( DRY_RUN == 1 )); then
    warn "$1"
    warn "  (dry-run) previewing anyway; a real run would stop here"
    return 0
  fi
  err "$1"
  exit 2
}

# 1. macOS only
if [[ "$(uname -s)" != "Darwin" ]]; then
  preflight_fail "This script is for macOS only (detected: $(uname -s))."
fi
OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo '?')"
OS_BUILD="$(sw_vers -buildVersion   2>/dev/null || echo '?')"
ARCH="$(uname -m)"
ok "macOS $OS_VERSION ($OS_BUILD) on $ARCH"

# 2. Not root
if [[ "$(id -u)" == "0" ]]; then
  preflight_fail "Do NOT run stay_fresh.sh as root. Run as a normal user; it will ask for sudo."
fi
ok "running as user: $(id -un)"

# A real run with no terminal must be explicitly authorized. This guard comes
# before log creation, sudo, package-manager probes, or any other side effect.
if (( DRY_RUN == 0 && ASSUME_YES == 0 )) && [[ ! -t 0 ]]; then
  err "non-interactive execution requires --yes; refusing to make changes"
  exit 2
fi

if (( DRY_RUN == 0 )); then
  acquire_lock || exit 2
fi

# A dry run writes nothing — including this script's own log. See the same
# guard in install_devtools.sh; run_cmd() already skips the appends.
if (( DRY_RUN == 1 )); then
  info "  (dry-run) would write log: $C_DIM$LOG_FILE$C_RESET"
else
  if ! mkdir -p "$LOG_DIR" || ! : > "$LOG_FILE"; then
    err "cannot initialize log file: $LOG_FILE"
    exit 2
  fi
  echo "stay_fresh.sh log - $(date)" >> "$LOG_FILE"
  info "log file: $C_DIM$LOG_FILE$C_RESET"
fi

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
    note_auto_skip brew "Homebrew is not installed"
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
    note_auto_skip docker "the Docker CLI is not installed"
  elif ! docker info >/dev/null 2>&1; then
    warn "Docker CLI present but daemon unreachable — docker-prune step will be skipped"
    SKIP_DOCKER=1
    note_auto_skip docker "the Docker daemon is unreachable"
  else
    ok "Docker daemon reachable"
  fi
fi

# 4c. Xcode check — auto-skip if no ~/Library/Developer/Xcode and no xcrun simctl
if (( SKIP_XCODE == 0 )); then
  if [[ ! -d "$HOME/Library/Developer/Xcode" ]] && ! command -v xcrun >/dev/null 2>&1; then
    info "No Xcode data found — xcode-extras step will be skipped"
    SKIP_XCODE=1
    note_auto_skip xcode "no Xcode data is present"
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
  # Only the steps that were still going to run belong in this explanation.
  # Memory is opt-in, and --only / --skip-* have already taken others off the
  # list; blaming those on --no-sudo makes a versions-only run look like three
  # root-owned steps were refused.
  if (( SKIP_MEMORY == 0 || SKIP_DNS == 0 || SKIP_SYSCACHES == 0 || SKIP_DIAGNOSTICS == 0 )); then
    warn "--no-sudo set: memory purge, DNS flush, system caches, and system diagnostics will be skipped"
  fi
  (( SKIP_MEMORY == 0 ))    && note_auto_skip memory        "--no-sudo was passed"
  (( SKIP_DNS == 0 ))       && note_auto_skip dns           "--no-sudo was passed"
  (( SKIP_SYSCACHES == 0 )) && note_auto_skip system-caches "--no-sudo was passed"
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
    # Keep the sudo timestamp warm for the length of the run. Disowned so the
    # EXIT kill does not print bash's "Terminated: 15" job noise.
    #
    # Two details are load-bearing. The redirections detach this subshell from
    # the script's stdio: it forks `sleep`, the trap below kills the subshell
    # but not that grandchild, and an orphaned `sleep` holding the write end of
    # the caller's pipe blocks every caller that captures output —
    # `out="$(stay_fresh ...)"`, a CI step, the LaunchAgent's log redirect —
    # until it finally expires. And the wait is broken into short naps that
    # re-check the parent, so the orphan window is seconds rather than a full
    # minute.
    ( while kill -0 "$$" 2>/dev/null; do
        sudo -n true 2>/dev/null || exit
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
          sleep 5
          kill -0 "$$" 2>/dev/null || exit
        done
      done ) </dev/null >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
    disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || disown || true
  else
    err "sudo authentication failed — disabling sudo-requiring steps"
    (( SKIP_MEMORY == 0 ))    && note_auto_skip memory        "sudo authentication failed"
    (( SKIP_DNS == 0 ))       && note_auto_skip dns           "sudo authentication failed"
    (( SKIP_SYSCACHES == 0 )) && note_auto_skip system-caches "sudo authentication failed"
    SKIP_MEMORY=1
    SKIP_DNS=1
    SKIP_SYSCACHES=1
    SKIP_DIAGNOSTICS_SYS=1
  fi
elif (( DRY_RUN && NEEDS_SUDO )); then
  info "(dry-run) would request sudo for memory/DNS/system-caches/diagnostics steps"
fi

SKIP_DIAGNOSTICS_SYS="${SKIP_DIAGNOSTICS_SYS:-0}"

# --only names the work you want done. Preflight can quietly take a step back
# off that list — no Homebrew, no Docker daemon, --no-sudo — and the run then
# reaches the summary having done nothing while still exiting 0, which reads as
# success. Reconcile the two lists and say plainly what is left.
if (( ${#ONLY_SELECTED[@]} > 0 )); then
  only_voided=()
  only_voided_why=()
  for step_id in "${ONLY_SELECTED[@]}"; do
    why="$(auto_skip_reason "$step_id")"
    [[ -n "$why" ]] || continue
    only_voided+=("$step_id")
    only_voided_why+=("$why")
  done
  if (( ${#only_voided[@]} > 0 )); then
    for (( i=0; i<${#only_voided[@]}; i++ )); do
      warn "--only ${only_voided[$i]}: ${only_voided_why[$i]} — that step cannot run here"
    done
    if (( ${#only_voided[@]} == ${#ONLY_SELECTED[@]} )); then
      preflight_fail "every step named by --only was disabled by preflight; nothing to do"
    fi
  fi
fi

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
plan_line "purge disk caches"                 "$(( 1 - SKIP_MEMORY      ))" "sudo purge (opt-in troubleshooting)"
plan_line "flush DNS cache"                   "$(( 1 - SKIP_DNS         ))" "dscacheutil + mDNSResponder"
plan_line "clear system caches"               "$(( 1 - SKIP_SYSCACHES   ))" "/Library/Caches, /System/Library/Caches"
plan_line "clear user caches"                 "$(( 1 - SKIP_USERCACHES  ))" "~/Library/Caches, Saved State, DerivedData, ..."
plan_line "clear per-app caches"              "$(( 1 - SKIP_APPCACHES   ))" "Chromium, sandboxed containers, VSIX"
plan_line "clear AI tool caches"              "$(( 1 - SKIP_AICACHES    ))" "Claude, Codex, ChatGPT, Cursor, Windsurf"
plan_line "prune workspace storage"           "$(( 1 - SKIP_WORKSPACESTORAGE ))" "VS Code, deleted projects only"
plan_line "empty trash"                       "$(( 1 - SKIP_TRASH       ))" "~/.Trash"
if (( PRUNE_DOCKER_VOLUMES )); then
  docker_plan="images, containers, builder + unused volumes"
else
  docker_plan="images, containers, builder; volumes kept"
fi
plan_line "docker / orbstack prune"           "$(( 1 - SKIP_DOCKER      ))" "$docker_plan"
if [[ -n "$XCODE_ARCHIVE_DAYS" ]]; then
  xcode_plan="DeviceSupport, simulators, Archives older than ${XCODE_ARCHIVE_DAYS}d"
else
  xcode_plan="DeviceSupport, simulators; Archives kept"
fi
plan_line "xcode extras"                      "$(( 1 - SKIP_XCODE       ))" "$xcode_plan"
plan_line "diagnostic / crash reports"        "$(( 1 - SKIP_DIAGNOSTICS ))" "user (+ system if sudo)"
plan_line "homebrew update/upgrade/cleanup"   "$(( 1 - SKIP_BREW        ))" "brew update · upgrade · cleanup -s · autoremove"
if (( CLEANUP_OLD_GEMS )); then
  devcache_plan="npm/yarn/pnpm/pip/go caches + old installed gems"
else
  devcache_plan="npm/yarn/pnpm/pip/go caches; installed gems kept"
fi
plan_line "dev-tool caches"                   "$(( 1 - SKIP_DEVCACHES   ))" "$devcache_plan"
plan_line "helm plugin refresh"               "$(( 1 - SKIP_HELM_PLUGINS))" "helm plugin update <name>"
plan_line "gcloud components update"          "$(( 1 - SKIP_GCLOUD      ))" "non-brew gcloud components"
plan_line "report active versions"            "$(( 1 - SKIP_VERSIONS    ))" "pyenv/goenv/tfenv/tenv/helm/gcloud"
hr

if (( DRY_RUN )); then
  bold "Dry run — no changes will be made."
fi

if (( ASSUME_YES == 0 )) && (( DRY_RUN == 0 )); then
  printf "%sProceed? [y/N]%s " "$C_BOLD" "$C_RESET"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) warn "aborted by user"; exit 0 ;;
  esac
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
        -exec rm -rf {} + 2>>"$LOG_FILE" \
        || warn_step "some writable system cache entries could not be removed"
    else
      printf "  %s(dry-run) would remove writable entries in /System/Library/Caches%s\n" "$C_DIM" "$C_RESET"
    fi
  fi
}

step_usercaches() {
  local targets=(
    "$HOME/Library/Caches"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$HOME/Library/Application Support/Caches"
  )
  for d in "${targets[@]}"; do
    clear_dir "$d"
  done
}

# Electron / Chromium apps (Slack, VS Code, Chrome, Brave, ...)
# keep their disposable caches inside their own Application Support directory,
# not in ~/Library/Caches — so step_usercaches above never touches them. On a
# developer machine this is routinely several GB.
#
# The matched names are Chromium-internal and are recreated on next launch.
# The search is deliberately restricted to known application roots. A broad
# walk of Application Support cannot prove that every directory named "Cache"
# belongs to a Chromium profile.
step_appcaches() {
  local root="$HOME/Library/Application Support"
  if [[ ! -d "$root" ]]; then
    warn "$root not found"
    return 0
  fi

  # Parallel process/path arrays keep the implementation compatible with the
  # Bash 3.2 shipped by macOS, which has no associative arrays.
  local -a app_processes=(
    "Slack" "Code" "Code - Insiders"
    "Notion" "Obsidian" "Signal" "Discord"
    "Google Chrome" "Brave Browser" "Vivaldi" "Microsoft Teams"
  )
  local -a app_dirs=(
    "Slack" "Code" "Code - Insiders"
    "Notion" "obsidian" "Signal" "discord"
    "Google/Chrome" "BraveSoftware/Brave-Browser" "Vivaldi" "Microsoft/Teams"
  )
  local -a running=() scan_roots=() skipped_roots=()
  local i proc app_root
  for (( i=0; i<${#app_processes[@]}; i++ )); do
    proc="${app_processes[$i]}"
    app_root="$root/${app_dirs[$i]}"
    [[ -d "$app_root" ]] || continue
    if pgrep -x "$proc" >/dev/null 2>&1; then
      running+=("$proc")
      if (( FORCE_ACTIVE_APP_CACHES )); then
        scan_roots+=("$app_root")
      else
        skipped_roots+=("$app_root")
      fi
    else
      scan_roots+=("$app_root")
    fi
  done
  if (( ${#running[@]} > 0 )); then
    if (( FORCE_ACTIVE_APP_CACHES )); then
      warn "running now: ${running[*]} — force flag allows their caches to be cleared"
    else
      warn "running now: ${running[*]} — their cache roots will be kept"
    fi
  fi

  # -prune keeps find from descending into a directory it already matched, so
  # nested hits aren't reported (and re-deleted) twice. A temporary file keeps
  # the exit status observable while retaining the NUL-safe path contract.
  local -a hits=()
  local d scan_out
  scan_out="$(mktemp)"
  for app_root in ${scan_roots[@]+"${scan_roots[@]}"}; do
    find "$app_root" -maxdepth 5 -type d \( \
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
           -iname "GrShaderCache"        \
         \) -prune -print0 >>"$scan_out" 2>>"$LOG_SINK" \
      || warn_step "could not scan application caches under $app_root"
  done
  while IFS= read -r -d '' d; do
    hits+=("$d")
  done < "$scan_out"
  rm -f "$scan_out"

  clear_paths "Electron/Chromium caches" dir ${hits[@]+"${hits[@]}"}

  # Sandboxed apps (Teams, Outlook, Mail, Weather, ...) can't see ~/Library,
  # so macOS gives each one a private Caches dir inside its container. Same
  # disposable data as ~/Library/Caches, invisible to step_usercaches.
  # Contents only: the Caches dir itself carries sandbox ACLs worth keeping.
  local containers="$HOME/Library/Containers"
  local -a ccaches=()
  if (( FORCE_ACTIVE_APP_CACHES )); then
    if [[ -d "$containers" ]]; then
      local container_scan
      container_scan="$(mktemp)"
      find "$containers" -maxdepth 4 -type d -path "*/Data/Library/Caches" \
        -print0 >"$container_scan" 2>>"$LOG_SINK" \
        || warn_step "could not scan sandboxed application caches"
      while IFS= read -r -d '' d; do
        ccaches+=("$d")
      done < "$container_scan"
      rm -f "$container_scan"
    fi
    clear_paths "sandboxed app caches" contents ${ccaches[@]+"${ccaches[@]}"}
  else
    info "sandboxed app caches kept; activity cannot be mapped reliably (use --force-active-app-caches)"
  fi

  # VS Code keeps the downloaded .vsix archive for every extension
  # after installing it. Purely a download cache; the installed extension lives
  # in ~/.vscode/extensions (or the editor's equivalent) and is untouched.
  local ed vsix_dir skipped
  local -a vsix=()
  for ed in "${VSCODE_FAMILY[@]}"; do
    vsix_dir="$root/$ed/CachedExtensionVSIXs"
    [[ -d "$vsix_dir" ]] || continue
    skipped=0
    for app_root in ${skipped_roots[@]+"${skipped_roots[@]}"}; do
      case "$vsix_dir/" in "$app_root/"*) skipped=1; break ;; esac
    done
    (( skipped )) || vsix+=("$vsix_dir")
  done
  clear_paths "extension VSIX cache" contents ${vsix[@]+"${vsix[@]}"}

}

# AI tools keep large disposable browser caches beside persistent application
# state. Restrict this step to exact cache directory names and known bundle
# cache roots: broad deletion under these products would remove conversations,
# project sessions, credentials, extensions, runtimes, or downloaded models.
ai_process_running() {
  local process rc process_check_failed=0
  for process in "$@"; do
    pgrep -x "$process" >/dev/null 2>&1
    rc=$?
    (( rc == 0 )) && return 0
    (( rc == 1 )) || process_check_failed=1
  done
  (( process_check_failed == 0 )) || return 2
  return 1
}

clear_ai_support_caches() {
  local label="$1" root="$2"; shift 2
  [[ -d "$root" ]] || return 0
  AI_CACHE_FOUND=1

  ai_process_running "$@"
  case $? in
    0)
      warn "$label is running - keeping its caches"
      return 0
      ;;
    2)
      warn_step "cannot determine whether $label is running - keeping its caches"
      return 0
      ;;
  esac

  local scan_out d
  local -a hits=()
  if (( DRY_RUN )); then
    # Process substitution keeps preview discovery read-only. The real path
    # below uses a temporary file so it can retain find's exit status.
    while IFS= read -r -d '' d; do hits+=("$d"); done < <(
      find "$root" -maxdepth 4 -type d \( \
        -name "Cache"              -o \
        -name "Code Cache"         -o \
        -name "GPUCache"           -o \
        -name "DawnGraphiteCache"  -o \
        -name "DawnWebGPUCache"    -o \
        -name "GraphiteDawnCache"  -o \
        -name "blob_storage" \
      \) -prune -print0 2>>"$LOG_SINK"
    )
  else
    scan_out="$(mktemp)"
    if ! find "$root" -maxdepth 4 -type d \( \
         -name "Cache"              -o \
         -name "Code Cache"         -o \
         -name "GPUCache"           -o \
         -name "DawnGraphiteCache"  -o \
         -name "DawnWebGPUCache"    -o \
         -name "GraphiteDawnCache"  -o \
         -name "blob_storage" \
       \) -prune -print0 >"$scan_out" 2>>"$LOG_SINK"; then
      warn_step "could not scan $label application caches"
    fi
    while IFS= read -r -d '' d; do hits+=("$d"); done < "$scan_out"
    rm -f "$scan_out"
  fi
  clear_paths "$label application caches" dir ${hits[@]+"${hits[@]}"}
}

clear_ai_cache_roots() {
  local label="$1" process_list="$2"; shift 2
  local -a processes=()
  local process root roots_found=0
  while IFS= read -r process; do
    [[ -n "$process" ]] && processes+=("$process")
  done <<< "$process_list"

  for root in "$@"; do
    if [[ -d "$root" ]]; then
      AI_CACHE_FOUND=1
      roots_found=1
    fi
  done
  (( roots_found )) || return 0

  ai_process_running "${processes[@]}"
  case $? in
    0)
      warn "$label is running - keeping its caches"
      return 0
      ;;
    2)
      warn_step "cannot determine whether $label is running - keeping its caches"
      return 0
      ;;
  esac
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    clear_dir "$root"
  done
}

step_aicaches() {
  AI_CACHE_FOUND=0

  clear_ai_support_caches "Claude" \
    "$HOME/Library/Application Support/Claude" Claude claude
  clear_ai_support_caches "Codex" \
    "$HOME/Library/Application Support/Codex" ChatGPT Codex codex
  clear_ai_support_caches "ChatGPT" \
    "$HOME/Library/Application Support/com.openai.chat" ChatGPT
  clear_ai_support_caches "Cursor" \
    "$HOME/Library/Application Support/Cursor" Cursor
  clear_ai_support_caches "Windsurf" \
    "$HOME/Library/Application Support/Windsurf" Windsurf

  clear_ai_cache_roots "Claude" $'Claude\nclaude' \
    "$HOME/Library/Caches/com.anthropic.claudefordesktop" \
    "$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt" \
    "$HOME/.claude/cache"
  clear_ai_cache_roots "Codex" $'ChatGPT\nCodex\ncodex' \
    "$HOME/Library/Caches/Codex" \
    "$HOME/Library/Caches/com.openai.codex" \
    "$HOME/Library/Caches/com.openai.sky.CUAService" \
    "$HOME/.codex/tmp"
  clear_ai_cache_roots "ChatGPT" "ChatGPT" \
    "$HOME/Library/Caches/com.openai.chat"
  clear_ai_cache_roots "Cursor" "Cursor" \
    "$HOME/Library/Caches/com.todesktop.230313mzl4w4u92"
  clear_ai_cache_roots "Windsurf" "Windsurf" \
    "$HOME/Library/Caches/com.exafunction.windsurf"

  if (( AI_CACHE_FOUND == 0 )); then
    info "no supported AI tool caches found"
  else
    info "AI credentials, settings, sessions, projects, extensions, runtimes, and models kept"
  fi
}

# VS Code creates workspaceStorage/<hash>/ for every folder ever opened and
# never removes it - state DBs, extension scratch data, and language-server
# indexes. Entries outlive the projects they belong to indefinitely.
# Classification lives in lib/workspace_scan.py rather than here. Deciding which
# entries are dead means parsing JSON, percent-decoding a URI, and asking whether
# a path's volume is even attached — none of which shell does well, and the cost
# of getting it wrong is somebody's project state. The scanner is unit-tested
# against fixtures covering each of those cases; see test-env/python/tests.
#
# An entry is dropped only when its recorded path is provably gone. Remote or
# virtual URIs, missing or unparsable workspace.json, and paths on a volume that
# is not currently mounted are all kept, so errors cost disk, never data.
step_workspacestorage() {
  local root="$HOME/Library/Application Support"
  local ed ws status dir reason
  local live=0 unresolved=0
  local -a roots=() stale=()

  for ed in "${VSCODE_FAMILY[@]}"; do
    ws="$root/$ed/User/workspaceStorage"
    [[ -d "$ws" ]] && roots+=("$ws")
  done
  if (( ${#roots[@]} == 0 )); then
    info "no editor workspace storage found"
    return 0
  fi

  # Absolute path, not `python3`: on a developer machine a bare python3 resolves
  # to whichever pyenv shim or activated virtualenv happens to be first on PATH,
  # and this has to be the interpreter that is always present.
  local py=/usr/bin/python3
  local scanner="$SCRIPT_DIR/lib/workspace_scan.py"
  if [[ ! -x "$py" || ! -f "$scanner" ]]; then
    warn_step "workspace scanner unavailable — keeping all entries"
    return 0
  fi

  # Run to a file rather than straight into the loop: with process substitution
  # the scanner's exit status is unreachable, and "the scanner crashed" and
  # "this machine has no workspaces yet" both look like zero records. The first
  # deserves a warning, the second is a perfectly ordinary [ ok ].
  local scan_out
  scan_out="$(mktemp)"
  if ! "$py" "$scanner" "${roots[@]}" >"$scan_out" 2>>"$LOG_SINK"; then
    rm -f "$scan_out"
    warn_step "workspace scanner failed — keeping all entries (see log)"
    return 0
  fi

  # Every field is NUL-delimited because macOS paths may contain tabs and
  # newlines. NUL is the only byte a pathname cannot contain.
  while IFS= read -r -d '' status \
    && IFS= read -r -d '' dir \
    && IFS= read -r -d '' reason \
    && IFS= read -r -d '' _; do   # 4th field consumed to keep records aligned
    case "$status" in
      live)  live=$(( live + 1 )) ;;
      stale) stale+=("$dir") ;;
      *)
        unresolved=$(( unresolved + 1 ))
        (( VERBOSE )) && printf "      %skept: %s%s\n" "$C_DIM" "$reason" "$C_RESET"
        ;;
    esac
  done < "$scan_out"
  rm -f "$scan_out"

  if (( live + unresolved + ${#stale[@]} == 0 )); then
    info "no editor workspace storage entries"
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
  local delete_rc=0 remaining="" verify_rc=0
  find "$trash" -mindepth 1 -delete 2>>"$LOG_FILE" || delete_rc=$?
  remaining="$(find "$trash" -mindepth 1 -print -quit 2>>"$LOG_FILE")" || verify_rc=$?
  after_b="$(path_bytes "$trash")"
  delta=$(( before_b - after_b ))
  (( delta > 0 )) && STEP_FREED_B=$(( STEP_FREED_B + delta ))
  printf "  %s->%s freed %s from ~/.Trash\n" "$C_GREEN" "$C_RESET" "$(human_bytes "$delta")"
  if (( delete_rc != 0 || verify_rc != 0 )) || [[ -n "$remaining" ]]; then
    warn_step "Trash cleanup incomplete — protected or recreated entries remain"
  fi
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
      warn_step "node is not runnable; skipping npm cache clean (try: brew reinstall node)"
    fi
  fi

  if command -v yarn >/dev/null 2>&1; then
    any=1
    local d="$HOME/Library/Caches/Yarn"
    printf "  yarn cache %s(%s)%s\n" "$C_DIM" "$(human_bytes "$(path_bytes "$d")")" "$C_RESET"
    if (( node_ok )); then
      run_cmd "yarn cache clean" yarn cache clean || warn "'yarn cache clean' failed"
    else
      warn_step "node is not runnable; skipping yarn cache clean (try: brew reinstall node)"
    fi
  fi

  if command -v pnpm >/dev/null 2>&1; then
    any=1
    if (( node_ok )); then
      run_cmd "pnpm store prune" pnpm store prune || warn "'pnpm store prune' failed"
    else
      warn_step "node is not runnable; skipping pnpm store prune (try: brew reinstall node)"
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
    if (( CLEANUP_OLD_GEMS )); then
      # `gem cleanup` uninstalls old versions from GEM_HOME; it is package
      # maintenance, not cache cleanup, so it must never happen implicitly.
      run_cmd "gem cleanup" gem cleanup || warn "'gem cleanup' failed"
    else
      info "old installed gem versions kept; pass --cleanup-old-gems to remove them"
    fi
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
  if ! ctx="$(docker context show 2>>"$LOG_SINK")" || [[ -z "$ctx" ]]; then
    warn_step "cannot resolve the active Docker context — skipping prune"
    return 0
  fi
  if ! host="$(docker context inspect "$ctx" --format '{{ (index .Endpoints "docker").Host }}' 2>>"$LOG_SINK")" \
     || [[ -z "$host" ]]; then
    warn_step "cannot resolve the Docker endpoint for context '$ctx' — skipping prune"
    return 0
  fi
  if [[ "$host" != unix://* ]]; then
    warn_step "docker context '${ctx:-?}' points to non-local host (${host}) — skipping prune"
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
  # Volumes are data, not cache: a stopped project's database volume counts
  # as "unused" the moment its container is removed, and the LaunchAgent runs
  # this script with --yes, so a default volume prune would delete it
  # unattended. Everything else pruned here is reproducible; volumes are the
  # one thing that is not, so they sit behind their own flag.
  if (( PRUNE_DOCKER_VOLUMES )); then
    run_cmd "docker volume prune -f" docker volume prune -f \
      || warn "'docker volume prune' failed"
  else
    info "volumes kept (data, not cache) — pass --prune-docker-volumes to remove unused ones"
  fi
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

  local archives="$HOME/Library/Developer/Xcode/Archives"
  if [[ -n "$XCODE_ARCHIVE_DAYS" ]] && [[ -d "$archives" ]]; then
    any=1
    local archive_scan
    local -a old_archives=()
    archive_scan="$(mktemp)"
    if find "$archives" -mindepth 1 -maxdepth 3 -type d -name '*.xcarchive' \
         -mtime "+$XCODE_ARCHIVE_DAYS" -prune -print0 >"$archive_scan" 2>>"$LOG_SINK"; then
      while IFS= read -r -d '' d; do old_archives+=("$d"); done < "$archive_scan"
    else
      warn_step "could not scan Xcode Archives"
    fi
    rm -f "$archive_scan"
    clear_paths "Xcode Archives older than ${XCODE_ARCHIVE_DAYS}d" dir \
      ${old_archives[@]+"${old_archives[@]}"}
  elif [[ -d "$archives" ]]; then
    any=1
    info "Xcode Archives kept; use --prune-xcode-archives-days N for age-based pruning"
  fi

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

  local -a brew_yes=()
  (( ASSUME_YES )) && brew_yes+=(--yes)

  run_cmd     "brew update"         brew update    || warn "'brew update' had issues"
  # Keep formulae and casks separate: generic `brew upgrade` considers both,
  # which made the following cask command a duplicate pass.
  # Plain warn, not warn_step: run_cmd has already counted this failure.
  # Adding warn_step here would report one failed upgrade as two warnings, and
  # the CLT hint below as a third.
  if ! run_cmd "brew upgrade --formula" brew upgrade --formula \
       ${brew_yes[@]+"${brew_yes[@]}"}; then
    warn "'brew upgrade --formula' had issues"
    if grep -q "Command Line Tools are too outdated" "$LOG_FILE" 2>/dev/null; then
      warn "Homebrew reports Xcode Command Line Tools are outdated. Update via System Settings → Software Update, or: sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install"
    fi
  fi

  # A cask postinstall can invoke sudo even though Homebrew itself is running as
  # the user. Never attempt that from --no-sudo or without a controlling TTY.
  if (( USE_SUDO == 0 )) || { (( DRY_RUN == 0 )) && ! have_tty; }; then
    info "skipping cask upgrades: they may require an interactive sudo prompt"
  elif (( BREW_GREEDY )); then
    run_cmd_tty "brew upgrade --cask --greedy" brew upgrade --cask --greedy \
      ${brew_yes[@]+"${brew_yes[@]}"} || warn "'brew upgrade --cask --greedy' had issues"
  else
    run_cmd_tty "brew upgrade --cask" brew upgrade --cask \
      ${brew_yes[@]+"${brew_yes[@]}"} || warn "'brew upgrade --cask' had issues"
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
  if (( DRY_RUN )); then
    # Even ostensibly read-only gcloud commands initialise config databases and
    # logs under ~/.config/gcloud. A dry run may not invoke them at all.
    printf "  [dry] gcloud components update --quiet\n"
    printf "  [dry] gcloud components update-macos-python --quiet (if supported)\n"
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
  if command -v gcloud >/dev/null 2>&1 && (( DRY_RUN == 0 )); then
    any=1
    line="$(gcloud version 2>/dev/null | head -n1 || echo '?')"
    printf "  gcloud:        %s%s%s\n" "$C_DIM" "$line" "$C_RESET"
  elif command -v gcloud >/dev/null 2>&1; then
    any=1
    printf "  gcloud:        %snot probed in dry-run (gcloud writes config/log state)%s\n" \
      "$C_DIM" "$C_RESET"
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
  local label="$1" skip_flag="$2" fn="$3" step_id="${4:-}" why=""
  if (( skip_flag )); then
    [[ -n "$step_id" ]] && why="$(auto_skip_reason "$step_id")"
    step "$label"
    if [[ -n "$why" ]]; then
      printf "  %sskipped — %s%s\n" "$C_DIM" "$why" "$C_RESET"
      STEPS_SKIP+=("$label ($why)")
    else
      printf "  %sskipped%s\n" "$C_DIM" "$C_RESET"
      STEPS_SKIP+=("$label")
    fi
    return 0
  fi
  do_step "$label" "$fn"
}

run_or_skip "Purge inactive memory"                "$SKIP_MEMORY"      step_memory memory
run_or_skip "Flush DNS cache"                      "$SKIP_DNS"         step_dns dns
run_or_skip "Clear system caches"                  "$SKIP_SYSCACHES"   step_syscaches system-caches
run_or_skip "Clear user caches"                    "$SKIP_USERCACHES"  step_usercaches user-caches
run_or_skip "Clear per-app caches"                 "$SKIP_APPCACHES"   step_appcaches app-caches
run_or_skip "Clear AI tool caches"                 "$SKIP_AICACHES"    step_aicaches ai-caches
run_or_skip "Prune stale workspace storage"        "$SKIP_WORKSPACESTORAGE" step_workspacestorage workspace-storage
run_or_skip "Empty trash"                          "$SKIP_TRASH"       step_trash trash
run_or_skip "Docker / OrbStack prune"              "$SKIP_DOCKER"      step_docker docker
run_or_skip "Xcode extras"                         "$SKIP_XCODE"       step_xcode xcode
run_or_skip "Diagnostic / crash reports"           "$SKIP_DIAGNOSTICS" step_diagnostics diagnostics
run_or_skip "Homebrew update / upgrade / cleanup"  "$SKIP_BREW"         step_brew brew
run_or_skip "Dev-tool caches"                      "$SKIP_DEVCACHES"   step_devcaches dev-caches
run_or_skip "Helm plugin refresh"                  "$SKIP_HELM_PLUGINS" step_helm_plugins helm-plugins
run_or_skip "gcloud components update"             "$SKIP_GCLOUD"       step_gcloud gcloud
run_or_skip "Active tool versions"                 "$SKIP_VERSIONS"     step_versions versions

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
  local item
  for item in "$@"; do printf "  - %s\n" "$item"; done
}

(( ${#STEPS_OK[@]}   > 0 )) && print_group "OK"      "$C_GREEN"  "${STEPS_OK[@]}"
(( ${#STEPS_WARN[@]} > 0 )) && print_group "Warned"  "$C_YELLOW" "${STEPS_WARN[@]}"
(( ${#STEPS_SKIP[@]} > 0 )) && print_group "Skipped" "$C_DIM"    "${STEPS_SKIP[@]}"
(( ${#STEPS_FAIL[@]} > 0 )) && print_group "Failed"  "$C_RED"    "${STEPS_FAIL[@]}"

echo
if (( DRY_RUN )); then
  : # No log exists to retain or discard.
elif (( ${#STEPS_FAIL[@]} > 0 || ${#STEPS_WARN[@]} > 0 )); then
  PERSISTENT_LOG_DIR="$HOME/Library/Logs/stay_fresh"
  mkdir -p "$PERSISTENT_LOG_DIR"
  SAVED_LOG="$PERSISTENT_LOG_DIR/$(basename "$LOG_FILE")"
  if cp "$LOG_FILE" "$SAVED_LOG" 2>/dev/null; then
    rm -f "$LOG_FILE"
  else
    SAVED_LOG="$LOG_FILE"
  fi
  # keep only the 10 most recent logs
  old_log_list="$(mktemp)"
  find "$PERSISTENT_LOG_DIR" -name 'stay_fresh-*.log' -type f 2>/dev/null \
    | sort -r | tail -n +11 > "$old_log_list"
  while IFS= read -r old_log; do
    [[ -n "$old_log" ]] || continue
    rm -f "$old_log" 2>/dev/null || warn "could not remove old log: $old_log"
  done < "$old_log_list"
  rm -f "$old_log_list"
  warn "log saved: $SAVED_LOG"
  printf "  %sTo inspect:%s tail -80 '%s'\n" "$C_DIM" "$C_RESET" "$SAVED_LOG"
else
  rm -f "$LOG_FILE"
  info "run clean — log discarded"
fi

if (( ${#STEPS_FAIL[@]} > 0 )); then
  exit 1
fi

if (( FAIL_ON_WARN )) && (( ${#STEPS_WARN[@]} > 0 )); then
  err "warnings are fatal because --fail-on-warn was requested"
  exit 1
fi

ok "You're fresh. Consider a reboot if things still feel sluggish."

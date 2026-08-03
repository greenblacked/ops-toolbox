#!/usr/bin/env bash
# workstation_doctor.sh
# Read-only post-bootstrap health report: security posture, disk, CLT, Homebrew,
# SSH/git, Time Machine, log footprint, LaunchAgents, and optional login items.
#
# Usage:
#   ./workstation_doctor.sh [--verbose] [--skip-brew-doctor] [--skip-login-items]
#                           [--skip-time-machine] [--skip-log-sizes]
#                           [--skip-launchd] [--help]
#
# Exit codes:
#   0   completed (warnings do not change the exit code)
#   2   preflight failed (not macOS, running as root)
#   3   bad CLI arguments

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
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

bold() { printf "%s%s%s\n" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf "%s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" 1>&2; }
step() { printf "\n%s==>%s %s%s%s\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
hr()   { printf "%s%s%s\n" "$C_DIM" "--------------------------------------------------------------" "$C_RESET"; }

VERBOSE=0
SKIP_BREW_DOCTOR=0
SKIP_LOGIN_ITEMS=0
SKIP_TIME_MACHINE=0
SKIP_LOG_SIZES=0
SKIP_LAUNCHD=0

LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/workstation_doctor-$(date +%Y%m%d-%H%M%S).log"

usage() {
  cat <<EOF
${C_BOLD}workstation_doctor.sh${C_RESET} — read-only macOS workstation report.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [options]

${C_BOLD}Options:${C_RESET}
  --verbose, -v       Log full command output to $LOG_FILE
  --skip-brew-doctor  Skip 'brew doctor' (can be slow)
  --skip-login-items  Skip AppleScript login-item listing (may prompt for Automation)
  --skip-time-machine Skip Time Machine / tmutil section
  --skip-log-sizes    Skip ~/Library/Logs and diagnostic size estimates
  --skip-launchd      Skip LaunchAgents listing
  -h, --help          Show this help

Log file: $LOG_FILE
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -v|--verbose)        VERBOSE=1 ;;
    --skip-brew-doctor)  SKIP_BREW_DOCTOR=1 ;;
    --skip-login-items)  SKIP_LOGIN_ITEMS=1 ;;
    --skip-time-machine) SKIP_TIME_MACHINE=1 ;;
    --skip-log-sizes)    SKIP_LOG_SIZES=1 ;;
    --skip-launchd)      SKIP_LAUNCHD=1 ;;
    -h|--help)           usage; exit 0 ;;
    *)                   err "unknown option: $1"; echo; usage; exit 3 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
bold "=== workstation_doctor: preflight ==="
mkdir -p "$LOG_DIR"
: >"$LOG_FILE"
echo "workstation_doctor.sh log - $(date)" >>"$LOG_FILE"
info "log file: $C_DIM$LOG_FILE$C_RESET"

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only (detected: $(uname -s))."
  exit 2
fi
if [[ "$(id -u)" == "0" ]]; then
  err "Run as a normal user, not root."
  exit 2
fi

OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo '?')"
ARCH="$(uname -m)"
ok "macOS $OS_VERSION on $ARCH ($(sw_vers -buildVersion 2>/dev/null || echo '?'))"

# ---------------------------------------------------------------------------
step "Security"
fv_line="$(fdesetup status 2>/dev/null | head -n1 || true)"
if grep -qE 'FileVault is On' <<<"$fv_line"; then
  ok "FileVault: on"
elif grep -qE 'FileVault is Off' <<<"$fv_line"; then
  warn "FileVault: off"
else
  info "FileVault: could not parse status (see System Settings) — ${fv_line:-no output}"
fi

if spctl --status 2>/dev/null | grep -q "enabled"; then
  ok "Gatekeeper: assessments enabled"
else
  warn "Gatekeeper: $(spctl --status 2>/dev/null | tr -d '\n' || echo 'unknown')"
fi

if csrutil status 2>/dev/null | grep -q "enabled"; then
  ok "SIP: enabled ($(csrutil status 2>/dev/null | head -n1 | tr -d '\n'))"
elif csrutil status 2>/dev/null | grep -q "disabled"; then
  warn "SIP: disabled"
else
  info "SIP: $(csrutil status 2>/dev/null | head -n1 || echo 'unknown')"
fi

if [[ "$ARCH" == "arm64" ]]; then
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    ok "Rosetta: x86_64 emulation available"
  else
    warn "Rosetta: x86_64 emulation not available (softwareupdate --install-rosetta)"
  fi
else
  info "Rosetta: N/A (Intel Mac)"
fi

# ---------------------------------------------------------------------------
step "Disk"
FREE_B="$(df -k / | awk 'NR==2 {printf "%.0f", $4 * 1024}')"
ok "Free space on /: ~$(awk -v b="$FREE_B" 'BEGIN { if (b>=1073741824) printf "%.1fG", b/1073741824; else if (b>=1048576) printf "%.0fM", b/1048576; else printf "%dK", b/1024 }')"

# ---------------------------------------------------------------------------
step "Xcode Command Line Tools"
if xcode-select -p &>/dev/null; then
  clt_path="$(xcode-select -p 2>/dev/null)"
  ok "CLT path: $clt_path"
  clt_ver="$(pkgutil --pkg-info com.apple.pkg.CLTools_Executables 2>/dev/null | awk -F': ' '/^version:/ {print $2; exit}')"
  [[ -n "$clt_ver" ]] && ok "CLT package version: $clt_ver"
else
  warn "CLT not selected — install with: xcode-select --install"
fi

# ---------------------------------------------------------------------------
step "Homebrew"
if command -v brew &>/dev/null; then
  ok "$(brew --version | head -n1) — prefix $(brew --prefix)"
  if (( SKIP_BREW_DOCTOR )); then
    info "skipping brew doctor (--skip-brew-doctor)"
  else
    info "running brew doctor (set --skip-brew-doctor to omit; --verbose streams here)"
    if (( VERBOSE )); then
      if brew doctor 2>&1 | tee -a "$LOG_FILE"; then
        ok "brew doctor: no problems reported"
      else
        warn "brew doctor reported issues — see log"
      fi
    else
      if brew doctor >>"$LOG_FILE" 2>&1; then
        ok "brew doctor: no problems reported"
      else
        warn "brew doctor: see $LOG_FILE"
      fi
    fi
  fi
else
  warn "Homebrew not on PATH"
fi

# ---------------------------------------------------------------------------
step "SSH keys"
found=0
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
  if [[ -f "$k" ]]; then
    ok "found $k"
    found=1
  fi
done
(( found )) || warn "no common public keys in ~/.ssh (id_ed25519/id_rsa/id_ecdsa)"

if ssh-add -l &>/dev/null; then
  info "ssh-agent keys: $(ssh-add -l 2>/dev/null | wc -l | tr -d ' ') loaded"
else
  info "ssh-add -l: no agent or no keys (non-fatal)"
fi

# ---------------------------------------------------------------------------
step "Git identity"
if command -v git &>/dev/null; then
  gn="$(git config --global user.name 2>/dev/null || true)"
  ge="$(git config --global user.email 2>/dev/null || true)"
  if [[ -n "$gn" && -n "$ge" ]]; then
    ok "git user.name=$gn"
    ok "git user.email=$ge"
  else
    warn "git global user.name or user.email not set"
  fi
else
  info "git not installed"
fi

# ---------------------------------------------------------------------------
if (( SKIP_TIME_MACHINE == 0 )); then
  step "Time Machine"
  if command -v tmutil &>/dev/null; then
    {
      echo "# $(date '+%H:%M:%S') tmutil status"
      tmutil status 2>&1
    } | head -n20 | tee -a "$LOG_FILE" || true
    if lb="$(tmutil latestbackup 2>/dev/null)"; then
      [[ -n "$lb" ]] && ok "latest backup: $lb"
    else
      info "latestbackup: none or not configured"
    fi
    snap_n="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple' || true)"
    info "local APFS snapshots (lines matching com.apple): ${snap_n:-0}"
  else
    info "tmutil not available"
  fi
fi

# ---------------------------------------------------------------------------
if (( SKIP_LOG_SIZES == 0 )); then
  step "Logs and diagnostics (sizes)"
  for p in \
    "$HOME/Library/Logs" \
    "$HOME/Library/Logs/DiagnosticReports" \
    "/Library/Logs"; do
    if [[ -d "$p" ]]; then
      sz="$(du -sh "$p" 2>/dev/null | awk '{print $1}')"
      ok "$p — $sz"
    fi
  done
fi

# ---------------------------------------------------------------------------
if (( SKIP_LAUNCHD == 0 )); then
  step "LaunchAgents (user)"
  la_dir="$HOME/Library/LaunchAgents"
  if [[ -d "$la_dir" ]]; then
    cnt="$(find "$la_dir" -maxdepth 1 -name '*.plist' 2>/dev/null | wc -l | tr -d ' ')"
    ok "$cnt plist(s) in $la_dir"
    find "$la_dir" -maxdepth 1 -name '*.plist' 2>/dev/null | sort | while read -r f; do
      [[ -n "$f" ]] && info "  $(basename "$f")"
    done
  else
    info "no $la_dir"
  fi
fi

# ---------------------------------------------------------------------------
if (( SKIP_LOGIN_ITEMS == 0 )); then
  step "Login items (GUI)"
  if items="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)"; then
    [[ -n "$items" ]] && ok "login items: $items" || info "no login items reported"
  else
    warn "could not read login items (grant Terminal/iTerm Automation for System Events, or use --skip-login-items)"
  fi
fi

hr
bold "=== workstation_doctor: done ==="
info "full log: $LOG_FILE"
exit 0

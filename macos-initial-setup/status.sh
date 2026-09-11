#!/usr/bin/env bash
# status.sh
# One-screen verdict for a macOS workstation: is this machine well enough
# to work on, and what should I run next?
#
# Read-only. No log file. No sudo. Standalone — copy it into ~/bin.
#
# Usage:
#   ./status.sh
#   ./status.sh --only disk,brew
#   ./status.sh --list-sections
#   ./status.sh --help
#
# Exit codes:
#   0   every selected section is ok
#   1   at least one section warned or failed
#   2   not macOS
#   3   bad CLI arguments
#   4   --only selected nothing

set -u
set -o pipefail

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

ok()   { printf "%s[ ok ]%s %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n"  "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n"  "$C_RED"    "$C_RESET" "$*" >&2; }
info() { printf "%s[info]%s %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }

ONLY=""
LIST_SECTIONS=0
WARNED=0

# id|label
SECTIONS=(
  "os|macOS version and architecture"
  "disk|free space on /"
  "brew|Homebrew presence and pending upgrades"
  "git|effective user.name and user.email"
  "agent|stay_fresh LaunchAgent loaded?"
  "security|FileVault and SIP, best-effort"
)

section_ids() {
  local row
  for row in "${SECTIONS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

usage() {
  cat <<EOF
${C_BOLD}status.sh${C_RESET} — one-screen verdict for this Mac.

Read-only. Writes nothing. The long reports are still
workstation_doctor.sh (well) and hardening_audit.sh (safe).

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [--only SECTION[,SECTION...]] [--list-sections] [--help]

${C_BOLD}Options:${C_RESET}
  --only LIST         Only the named sections (see --list-sections)
  --list-sections     Print stable section ids and exit
  -h, --help          Show this help

${C_BOLD}Sections:${C_RESET}
EOF
  local row id label
  for row in "${SECTIONS[@]}"; do
    id="${row%%|*}"
    label="${row#*|}"
    printf "  %-10s %s\n" "$id" "$label"
  done
  cat <<EOF

${C_BOLD}Exit codes:${C_RESET}
  0  every selected section is ok
  1  at least one section warned
  2  not macOS
  3  invalid arguments
  4  --only selected nothing
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    err "$option requires a value"
    exit 3
  fi
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    --list-sections)    LIST_SECTIONS=1 ;;
    --only)             require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)           ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    *)                  err "unknown option: $1"; usage >&2; exit 3 ;;
  esac
  shift
done

if (( LIST_SECTIONS )); then
  section_ids
  exit 0
fi

SELECTED=()
if [[ -n "$ONLY" ]]; then
  known=""
  while IFS= read -r id; do
    known="$known $id "
  done < <(section_ids)
  IFS=',' read -r -a items <<< "$ONLY"
  for raw in "${items[@]}"; do
    id="$(printf '%s' "$raw" | tr -d '[:space:]')"
    [[ -n "$id" ]] || continue
    case "$known" in
      *" $id "*) SELECTED+=("$id") ;;
      *) err "unknown section in --only: $id (see --list-sections)"; exit 3 ;;
    esac
  done
  if (( ${#SELECTED[@]} == 0 )); then
    err "--only selected nothing"
    exit 4
  fi
else
  while IFS= read -r id; do
    SELECTED+=("$id")
  done < <(section_ids)
fi

want() {
  local needle="$1" s
  for s in "${SELECTED[@]}"; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

note_warn() { WARNED=1; warn "$1"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only (detected: $(uname -s))."
  exit 2
fi

printf "%s=== status ===%s\n" "$C_BOLD" "$C_RESET"

if want os; then
  ver="$(sw_vers -productVersion 2>/dev/null || echo '?')"
  build="$(sw_vers -buildVersion 2>/dev/null || echo '?')"
  arch="$(uname -m)"
  ok "os        macOS $ver ($build) on $arch"
fi

if want disk; then
  free_gb="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "${free_gb:-}" ]]; then
    note_warn "disk      could not read free space on /"
  elif (( free_gb < 20 )); then
    note_warn "disk      ${free_gb}G free on / — under 20G"
  else
    ok "disk      ${free_gb}G free on /"
  fi
fi

if want brew; then
  if ! command -v brew >/dev/null 2>&1; then
    note_warn "brew      Homebrew is not on PATH — run ./install_apps.sh"
  else
    outdated="$(brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ')"
    prefix="$(brew --prefix 2>/dev/null || echo '?')"
    if [[ "${outdated:-0}" -gt 0 ]]; then
      note_warn "brew      $outdated pending upgrade(s)  ($prefix)"
    else
      ok "brew      up to date  ($prefix)"
    fi
  fi
fi

if want git; then
  if ! command -v git >/dev/null 2>&1; then
    note_warn "git       git is not on PATH"
  else
    name="$(git config --global --get user.name 2>/dev/null || true)"
    email="$(git config --global --get user.email 2>/dev/null || true)"
    if [[ -z "$name" || -z "$email" ]]; then
      note_warn "git       global user.name / user.email is incomplete"
    else
      ok "git       $name <$email>"
    fi
  fi
fi

if want agent; then
  uid="$(id -u 2>/dev/null || echo "")"
  label="com.ops-toolbox.stay-fresh"
  loaded=0
  if command -v launchctl >/dev/null 2>&1 && [[ -n "$uid" ]]; then
    if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
      loaded=1
    fi
  fi
  plist="${HOME:-}/Library/LaunchAgents/${label}.plist"
  if (( loaded )); then
    ok "agent     LaunchAgent $label is loaded"
  elif [[ -n "${HOME:-}" && -f "$plist" ]]; then
    note_warn "agent     $plist exists but is not loaded"
  else
    info "agent     no stay_fresh LaunchAgent — launchd/stay_fresh_agent.sh install"
  fi
fi

if want security; then
  fv="$(fdesetup status 2>/dev/null || true)"
  case "$fv" in
    *"FileVault is On"*)  ok "security  FileVault on" ;;
    *"FileVault is Off"*) note_warn "security  FileVault off" ;;
    *)                    info "security  FileVault status unknown" ;;
  esac
  sip="$(csrutil status 2>/dev/null || true)"
  case "$sip" in
    *"enabled"*)  ok "security  SIP enabled" ;;
    *"disabled"*) note_warn "security  SIP disabled" ;;
    *)            info "security  SIP status unknown" ;;
  esac
fi

printf "%s=== next ===%s\n" "$C_BOLD" "$C_RESET"
if (( WARNED == 0 )); then
  info "machine looks well. Recurring work: ./stay_fresh.sh --dry-run"
  exit 0
fi
info "well:  ./workstation_doctor.sh"
info "safe:  ./hardening_audit.sh"
info "fresh: ./stay_fresh.sh --dry-run"
exit 1

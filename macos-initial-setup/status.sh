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
#   ./status.sh --json
#   ./status.sh --help
#
# --json prints the same verdicts as one JSON object on stdout and nothing
# else: no colour, no headings, no "next" hint. The exit code is part of that
# contract, so a consumer reads $? as well as the document. The schema is
# versioned ("schema": 1):
#
#   {"schema":1,"script":"status.sh","host":"...","generated":"...Z",
#    "ok":true|false,"sections":[{"id":"disk","verdict":"ok|warn|info",
#    "message":"..."}]}
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
JSON=0
JSON_SECTIONS=""

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
  $(basename "$0") [--only SECTION[,SECTION...]] [--json] [--list-sections] [--help]

${C_BOLD}Options:${C_RESET}
  --only LIST         Only the named sections (see --list-sections)
  --json              Print one JSON object instead of the report; the exit
                      code is unchanged
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
    --json)             JSON=1 ;;
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

# The document is for a parser, whatever stdout is attached to.
if (( JSON )); then
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
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

# A JSON string. Backslash and double quote are escaped, newline, tab and CR
# become spaces, and every other control character (ESC included) is dropped,
# so whatever a probe printed, the document stays valid. sed and tr only:
# jq and python are not on a stock Mac.
json_str() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\n\t\r' '   ' | tr -d '\000-\037\177' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# report LEVEL ID MESSAGE: one section verdict. The human line is exactly the
# one each section printed before --json existed; in JSON mode it becomes a
# record instead.
report() {
  local level="$1" id="$2" msg="$3"
  [[ "$level" == "warn" ]] && WARNED=1
  if (( JSON )); then
    JSON_SECTIONS="$JSON_SECTIONS${JSON_SECTIONS:+,}{\"id\":$(json_str "$id"),\"verdict\":\"$level\",\"message\":$(json_str "$msg")}"
    return 0
  fi
  case "$level" in
    ok)   ok "$(printf '%-9s %s' "$id" "$msg")" ;;
    warn) warn "$(printf '%-9s %s' "$id" "$msg")" ;;
    *)    info "$(printf '%-9s %s' "$id" "$msg")" ;;
  esac
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only (detected: $(uname -s))."
  exit 2
fi

(( JSON )) || printf "%s=== status ===%s\n" "$C_BOLD" "$C_RESET"

if want os; then
  ver="$(sw_vers -productVersion 2>/dev/null || echo '?')"
  build="$(sw_vers -buildVersion 2>/dev/null || echo '?')"
  arch="$(uname -m)"
  report ok os "macOS $ver ($build) on $arch"
fi

if want disk; then
  free_gb="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "${free_gb:-}" ]]; then
    report warn disk "could not read free space on /"
  elif (( free_gb < 20 )); then
    report warn disk "${free_gb}G free on / — under 20G"
  else
    report ok disk "${free_gb}G free on /"
  fi
fi

if want brew; then
  if ! command -v brew >/dev/null 2>&1; then
    report warn brew "Homebrew is not on PATH — run ./install_apps.sh"
  else
    outdated="$(HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ')"
    prefix="$(brew --prefix 2>/dev/null || echo '?')"
    if [[ "${outdated:-0}" -gt 0 ]]; then
      report warn brew "$outdated pending upgrade(s)  ($prefix)"
    else
      report ok brew "up to date  ($prefix)"
    fi
  fi
fi

if want git; then
  if ! command -v git >/dev/null 2>&1; then
    report warn git "git is not on PATH"
  else
    name="$(git config --global --get user.name 2>/dev/null || true)"
    email="$(git config --global --get user.email 2>/dev/null || true)"
    if [[ -z "$name" || -z "$email" ]]; then
      report warn git "global user.name / user.email is incomplete"
    else
      report ok git "$name <$email>"
    fi
  fi
fi

if want agent; then
  uid="$(id -u 2>/dev/null || echo "")"
  label="com.pretty-useful.stay-fresh"
  loaded=0
  if command -v launchctl >/dev/null 2>&1 && [[ -n "$uid" ]]; then
    if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
      loaded=1
    fi
  fi
  plist="${HOME:-}/Library/LaunchAgents/${label}.plist"
  if (( loaded )); then
    report ok agent "LaunchAgent $label is loaded"
  elif [[ -n "${HOME:-}" && -f "$plist" ]]; then
    report warn agent "$plist exists but is not loaded"
  else
    report info agent "no stay_fresh LaunchAgent — launchd/stay_fresh_agent.sh install"
  fi
fi

if want security; then
  fv="$(fdesetup status 2>/dev/null || true)"
  case "$fv" in
    *"FileVault is On"*)  report ok security "FileVault on" ;;
    *"FileVault is Off"*) report warn security "FileVault off" ;;
    *)                    report info security "FileVault status unknown" ;;
  esac
  sip="$(csrutil status 2>/dev/null || true)"
  # Anchored on "status: ", not a bare "enabled". csrutil answers
  # "status: unknown (Custom Configuration)" on a machine with individual
  # protections turned off, and then lists them - "Kext Signing: enabled"
  # among them. An unanchored match found that word and called the machine
  # green while its filesystem protections were off. stay_fresh.sh's
  # sip_status() and hardening_audit.sh were both anchored for this reason;
  # this copy and workstation_doctor.sh were the two that were not.
  case "$sip" in
    *"status: enabled"*|*"status: Enabled"*)   report ok security "SIP enabled" ;;
    *"status: disabled"*|*"status: Disabled"*) report warn security "SIP disabled" ;;
    *"Custom Configuration"*)                  report warn security "SIP partially disabled (custom configuration)" ;;
    *)                                         report info security "SIP status unknown" ;;
  esac
fi

if (( JSON )); then
  json_ok=true
  (( WARNED )) && json_ok=false
  printf '{"schema":1,"script":"status.sh","host":%s,"generated":%s,"ok":%s,"sections":[%s]}\n' \
    "$(json_str "$(uname -n 2>/dev/null)")" "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    "$json_ok" "$JSON_SECTIONS"
  (( WARNED )) && exit 1
  exit 0
fi

if (( WARNED == 0 )); then
  info "next      ./stay_fresh.sh --dry-run"
  exit 0
fi
info "next      ./workstation_doctor.sh"
exit 1

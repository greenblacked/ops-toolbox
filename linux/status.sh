#!/usr/bin/env bash
# status.sh
# One-screen verdict for a Linux workstation or server: is this machine
# well enough to work on, and what should I run next?
#
# Read-only. No log file. No sudo. Standalone — copy it into ~/bin.
#
# Usage:
#   ./status.sh
#   ./status.sh --only disk,git
#   ./status.sh --list-sections
#   ./status.sh --help
#
# Exit codes:
#   0   every selected section is ok
#   1   at least one section warned
#   2   not Linux
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
  "os|distro and kernel"
  "disk|free space on /"
  "packages|apt, dnf or pacman on PATH"
  "reboot|pending reboot marker"
  "timer|stay_fresh user timer"
  "git|effective user.name and user.email"
)

section_ids() {
  local row
  for row in "${SECTIONS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

usage() {
  cat <<EOF
${C_BOLD}status.sh${C_RESET} — one-screen verdict for this Linux machine.

Read-only. Writes nothing. The long reports are still
system_doctor.sh (well) and hardening_audit.sh (safe).

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
  2  not Linux
  3  invalid arguments
  4  --only selected nothing
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
known=" "
row=""
for row in "${SECTIONS[@]}"; do
  known="$known ${row%%|*} "
done
if [[ -n "$ONLY" ]]; then
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
  for row in "${SECTIONS[@]}"; do
    SELECTED+=("${row%%|*}")
  done
fi

want() {
  local needle="$1" s
  for s in "${SELECTED[@]}"; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

note_warn() { WARNED=1; warn "$1"; }

if [[ "$(uname -s)" != "Linux" ]]; then
  err "This script is for Linux only (detected: $(uname -s))."
  exit 2
fi

printf "%s=== status ===%s\n" "$C_BOLD" "$C_RESET"

if want os; then
  pretty="Linux"
  os_release="${OS_RELEASE:-/etc/os-release}"
  if [[ -r "$os_release" ]]; then
    pretty="$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,""); print $2; exit}' "$os_release")"
    [[ -n "$pretty" ]] || pretty="Linux"
  fi
  ok "os        $pretty  kernel $(uname -r)  $(uname -m)"
fi

if want disk; then
  # Portable: 1K-blocks, no GNU-only flags. 20G = 20971520 KiB.
  avail="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "${avail:-}" || ! "$avail" =~ ^[0-9]+$ ]]; then
    note_warn "disk      could not read free space on /"
  else
    gb=$((avail / 1024 / 1024))
    if (( gb < 20 )); then
      note_warn "disk      ${gb}G free on / — under 20G"
    else
      ok "disk      ${gb}G free on /"
    fi
  fi
fi

if want packages; then
  mgr=""
  command -v apt-get >/dev/null 2>&1 && mgr="apt"
  command -v dnf >/dev/null 2>&1 && mgr="${mgr:+$mgr, }dnf"
  command -v pacman >/dev/null 2>&1 && mgr="${mgr:+$mgr, }pacman"
  if [[ -z "$mgr" ]]; then
    note_warn "packages  no apt/dnf/pacman on PATH — run ./install_devtools.sh"
  else
    ok "packages  $mgr on PATH"
  fi
fi

if want reboot; then
  if [[ -f /var/run/reboot-required ]]; then
    note_warn "reboot    /var/run/reboot-required is set"
  elif command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r >/dev/null 2>&1; then
      ok "reboot    needs-restarting reports none"
    else
      note_warn "reboot    needs-restarting wants a reboot"
    fi
  else
    info "reboot    no reboot-required marker"
  fi
fi

if want timer; then
  if ! command -v systemctl >/dev/null 2>&1; then
    info "timer     systemctl not on PATH"
  else
    if systemctl --user is-enabled stay-fresh.timer >/dev/null 2>&1 \
       || systemctl --user is-active stay-fresh.timer >/dev/null 2>&1; then
      ok "timer     stay-fresh.timer is enabled or active"
    else
      info "timer     no stay-fresh user timer — systemd/stay_fresh_timer.sh install"
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

if (( WARNED == 0 )); then
  info "next      ./stay_fresh.sh --dry-run"
  exit 0
fi
info "next      ./system_doctor.sh"
exit 1

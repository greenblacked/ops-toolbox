#!/usr/bin/env bash
# hardening_audit.sh
# Read-only security audit of a Mac.
#
# The macOS half of linux/hardening_audit.sh, down to the flags and the exit
# codes. Same posture, too: it reports and never changes anything. There is no
# --apply and no --fix, because every finding below has a context where the
# "insecure" answer is the correct one — SIP disabled on a kernel-extension
# development machine, Remote Login on for a box you actually ssh into. A
# script that auto-hardened would be wrong often enough to be dangerous, so
# this one hands you the finding and the command, and you decide.
#
# It is the security half of a pair with workstation_doctor.sh, which reports
# the same machine's health. Where they overlap — FileVault, SIP, Gatekeeper —
# the doctor states what it found and this grades it.
#
# Checks are grouped; use --only to run a subset and --list-groups to see them.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

ONLY=""
FAIL_ON="fail"
QUIET=0

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# A finding is one line: verdict, what was checked, and — when it is not a
# pass — what to do about it. The fix is printed rather than run.
pass() { PASS_COUNT=$((PASS_COUNT + 1)); (( QUIET )) || printf "  %s[pass]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }

usage() {
  cat <<EOF
hardening_audit.sh - read-only security audit of a Mac

Reports findings and the command that would fix each one. Changes nothing.

Usage:
  $(basename "$0") [--only GROUPS] [--fail-on warn|fail] [--quiet]

Options:
  --only GROUPS    Comma-separated subset (see --list-groups)
  --fail-on LEVEL  Exit 1 on 'fail' (default) or on 'warn' and above
  --quiet          Print only warnings and failures
  --list-groups    Print the group names and exit
  --help, -h       Show this help

Groups:
  sharing    Remote Login, Screen Sharing, File Sharing
  firewall   Application Firewall state and stealth mode
  updates    Automatic check, download and install of macOS updates
  disk       FileVault full-disk encryption
  lock       Password requirement after display sleep / screen saver
  sip        System Integrity Protection
  gatekeeper Gatekeeper assessments

Exit codes: 0 clean, 1 findings at or above --fail-on, 2 preflight, 3 usage
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

ALL_GROUPS="sharing firewall updates disk lock sip gatekeeper"

while (( $# > 0 )); do
  case "$1" in
    --only)      require_value "$1" "${2:-}"; shift; ONLY="$1" ;;
    --only=*)    ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --fail-on)   require_value "$1" "${2:-}"; shift; FAIL_ON="$1" ;;
    --fail-on=*) FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --quiet)     QUIET=1 ;;
    --list-groups) printf '%s\n' $ALL_GROUPS; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$FAIL_ON" in
  warn|fail) ;;
  *) err "--fail-on must be warn or fail, got: $FAIL_ON"; exit 3 ;;
esac

if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a requested <<< "$ONLY"
  for g in "${requested[@]}"; do
    case " $ALL_GROUPS " in
      *" $g "*) ;;
      *) err "unknown group: $g (see --list-groups)"; exit 3 ;;
    esac
  done
fi

# --help and --list-groups are handled above so they work anywhere; the checks
# themselves call macOS-only tools.
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS"
  exit 2
fi

want() {
  [[ -z "$ONLY" ]] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# A managed preference (MDM, configuration profile) or a plain plist value.
# Prints nothing when the key is unset, which for most of these means "macOS
# default" rather than "off".
pref() {
  local domain="$1" key="$2"
  defaults read "$domain" "$key" 2>/dev/null || true
}

# Is anything listening on this port, on an address other than loopback?
#
# The supported way to ask whether Remote Login is on is `systemsetup
# -getremotelogin`, which needs root, and an audit you have to sudo is an audit
# nobody runs. netstat answers unprivileged, and for these three services the
# listening socket *is* the service. Loopback-only binds are excluded: an ssh
# tunnel endpoint on 127.0.0.1 is not File Sharing switched on.
port_state() {
  local port="$1" out
  command -v netstat >/dev/null 2>&1 || { printf 'unknown\n'; return; }
  out="$(netstat -an -p tcp 2>/dev/null | awk -v p="[.]${port}\$" '
    $NF == "LISTEN" && $4 ~ p {
      addr = $4
      sub(/[.][0-9]+$/, "", addr)
      if (addr == "127.0.0.1" || addr == "::1") next
      found = 1
    }
    END { print (found ? "on" : "off") }')"
  printf '%s\n' "${out:-unknown}"
}

# --- sharing ---------------------------------------------------------------
if want sharing; then
  group "sharing"

  # systemsetup is authoritative but root-only; fall back to the port probe so
  # the check still answers as a normal user.
  rl="$(systemsetup -getremotelogin 2>/dev/null || true)"
  case "$rl" in
    *"Remote Login: On"*)  remote_login="on" ;;
    *"Remote Login: Off"*) remote_login="off" ;;
    *)                     remote_login="$(port_state 22)" ;;
  esac
  case "$remote_login" in
    off) pass "Remote Login (ssh) is off" ;;
    on)  warn "Remote Login (ssh) is on" \
              "fine if you ssh into this Mac; otherwise: sudo systemsetup -setremotelogin off" ;;
    *)   skip "could not determine whether Remote Login is on" ;;
  esac

  case "$(port_state 5900)" in
    off) pass "Screen Sharing is off" ;;
    on)  warn "Screen Sharing is on (port 5900 is listening)" \
              "System Settings > General > Sharing > Screen Sharing" ;;
    *)   skip "could not determine whether Screen Sharing is on" ;;
  esac

  case "$(port_state 445)" in
    off) pass "File Sharing is off" ;;
    on)  warn "File Sharing is on (port 445 is listening)" \
              "System Settings > General > Sharing > File Sharing" ;;
    *)   skip "could not determine whether File Sharing is on" ;;
  esac
fi

# --- firewall --------------------------------------------------------------
if want firewall; then
  group "firewall"
  SOCKETFILTERFW=/usr/libexec/ApplicationFirewall/socketfilterfw
  if [[ ! -x "$SOCKETFILTERFW" ]]; then
    skip "socketfilterfw not present"
  else
    # Captured and then matched rather than piped into `grep -q`: grep -q stops
    # reading at its first match, the producer dies of SIGPIPE, and under
    # `set -o pipefail` the pipeline reports 141. A false all-clear is the worst
    # thing this script can print.
    state="$("$SOCKETFILTERFW" --getglobalstate 2>/dev/null || true)"
    case "$state" in
      *"State = 1"*|*"State = 2"*|*"enabled"*)
        pass "Application Firewall is on"
        stealth="$("$SOCKETFILTERFW" --getstealthmode 2>/dev/null || true)"
        case "$stealth" in
          *"mode is on"*|*"enabled"*)
            pass "stealth mode is on" ;;
          *"mode is off"*|*"disabled"*)
            warn "stealth mode is off" \
                 "the Mac answers pings and probes to closed ports: sudo $SOCKETFILTERFW --setstealthmode on" ;;
          *)
            skip "could not read stealth mode" ;;
        esac
        ;;
      *"State = 0"*|*"disabled"*)
        warn "Application Firewall is off" \
             "fine behind a network you control; otherwise: sudo $SOCKETFILTERFW --setglobalstate on"
        # Stealth mode is meaningless with the firewall off, so it is not
        # reported separately — one finding, not two.
        ;;
      *)
        skip "could not read the firewall state (needs root on some releases)" ;;
    esac
  fi
fi

# --- updates ---------------------------------------------------------------
if want updates; then
  group "updates"
  SU_DOMAIN=/Library/Preferences/com.apple.SoftwareUpdate

  # Unset means the macOS default, which is on for all of these. Saying so
  # beats reporting a machine that has never been touched as misconfigured.
  check_pref() {
    local key="$1" label="$2" hint="$3" value
    value="$(pref "$SU_DOMAIN" "$key")"
    case "$value" in
      1|true)  pass "$label is on" ;;
      0|false) warn "$label is off" "$hint" ;;
      "")      pass "$label is unset (macOS defaults to on)" ;;
      *)       skip "$label: unexpected value '$value'" ;;
    esac
  }

  check_pref AutomaticCheckEnabled "checking for updates" \
    "softwareupdate --schedule on"
  check_pref AutomaticDownload "downloading updates in the background" \
    "System Settings > General > Software Update > Automatic Updates"
  check_pref CriticalUpdateInstall "installing security responses and system files" \
    "this is the one that matters most: System Settings > General > Software Update > Automatic Updates"
  check_pref ConfigDataInstall "installing system data files (XProtect, MRT)" \
    "System Settings > General > Software Update > Automatic Updates"

  auto_macos="$(pref "$SU_DOMAIN" AutomaticallyInstallMacOSUpdates)"
  case "$auto_macos" in
    1|true)  pass "installing macOS updates automatically is on" ;;
    0|false) warn "macOS updates are not installed automatically" \
                  "deliberate on a machine you cannot have rebooting itself; otherwise turn it on" ;;
    *)       skip "automatic macOS update installation not configured explicitly" ;;
  esac

  # How long since the machine last managed to check. This is answered from a
  # local plist and contacts nothing.
  last="$(pref "$SU_DOMAIN" LastSuccessfulDate)"
  if [[ -z "$last" ]]; then
    skip "no record of a successful update check"
  else
    last_epoch="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$last" '+%s' 2>/dev/null || true)"
    if [[ -z "$last_epoch" ]]; then
      skip "could not parse the last update check ($last)"
    else
      days=$(( ( $(date '+%s') - last_epoch ) / 86400 ))
      if (( days > 30 )); then
        warn "last successful update check was ${days}d ago" "softwareupdate --list"
      else
        pass "last successful update check was ${days}d ago"
      fi
    fi
  fi
fi

# --- disk ------------------------------------------------------------------
if want disk; then
  group "disk"
  if ! command -v fdesetup >/dev/null 2>&1; then
    skip "fdesetup not present"
  else
    fv="$(fdesetup status 2>/dev/null || true)"
    case "$fv" in
      *"FileVault is On"*)
        pass "FileVault is on" ;;
      *"Deferred enablement appears to be active"*)
        warn "FileVault is deferred, not enabled" \
             "encryption starts at the next login and has not yet: sudo fdesetup status" ;;
      *"FileVault is Off"*)
        fail "FileVault is off" \
             "an unencrypted disk is readable by anyone holding the machine: sudo fdesetup enable" ;;
      *)
        skip "could not read FileVault status" ;;
    esac
  fi
fi

# --- screen lock ------------------------------------------------------------
if want lock; then
  group "lock"
  if ! command -v sysadminctl >/dev/null 2>&1; then
    skip "sysadminctl not present"
  else
    lock_state="$(sysadminctl -screenLock status 2>&1 || true)"
    lock_lower="$(printf '%s' "$lock_state" | tr '[:upper:]' '[:lower:]')"
    case "$lock_lower" in
      *"delay is immediate"*)
        pass "password is required immediately after display sleep or screen saver"
        ;;
      *"screenlock is off"*|*"screen lock is off"*|*"disabled"*)
        fail "screen lock password requirement is off" \
             "System Settings > Lock Screen > Require password after screen saver begins or display is turned off"
        ;;
      *"delay is "*)
        warn "screen lock has a non-immediate password-free delay ($lock_state)" \
             "set Require password to Immediately in System Settings > Lock Screen"
        ;;
      *)
        skip "could not determine the screen lock password delay"
        ;;
    esac
  fi
fi

# --- sip -------------------------------------------------------------------
if want sip; then
  group "sip"
  if ! command -v csrutil >/dev/null 2>&1; then
    skip "csrutil not present"
  else
    sip="$(csrutil status 2>/dev/null || true)"
    case "$sip" in
      *"status: enabled"*)
        pass "System Integrity Protection is enabled" ;;
      *"status: disabled"*)
        fail "System Integrity Protection is disabled" \
             "re-enable from Recovery (hold power at boot) with: csrutil enable" ;;
      *"unknown (Custom Configuration)"*|*"Custom Configuration"*)
        warn "System Integrity Protection is partially disabled" \
             "csrutil status lists which protections are off; re-enable from Recovery with: csrutil enable" ;;
      *)
        skip "could not read SIP status" ;;
    esac
  fi
fi

# --- gatekeeper ------------------------------------------------------------
if want gatekeeper; then
  group "gatekeeper"
  if ! command -v spctl >/dev/null 2>&1; then
    skip "spctl not present"
  else
    gk="$(spctl --status 2>/dev/null || true)"
    case "$gk" in
      *"assessments enabled"*)
        pass "Gatekeeper assessments are enabled" ;;
      *"assessments disabled"*)
        fail "Gatekeeper assessments are disabled" \
             "every downloaded app runs unchecked: sudo spctl --master-enable" ;;
      *)
        skip "could not read Gatekeeper status" ;;
    esac
  fi
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s pass%s  %s%s warn%s  %s%s fail%s  %s%s skip%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

if (( SKIP_COUNT > 0 )) && [[ "$(id -u)" != "0" ]]; then
  info "some checks read more with root; rerun with sudo for the full picture"
fi

if [[ "$FAIL_ON" == "warn" ]] && (( WARN_COUNT + FAIL_COUNT > 0 )); then
  exit 1
fi
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0

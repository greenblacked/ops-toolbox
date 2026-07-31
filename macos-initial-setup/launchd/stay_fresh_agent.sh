#!/usr/bin/env bash
# stay_fresh_agent.sh
# Install, remove or inspect a LaunchAgent that runs stay_fresh.sh on a schedule.
#
# The agent runs in your GUI login session as you — not as root. That is a hard
# constraint, not a preference: a LaunchAgent has no terminal, so a sudo prompt
# has nothing to prompt. Steps needing root (memory purge, DNS flush, system
# caches, system diagnostics) are therefore skipped, and the agent always passes
# --no-sudo --yes. Run stay_fresh.sh by hand when you want the root-owned steps.
#
# Usage:
#   ./stay_fresh_agent.sh install [--weekday N] [--hour N] [--minute N] [--dry-run]
#   ./stay_fresh_agent.sh uninstall
#   ./stay_fresh_agent.sh status
#   ./stay_fresh_agent.sh run-now
#
# Options:
#   --weekday N   0-7, Sunday is 0 or 7 (default 1, Monday). 'daily' for every day
#   --hour N      0-23 (default 10)
#   --minute N    0-59 (default 30)
#   --dry-run     Make the agent invoke stay_fresh.sh with --dry-run
#   --print-only  Print the plist that would be installed and exit, writing
#                 nothing and loading nothing
#
# Exit codes:
#   0   success
#   1   command failed
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAY_FRESH="$(cd -P "$SCRIPT_DIR/.." && pwd)/stay_fresh.sh"

LABEL="com.pretty-useful.stay-fresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/stay_fresh"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

usage() {
  awk 'NR == 1 { next }
       /^#/    { sub(/^# ?/, ""); print; next }
       { exit }' "$0"
}

CMD=""
WEEKDAY=1
HOUR=10
MINUTE=30
DAILY=0
AGENT_DRY_RUN=0
PRINT_ONLY=0

while (( $# > 0 )); do
  case "$1" in
    install|uninstall|status|run-now)
      if [[ -n "$CMD" ]]; then err "only one command at a time"; exit 3; fi
      CMD="$1"
      ;;
    --weekday)
      shift; [[ $# -gt 0 ]] || { err "--weekday needs a value"; exit 3; }
      if [[ "$1" == "daily" ]]; then
        DAILY=1
      elif [[ "$1" =~ ^[0-7]$ ]]; then
        WEEKDAY="$1"
      else
        err "--weekday must be 0-7 or 'daily'"; exit 3
      fi
      ;;
    --hour)
      shift; [[ $# -gt 0 ]] || { err "--hour needs a value"; exit 3; }
      [[ "$1" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { err "--hour must be 0-23"; exit 3; }
      HOUR="$1"
      ;;
    --minute)
      shift; [[ $# -gt 0 ]] || { err "--minute needs a value"; exit 3; }
      [[ "$1" =~ ^([0-9]|[1-5][0-9])$ ]] || { err "--minute must be 0-59"; exit 3; }
      MINUTE="$1"
      ;;
    --dry-run)    AGENT_DRY_RUN=1 ;;
    --print-only) PRINT_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 3 ;;
  esac
  shift
done

[[ -n "$CMD" ]] || { usage; exit 3; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "launchd is macOS-only"
  exit 2
fi

DOMAIN="gui/$(id -u)"

case "$CMD" in
  install)
    if [[ ! -x "$STAY_FRESH" ]]; then
      err "stay_fresh.sh not found or not executable at $STAY_FRESH"
      exit 2
    fi
    if (( PRINT_ONLY == 0 )); then
      mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
    fi

    args="        <string>--yes</string>
        <string>--no-sudo</string>"
    if (( AGENT_DRY_RUN )); then
      args="$args
        <string>--dry-run</string>"
    fi

    if (( DAILY )); then
      schedule="    <key>StartCalendarInterval</key>
    <dict>
      <key>Hour</key><integer>$HOUR</integer>
      <key>Minute</key><integer>$MINUTE</integer>
    </dict>"
      when="daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
    else
      schedule="    <key>StartCalendarInterval</key>
    <dict>
      <key>Weekday</key><integer>$WEEKDAY</integer>
      <key>Hour</key><integer>$HOUR</integer>
      <key>Minute</key><integer>$MINUTE</integer>
    </dict>"
      when="weekday $WEEKDAY at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
    fi

    plist_body="$(cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>$STAY_FRESH</string>
$args
    </array>
$schedule
    <!-- Housekeeping missed because the Mac was asleep should still happen,
         but only once after wake, not once per missed interval. -->
    <key>StartCalendarIntervalRunMissed</key>
    <true/>
    <key>RunAtLoad</key>
    <false/>
    <!-- Never let housekeeping compete with interactive work. -->
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/agent.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/agent.err.log</string>
  </dict>
</plist>
PLIST_EOF
)"

    # Validate before writing, so a malformed template never lands in
    # ~/Library/LaunchAgents where launchd would keep complaining about it.
    lint_tmp="$(mktemp)"
    printf '%s\n' "$plist_body" >"$lint_tmp"
    if ! plutil -lint "$lint_tmp" >/dev/null 2>&1; then
      err "generated plist is malformed — refusing to install"
      plutil -lint "$lint_tmp" 2>&1 | sed 's/^/      /' >&2
      rm -f "$lint_tmp"
      exit 1
    fi
    rm -f "$lint_tmp"

    if (( PRINT_ONLY )); then
      printf '%s\n' "$plist_body"
      exit 0
    fi

    # Replacing an existing agent means booting the old one out first;
    # bootstrap onto a loaded label fails with a bare "Input/output error".
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    fi

    printf '%s\n' "$plist_body" >"$PLIST"

    if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
      err "launchctl bootstrap failed for $LABEL"
      info "inspect with: launchctl print $DOMAIN/$LABEL"
      exit 1
    fi

    ok "installed $LABEL — runs $when"
    info "as you, without sudo: memory purge, DNS flush, system caches and"
    info "system diagnostics are skipped. Run stay_fresh.sh by hand for those."
    printf "  %slogs: %s%s\n" "$C_DIM" "$LOG_DIR/agent.{out,err}.log" "$C_RESET"
    ;;

  uninstall)
    removed=0
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
      removed=1
    fi
    if [[ -f "$PLIST" ]]; then
      rm -f "$PLIST"
      removed=1
    fi
    if (( removed )); then
      ok "removed $LABEL"
    else
      info "$LABEL was not installed"
    fi
    ;;

  status)
    if [[ -f "$PLIST" ]]; then
      ok "plist present: $PLIST"
    else
      warn "no plist at $PLIST"
    fi
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      ok "loaded in $DOMAIN"
      launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
        | grep -E '^\s+(state|last exit code|runs) ' || true
    else
      warn "not loaded in $DOMAIN"
      exit 1
    fi
    ;;

  run-now)
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      err "$LABEL is not loaded — install it first"
      exit 1
    fi
    # -k restarts it if a run is already in flight.
    if launchctl kickstart -k "$DOMAIN/$LABEL"; then
      ok "triggered $LABEL"
      info "follow with: tail -f $LOG_DIR/agent.out.log"
    else
      err "could not kickstart $LABEL"
      exit 1
    fi
    ;;
esac

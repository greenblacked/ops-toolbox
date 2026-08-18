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
#   ./stay_fresh_agent.sh logs [--tail N]
#
# Options:
#   --weekday N   0-7, Sunday is 0 or 7 (default 1, Monday). 'daily' for every day
#   --hour N      0-23 (default 10)
#   --minute N    0-59 (default 30)
#   --dry-run     Make the agent invoke stay_fresh.sh with --dry-run
#   --print-only  Print the plist that would be installed and exit, writing
#                 nothing and loading nothing
#   --tail N      With 'logs', print the last N lines of the newest log
#                 (default 80)
#
# Exit codes:
#   0   success
#   1   command failed
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
AGENT_SCRIPT="$SCRIPT_DIR/$(basename "$SCRIPT_SOURCE")"
STAY_FRESH="$(cd -P "$SCRIPT_DIR/.." && pwd)/stay_fresh.sh"

LABEL="com.pretty-useful.stay-fresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/stay_fresh"
AGENT_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
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
TAIL_LINES=80
TAIL_SET=0

while (( $# > 0 )); do
  case "$1" in
    install|uninstall|status|run-now|logs|run-scheduled)
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
    --tail)
      shift; [[ $# -gt 0 ]] || { err "--tail needs a value"; exit 3; }
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || { err "--tail must be a positive integer"; exit 3; }
      TAIL_LINES="$1"
      TAIL_SET=1
      ;;
    --tail=*)
      TAIL_LINES="${1#*=}"
      [[ "$TAIL_LINES" =~ ^[1-9][0-9]*$ ]] || { err "--tail must be a positive integer"; exit 3; }
      TAIL_SET=1
      ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 3 ;;
  esac
  shift
done

[[ -n "$CMD" ]] || { usage; exit 3; }

if [[ "$CMD" != "logs" ]] && (( TAIL_SET )); then
  err "--tail is only valid with the logs command"
  exit 3
fi

# `install --print-only` is deliberately portable so CI can parse and inspect
# the exact plist without pretending a Linux container has launchd.
if [[ "$(uname -s)" != "Darwin" ]] \
   && ! { [[ "$CMD" == "install" ]] && (( PRINT_ONLY || AGENT_DRY_RUN )); }; then
  err "launchd is macOS-only"
  exit 2
fi

DOMAIN="gui/$(id -u)"

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

validate_plist() {
  local file="$1"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$file" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1], "rb"))' "$file" \
      >/dev/null 2>&1
  else
    return 1
  fi
}

agent_log_names() {
  local path name
  for path in "$LOG_DIR"/agent-*.log; do
    [[ -f "$path" ]] || continue
    name="${path##*/}"
    [[ "$name" =~ ^agent-[0-9]{8}-[0-9]{6}-[0-9]+[.]log$ ]] || continue
    printf '%s\n' "$name"
  done
}

run_scheduled() {
  if [[ ! -x "$STAY_FRESH" ]]; then
    err "stay_fresh.sh not found or not executable at $STAY_FRESH"
    return 2
  fi
  mkdir -p "$LOG_DIR" || { err "cannot create log directory: $LOG_DIR"; return 1; }

  local run_log="$LOG_DIR/agent-$(date +%Y%m%d-%H%M%S)-$$.log"
  local -a args=(--yes --no-sudo)
  (( AGENT_DRY_RUN )) && args+=(--dry-run)

  /bin/bash "$STAY_FRESH" "${args[@]}" >"$run_log" 2>&1
  local rc=$?

  # One bounded, complete transcript per invocation. launchd itself writes to
  # /dev/null, so fixed agent.out/agent.err files cannot grow without limit.
  local old_log_list old_log
  old_log_list="$(mktemp)"
  agent_log_names | sort -r | tail -n +11 > "$old_log_list"
  while IFS= read -r old_log; do
    [[ -n "$old_log" ]] || continue
    rm -f "$LOG_DIR/$old_log" 2>/dev/null || true
  done < "$old_log_list"
  rm -f "$old_log_list"

  return "$rc"
}

if [[ "$CMD" == "run-scheduled" ]]; then
  run_scheduled
  exit $?
fi

case "$CMD" in
  install)
    if [[ ! -x "$STAY_FRESH" ]]; then
      err "stay_fresh.sh not found or not executable at $STAY_FRESH"
      exit 2
    fi
    if (( PRINT_ONLY == 0 && AGENT_DRY_RUN == 0 )); then
      mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
    fi

    args="        <string>run-scheduled</string>"
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

    xml_agent_script="$(xml_escape "$AGENT_SCRIPT")"
    xml_agent_path="$(xml_escape "$AGENT_PATH")"
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
      <string>$xml_agent_script</string>
$args
    </array>
$schedule
    <key>RunAtLoad</key>
    <false/>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>$xml_agent_path</string>
    </dict>
    <!-- Never let housekeeping compete with interactive work. -->
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
  </dict>
</plist>
PLIST_EOF
)"

    # Validate before writing, so a malformed template never lands in
    # ~/Library/LaunchAgents where launchd would keep complaining about it.
    lint_tmp="$(mktemp)"
    printf '%s\n' "$plist_body" >"$lint_tmp"
    if ! validate_plist "$lint_tmp"; then
      err "generated plist could not be validated — refusing to install"
      if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$lint_tmp" 2>&1 | sed 's/^/      /' >&2
      fi
      rm -f "$lint_tmp"
      exit 1
    fi
    rm -f "$lint_tmp"

    if (( PRINT_ONLY )); then
      printf '%s\n' "$plist_body"
      exit 0
    fi

    # AGENT_DRY_RUN was parsed and then only ever used to add --dry-run to the
    # plist's own arguments, so `install --dry-run` booted out the running
    # agent, wrote the plist and bootstrapped it — exactly what
    # systemd/stay_fresh_timer.sh did on Linux. --print-only was the only
    # no-write path, and it is a different flag with a different output.
    if (( AGENT_DRY_RUN )); then
      printf "  %s(dry-run)%s would write %s\n" "$C_DIM" "$C_RESET" "$PLIST"
      printf '%s\n' "$plist_body" | sed 's/^/           /'
      printf "  %s(dry-run)%s would run launchctl bootout %s/%s (if loaded)\n" \
        "$C_DIM" "$C_RESET" "$DOMAIN" "$LABEL"
      printf "  %s(dry-run)%s would run launchctl bootstrap %s %s\n" \
        "$C_DIM" "$C_RESET" "$DOMAIN" "$PLIST"
      printf "dry-run complete; no changes written\n"
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
    info "cask upgrades are skipped; Homebrew formulae still update unattended"
    printf "  %slogs: %s%s\n" "$C_DIM" "$LOG_DIR/agent-<timestamp>-<pid>.log (10 kept)" "$C_RESET"
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
    state="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
      | awk '/^[[:space:]]*state =/ { print $3; exit }')"
    if [[ "$state" == "running" ]]; then
      warn "$LABEL is already running — refusing to interrupt it"
      exit 1
    fi
    if launchctl kickstart "$DOMAIN/$LABEL"; then
      ok "triggered $LABEL"
      info "latest log: ls -1t '$LOG_DIR'/agent-*.log | head -1"
    else
      err "could not kickstart $LABEL"
      exit 1
    fi
    ;;

  logs)
    latest_name="$(agent_log_names | sort -r | head -n1)"
    if [[ -z "$latest_name" ]]; then
      warn "no agent logs found in $LOG_DIR"
      exit 1
    fi
    latest_log="$LOG_DIR/$latest_name"
    info "latest log: $latest_log"
    tail -n "$TAIL_LINES" "$latest_log"
    ;;
esac

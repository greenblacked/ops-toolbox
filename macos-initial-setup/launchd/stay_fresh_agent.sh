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
#   ./stay_fresh_agent.sh install [--weekday N] [--hour N] [--minute N]
#                                 [--profile safe|full] [--notify MODE]
#                                 [--notify-when WHEN] [--ignore-power]
#                                 [--dry-run]
#   ./stay_fresh_agent.sh uninstall [--dry-run]
#   ./stay_fresh_agent.sh status
#   ./stay_fresh_agent.sh run-now
#   ./stay_fresh_agent.sh logs [--tail N]
#
# Options:
#   --weekday N   0-7, Sunday is 0 or 7 (default 1, Monday). 'daily' for every day
#   --hour N      0-23 (default 10)
#   --minute N    0-59 (default 30)
#   --profile P   'safe' runs protected app/AI-cache cleanup, workspace cleanup,
#                 version reporting, the pending-OS-update report and the
#                 snapshot listing; 'full' keeps the original broad behavior
#                 (default safe)
#   --notify M    Passed to stay_fresh.sh as --notify: none, macos, telegram,
#                 slack, both, auto, or a comma-separated list of channels
#                 (default: not passed, and stay_fresh.sh's auto sends a macOS
#                 banner because no terminal is attached)
#   --notify-when W
#                 Passed to stay_fresh.sh as --notify-when: always, warn or
#                 fail (default: not passed; stay_fresh.sh's default is always)
#   --ignore-power
#                 Sweep even on battery and even with somebody at the keyboard,
#                 instead of deferring. Valid for 'install', where it travels
#                 into the plist and applies to every firing, and for
#                 'run-scheduled', where it applies to that run
#   --dry-run     Preview install or uninstall; change nothing
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

# One string field of stay_fresh.sh's last-run.json, with the two escapes it
# writes (backslash and double quote) undone.
json_field() {
  sed -n "s/^  \"$1\": \"\(.*\)\",\{0,1\}\$/\1/p" "$2" | head -n 1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

# Whether stay_fresh.sh will take a flag's value, asked of stay_fresh.sh
# itself: `--list-steps` answers after the argument checks and before
# anything runs, so exit 0 means yes and its message says why not. Checked
# at install so a typo fails here, not on the first scheduled run with
# nobody watching - and checked by the script that will parse it, so the
# two cannot disagree about `none,macos` or a channel added next month.
# Usage: stay_fresh_accepts --flag VALUE   (the reason lands in FLAG_ERROR)
FLAG_ERROR=""
stay_fresh_accepts() {
  local flag="$1" value="$2" out
  if [[ ! -x "$STAY_FRESH" ]]; then
    FLAG_ERROR="cannot validate $flag: stay_fresh.sh not found or not executable at $STAY_FRESH"
    return 1
  fi
  if out="$("$STAY_FRESH" --list-steps "$flag" "$value" 2>&1 >/dev/null)"; then
    return 0
  fi
  FLAG_ERROR="${out#*\] }"
  [[ -n "$FLAG_ERROR" ]] || FLAG_ERROR="$flag value rejected by stay_fresh.sh: $value"
  return 1
}

# Epoch seconds of a "YYYY-MM-DD HH:MM:SS" stamp: the BSD date on macOS, the
# GNU one where the tests run. Empty when neither can read it, and for an
# empty stamp, which GNU date would otherwise read as today.
epoch_of() {
  local e
  [[ -n "$1" ]] || { printf ''; return 0; }
  e="$(date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null)" \
    || e="$(date -d "$1" +%s 2>/dev/null)" \
    || e=""
  printf '%s' "$e"
}

# Modification time of a file in epoch seconds: BSD stat first, GNU second.
mtime_of() {
  local m
  m="$(stat -f %m "$1" 2>/dev/null)" || m="$(stat -c %Y "$1" 2>/dev/null)" || m=""
  printf '%s' "$m"
}

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
PROFILE="safe"
PROFILE_SET=0
NOTIFY=""
NOTIFY_SET=0
NOTIFY_WHEN=""
NOTIFY_WHEN_SET=0
SCHEDULE_SET=0
TAIL_LINES=80
TAIL_SET=0
IGNORE_POWER=0

while (( $# > 0 )); do
  case "$1" in
    install|uninstall|status|run-now|logs|run-scheduled)
      if [[ -n "$CMD" ]]; then err "only one command at a time"; exit 3; fi
      CMD="$1"
      ;;
    --weekday)
      shift; [[ $# -gt 0 ]] || { err "--weekday needs a value"; exit 3; }
      SCHEDULE_SET=1
      if [[ "$1" == "daily" ]]; then
        DAILY=1
      elif [[ "$1" =~ ^[0-7]$ ]]; then
        DAILY=0
        WEEKDAY="$1"
      else
        err "--weekday must be 0-7 or 'daily'"; exit 3
      fi
      ;;
    --weekday=*)
      SCHEDULE_SET=1
      if [[ "${1#*=}" == "daily" ]]; then
        DAILY=1
      elif [[ "${1#*=}" =~ ^[0-7]$ ]]; then
        DAILY=0
        WEEKDAY="${1#*=}"
      else
        err "--weekday must be 0-7 or 'daily'"; exit 3
      fi
      ;;
    --hour)
      shift; [[ $# -gt 0 ]] || { err "--hour needs a value"; exit 3; }
      [[ "$1" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { err "--hour must be 0-23"; exit 3; }
      SCHEDULE_SET=1
      HOUR="$1"
      ;;
    --hour=*)
      HOUR="${1#*=}"
      [[ "$HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { err "--hour must be 0-23"; exit 3; }
      SCHEDULE_SET=1
      ;;
    --minute)
      shift; [[ $# -gt 0 ]] || { err "--minute needs a value"; exit 3; }
      [[ "$1" =~ ^([0-9]|[1-5][0-9])$ ]] || { err "--minute must be 0-59"; exit 3; }
      SCHEDULE_SET=1
      MINUTE="$1"
      ;;
    --minute=*)
      MINUTE="${1#*=}"
      [[ "$MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]] || { err "--minute must be 0-59"; exit 3; }
      SCHEDULE_SET=1
      ;;
    --profile)
      shift; [[ $# -gt 0 ]] || { err "--profile needs a value"; exit 3; }
      [[ "$1" == "safe" || "$1" == "full" ]] \
        || { err "--profile must be 'safe' or 'full'"; exit 3; }
      PROFILE="$1"
      PROFILE_SET=1
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      [[ "$PROFILE" == "safe" || "$PROFILE" == "full" ]] \
        || { err "--profile must be 'safe' or 'full'"; exit 3; }
      PROFILE_SET=1
      ;;
    --notify)
      shift; [[ $# -gt 0 ]] || { err "--notify needs a value"; exit 3; }
      stay_fresh_accepts --notify "$1" || { err "$FLAG_ERROR"; exit 3; }
      NOTIFY="$1"
      NOTIFY_SET=1
      ;;
    --notify=*)
      NOTIFY="${1#*=}"
      stay_fresh_accepts --notify "$NOTIFY" || { err "$FLAG_ERROR"; exit 3; }
      NOTIFY_SET=1
      ;;
    --notify-when)
      shift; [[ $# -gt 0 ]] || { err "--notify-when needs a value"; exit 3; }
      stay_fresh_accepts --notify-when "$1" || { err "$FLAG_ERROR"; exit 3; }
      NOTIFY_WHEN="$1"
      NOTIFY_WHEN_SET=1
      ;;
    --notify-when=*)
      NOTIFY_WHEN="${1#*=}"
      stay_fresh_accepts --notify-when "$NOTIFY_WHEN" || { err "$FLAG_ERROR"; exit 3; }
      NOTIFY_WHEN_SET=1
      ;;
    --ignore-power) IGNORE_POWER=1 ;;
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

case "$CMD" in
  install)
    (( TAIL_SET == 0 )) || { err "--tail is only valid with logs"; exit 3; }
    ;;
  uninstall)
    (( SCHEDULE_SET == 0 && PROFILE_SET == 0 && NOTIFY_SET == 0 && NOTIFY_WHEN_SET == 0 && PRINT_ONLY == 0 && TAIL_SET == 0 \
       && IGNORE_POWER == 0 )) \
      || { err "uninstall accepts only --dry-run"; exit 3; }
    ;;
  logs)
    (( SCHEDULE_SET == 0 && PROFILE_SET == 0 && NOTIFY_SET == 0 && NOTIFY_WHEN_SET == 0 && PRINT_ONLY == 0 && AGENT_DRY_RUN == 0 \
       && IGNORE_POWER == 0 )) \
      || { err "logs accepts only --tail"; exit 3; }
    ;;
  status|run-now)
    (( SCHEDULE_SET == 0 && PROFILE_SET == 0 && NOTIFY_SET == 0 && NOTIFY_WHEN_SET == 0 && PRINT_ONLY == 0 \
       && AGENT_DRY_RUN == 0 && TAIL_SET == 0 && IGNORE_POWER == 0 )) \
      || { err "$CMD does not accept options"; exit 3; }
    ;;
  run-scheduled)
    (( SCHEDULE_SET == 0 && PRINT_ONLY == 0 && TAIL_SET == 0 )) \
      || { err "run-scheduled accepts only --profile, --notify, --notify-when, --ignore-power and --dry-run"; exit 3; }
    ;;
esac

# `install --print-only` is deliberately portable so CI can parse and inspect
# the exact plist without pretending a Linux container has launchd.
if [[ "$(uname -s)" != "Darwin" ]] \
   && ! { [[ "$CMD" == "install" ]] && (( PRINT_ONLY || AGENT_DRY_RUN )); } \
   && ! { [[ "$CMD" == "uninstall" ]] && (( AGENT_DRY_RUN )); }; then
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

# Where the power is coming from, as pmset reports it: "ac", "battery", or
# "unknown" when pmset is missing or says something this does not recognise.
# Unknown is treated as ac by the caller - a desktop with no battery must not
# have its schedule deferred forever by a probe that cannot answer.
power_source() {
  local out
  command -v pmset >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  out="$(pmset -g batt 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  case "$out" in
    *"'AC Power'"*)      printf 'ac\n' ;;
    *"'Battery Power'"*) printf 'battery\n' ;;
    *)                   printf 'unknown\n' ;;
  esac
}

# Seconds since the last keyboard or mouse event, from the HID system. Prints
# nothing when it cannot be read, which the caller treats as "cannot tell".
user_idle_seconds() {
  command -v ioreg >/dev/null 2>&1 || return 0
  ioreg -c IOHIDSystem 2>/dev/null \
    | awk '/HIDIdleTime/ { gsub(/[^0-9]/, "", $NF); if ($NF != "") { printf "%d\n", $NF / 1000000000; exit } }'
}

# A scheduled run is not worth a battery or an interruption. Both guards are
# advisory and both can be turned off with --ignore-power; neither ever runs
# for `run-now`, which is a person asking for it deliberately.
IDLE_BEFORE_SWEEP_S=300

# When the schedule last actually fired, for `status`. stay_fresh.sh's own
# last-run.json is rewritten by every run, a manual --quick included, so it
# cannot tell a job that stopped firing from one whose owner keeps running the
# script by hand; this stamp is written only here. The third field says whether
# the firing did the full job, and is empty when it did — readers that stop at
# the second field are unaffected.
note_scheduled_run() {
  (( AGENT_DRY_RUN == 0 )) || return 0
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${2:-}" \
    > "$LOG_DIR/last-scheduled" 2>/dev/null || true
}

run_scheduled() {
  if [[ ! -x "$STAY_FRESH" ]]; then
    err "stay_fresh.sh not found or not executable at $STAY_FRESH"
    return 2
  fi
  mkdir -p "$LOG_DIR" || { err "cannot create log directory: $LOG_DIR"; return 1; }

  local run_log="$LOG_DIR/agent-$(date +%Y%m%d-%H%M%S)-$$.log"
  local -a args=(--yes --no-sudo --fail-on-warn)
  local deferred="" power idle=""

  if (( IGNORE_POWER == 0 )); then
    power="$(power_source)"
    if [[ "$power" == "battery" ]]; then
      # A full sweep is minutes of du and rm plus a brew upgrade. On battery
      # that is somebody's afternoon, spent without being asked. The next
      # firing on mains does the work.
      info "on battery — deferring this run (pass --ignore-power to run anyway)"
      note_scheduled_run 0 "deferred:battery"
      return 0
    fi
    idle="$(user_idle_seconds)"
    if [[ "$idle" =~ ^[0-9]+$ ]] && (( idle < IDLE_BEFORE_SWEEP_S )); then
      # Somebody is at the keyboard. Deferring outright would mean a machine
      # in use at this hour every day never runs at all, so the read-only
      # reports run instead: they are the part worth having daily, and they
      # neither sweep nor upgrade anything.
      info "active ${idle}s ago — running the read-only reports only, not the sweep"
      args+=(--reports)
      deferred="reports-only:active"
    fi
  fi
  if [[ -n "$deferred" ]]; then
    : # --reports is already in args, and it refuses to be joined with --only
  elif [[ "$PROFILE" == "safe" ]]; then
    # Scheduled cleanup must be conservative by default. These steps protect
    # active/unknown application state and remove workspace data only when the
    # recorded local project path is provably gone. The two reports are
    # read-only and are the reason to look at the verdict at all: a pending
    # macOS update and a pile of local snapshots are what a scheduled run can
    # tell you that you would not otherwise notice.
    args+=(--only app-caches,ai-caches,workspace-storage,versions,os-updates,snapshots,downloads,launch-agents)
  fi
  (( NOTIFY_SET )) && args+=(--notify "$NOTIFY")
  (( NOTIFY_WHEN_SET )) && args+=(--notify-when "$NOTIFY_WHEN")
  (( AGENT_DRY_RUN )) && args+=(--dry-run)

  /bin/bash "$STAY_FRESH" "${args[@]}" >"$run_log" 2>&1
  local rc=$?

  note_scheduled_run "$rc" "$deferred"

  # One bounded, complete transcript per invocation. launchd itself writes to
  # /dev/null, so fixed agent.out/agent.err files cannot grow without limit.
  #
  # A preview stops here. This rotation deletes transcripts of real past
  # firings, and --dry-run exists to show what a firing would do, not to do the
  # irreversible half of it: previewing a schedule change used to destroy the
  # oldest surviving records of what the schedule had actually been doing, and
  # every preview destroyed one more, because the preview's own transcript
  # pushed the next one over the edge.
  # The transcript this invocation just wrote is the one file a dry run leaves
  # behind, and that is deliberate - it is the step list being previewed - so
  # it counts towards the ten at the next real firing, not at this one.
  (( AGENT_DRY_RUN == 0 )) || return "$rc"

  # mktemp fails on the full disk this whole script exists to postpone.
  # Unchecked, the scratch path is the empty string, and every line below it
  # addresses a file with no name: the redirect and the loop each report an
  # unnamed file on stderr - which launchd sends to /dev/null, so nobody ever
  # sees it - and the rotation silently stops happening on the one machine that
  # needed the space back. Skip it instead and leave the logs to the next
  # firing that can make a scratch file, the way linux/stay_fresh.sh does.
  local old_log_list old_log
  old_log_list="$(mktemp 2>/dev/null || true)"
  if [[ -n "$old_log_list" ]]; then
    agent_log_names | sort -r | tail -n +11 > "$old_log_list"
    while IFS= read -r old_log; do
      [[ -n "$old_log" ]] || continue
      rm -f "$LOG_DIR/$old_log" 2>/dev/null || true
    done < "$old_log_list"
    rm -f "$old_log_list"
  fi

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
      if ! mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"; then
        err "cannot create LaunchAgent or log directory"
        exit 1
      fi
    fi

    args="        <string>run-scheduled</string>
        <string>--profile</string>
        <string>$(xml_escape "$PROFILE")</string>"
    if (( NOTIFY_SET )); then
      args="$args
        <string>--notify</string>
        <string>$(xml_escape "$NOTIFY")</string>"
    fi
    if (( NOTIFY_WHEN_SET )); then
      args="$args
        <string>--notify-when</string>
        <string>$(xml_escape "$NOTIFY_WHEN")</string>"
    fi
    # The battery and at-the-keyboard guards live in run-scheduled, so this is
    # the only way --ignore-power can mean anything at install time. Without
    # this the flag parsed, passed validation and was reported as installed,
    # while the agent it wrote kept deferring on battery for good.
    if (( IGNORE_POWER )); then
      args="$args
        <string>--ignore-power</string>"
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
    if ! lint_tmp="$(mktemp)"; then
      err "cannot create temporary plist for validation"
      exit 1
    fi
    if ! printf '%s\n' "$plist_body" >"$lint_tmp"; then
      rm -f "$lint_tmp"
      err "cannot write temporary plist for validation"
      exit 1
    fi
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

    # Previewing an install must not alter the installed command either: this
    # plist is the exact real configuration, shown before any launchctl action.
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

    # Stage in the destination directory so the final rename is atomic. Keep a
    # byte-for-byte backup until the new job has bootstrapped; an update failure
    # must leave the previous schedule running, not merely leave a valid file.
    agent_dir="$(dirname "$PLIST")"
    if ! staged_plist="$(mktemp "$agent_dir/.${LABEL}.new.XXXXXX")"; then
      err "cannot stage LaunchAgent plist in $agent_dir"
      exit 1
    fi
    if ! printf '%s\n' "$plist_body" >"$staged_plist"; then
      rm -f "$staged_plist"
      err "cannot write staged LaunchAgent plist"
      exit 1
    fi

    backup_plist=""
    if [[ -f "$PLIST" ]]; then
      if ! backup_plist="$(mktemp "$agent_dir/.${LABEL}.old.XXXXXX")" \
         || ! cp -p "$PLIST" "$backup_plist"; then
        rm -f "$staged_plist" ${backup_plist:+"$backup_plist"}
        err "cannot back up the existing LaunchAgent plist"
        exit 1
      fi
    fi

    was_loaded=0
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      was_loaded=1
      if ! launchctl bootout "$DOMAIN/$LABEL"; then
        rm -f "$staged_plist" ${backup_plist:+"$backup_plist"}
        err "could not stop the existing $LABEL job; configuration was not changed"
        exit 1
      fi
    fi

    if ! mv -f "$staged_plist" "$PLIST"; then
      (( was_loaded )) && launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1
      rm -f "$staged_plist" ${backup_plist:+"$backup_plist"}
      err "could not install the new LaunchAgent plist"
      exit 1
    fi

    if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
      err "launchctl bootstrap failed for $LABEL; restoring the previous configuration"
      rm -f "$PLIST"
      rollback_ok=1
      if [[ -n "$backup_plist" ]]; then
        if mv -f "$backup_plist" "$PLIST"; then
          backup_plist=""
        else
          rollback_ok=0
          err "could not restore the previous plist"
        fi
      fi
      if (( was_loaded )) && [[ -f "$PLIST" ]]; then
        if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
          rollback_ok=0
          err "could not restart the previous $LABEL job"
        fi
      fi
      rm -f ${backup_plist:+"$backup_plist"}
      (( rollback_ok )) || err "manual recovery is required: inspect $PLIST"
      exit 1
    fi
    rm -f ${backup_plist:+"$backup_plist"}

    ok "installed $LABEL — runs $when (profile: $PROFILE)"
    info "as you, without sudo: memory purge, DNS flush, system caches and"
    info "system diagnostics are skipped. Run stay_fresh.sh by hand for those."
    if [[ "$PROFILE" == "safe" ]]; then
      info "safe profile: app/AI caches, stale workspace storage, versions, pending OS updates, the snapshot listing, old downloads and orphaned launch agents (both reported, never removed)"
    else
      info "full profile: cask upgrades are skipped; formulae update unattended"
    fi
    printf "  %slogs: %s%s\n" "$C_DIM" "$LOG_DIR/agent-<timestamp>-<pid>.log (10 kept)" "$C_RESET"
    ;;

  uninstall)
    if (( AGENT_DRY_RUN )); then
      printf "  %s(dry-run)%s would run launchctl bootout %s/%s (if loaded)\n" \
        "$C_DIM" "$C_RESET" "$DOMAIN" "$LABEL"
      printf "  %s(dry-run)%s would remove %s (if present)\n" \
        "$C_DIM" "$C_RESET" "$PLIST"
      printf "dry-run complete; no changes written\n"
      exit 0
    fi

    removed=0
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      if ! launchctl bootout "$DOMAIN/$LABEL"; then
        err "could not stop $LABEL; plist was not removed"
        exit 1
      fi
      removed=1
    fi
    if [[ -f "$PLIST" ]]; then
      if ! rm -f "$PLIST"; then
        err "could not remove $PLIST"
        # If bootout succeeded but deletion did not, put the still-present
        # configuration back into service rather than silently disabling it.
        (( removed )) && launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1
        exit 1
      fi
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
    # The verdict of the last real run, from the file stay_fresh.sh rewrites
    # for exactly this reader. One field per line there, so a line match is
    # all the parsing it takes; jq is not on a stock Mac.
    last_run="$LOG_DIR/last-run.json"
    if [[ -f "$last_run" ]]; then
      info "last run: $(json_field when "$last_run") — $(json_field headline "$last_run")"
      printf "  %s%s%s\n" "$C_DIM" "$(json_field detail "$last_run")" "$C_RESET"
    else
      info "no run recorded yet (last-run.json appears in $LOG_DIR after the first real run)"
    fi
    # A job that stopped firing is the failure a schedule hides best: launchd
    # still says loaded, the last verdict still reads OK, and the laptop was
    # simply asleep at 10:30 every Monday. Measured from the last time the
    # schedule itself ran (the stamp run-scheduled writes; last-run.json is
    # rewritten by manual runs too and would mask exactly this), or from the
    # install when it has never run. The plist says how often it should
    # fire; twice that with nothing is not running.
    stale=0
    since_s=""
    since_what=""
    if [[ -s "$LOG_DIR/last-scheduled" ]]; then
      IFS=$'\t' read -r sched_when sched_rc sched_note < "$LOG_DIR/last-scheduled"
      if [[ -n "${sched_note:-}" ]]; then
        info "last scheduled run: $sched_when (exit ${sched_rc:-?}, ${sched_note})"
      else
        info "last scheduled run: $sched_when (exit ${sched_rc:-?})"
      fi
      since_s="$(epoch_of "$sched_when")"
      since_what="the last scheduled run"
    elif [[ -f "$PLIST" ]]; then
      since_s="$(mtime_of "$PLIST")"
      since_what="the install"
      info "no scheduled run recorded yet"
    fi
    if [[ "$since_s" =~ ^[0-9]+$ ]]; then
      interval_days=1
      if grep -q '<key>Weekday</key>' "$PLIST" 2>/dev/null; then
        interval_days=7
      fi
      now_s="$(date +%s)"
      if (( now_s - since_s > 2 * interval_days * 86400 )); then
        if [[ "$since_what" == "the install" ]]; then
          # No stamp, so no evidence either way. Only run-scheduled writes
          # last-scheduled and only since this version, so an agent installed
          # before the upgrade has none however faithfully it has been firing
          # - and its plist mtime is the install date, which made a weekly job
          # installed a month ago report "the job is not running" and exit 1
          # while launchd was running it on time. A false death notice for a
          # working job is worse than waiting one more cycle for the real
          # signal, which the next firing writes.
          info "no run-scheduled stamp yet and the plist was installed $(( (now_s - since_s) / 86400 )) day(s) ago — if this agent predates the stamp it will appear at the next firing; check 'launchctl print' if it does not"
        else
          warn "no scheduled run in $(( (now_s - since_s) / 86400 )) day(s) since $since_what, and the schedule fires every $interval_days day(s) — the job is not running (check 'launchctl print' and the logs)"
          stale=1
        fi
      fi
    fi
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      ok "loaded in $DOMAIN"
      launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
        | grep -E '^\s+(state|last exit code|runs) ' || true
    else
      warn "not loaded in $DOMAIN"
      exit 1
    fi
    (( stale == 0 )) || exit 1
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

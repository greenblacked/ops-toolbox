#!/usr/bin/env bash
# stay_fresh_timer.sh
# Install, remove or inspect a systemd user timer that runs stay_fresh.sh on a
# schedule.
#
# The counterpart of macos-initial-setup/launchd/stay_fresh_agent.sh, and it
# inherits the same hard constraint: a timer has no terminal, so a sudo
# password prompt has nothing to prompt. The unit therefore always passes
# --yes --no-sudo, which means the steps needing root — package upgrade,
# autoremove and the journal vacuum — are skipped on every scheduled run. User
# caches, containers, flatpak and snap run normally. Run stay_fresh.sh by hand
# for the rest, or leave package updates to unattended-upgrades /
# dnf-automatic.timer, which hardening_audit.sh already checks for.
#
# Usage:
#   ./stay_fresh_timer.sh install [--weekday N|daily] [--hour N] [--minute N] [--dry-run]
#   ./stay_fresh_timer.sh uninstall
#   ./stay_fresh_timer.sh status
#   ./stay_fresh_timer.sh run-now
#
# Options:
#   --weekday N   0-7, Sunday is 0 or 7 (default 1, Monday). 'daily' for every day
#   --hour N      0-23 (default 10)
#   --minute N    0-59 (default 30)
#   --dry-run     Make the timer invoke stay_fresh.sh with --dry-run
#   --print-only  Print the units that would be installed and exit, writing
#                 nothing and enabling nothing
#   -h, --help    Show this help
#
# Exit codes:
#   0   success
#   1   command failed
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

# cd -P so a symlinked directory anywhere in the invocation path resolves to
# the real one: stay_fresh.sh is then looked up next to the actual file rather
# than beside the link.
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAY_FRESH="$(cd -P "$SCRIPT_DIR/.." && pwd)/stay_fresh.sh"

NAME="ops-toolbox-stay-fresh"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$UNIT_DIR/$NAME.service"
TIMER_FILE="$UNIT_DIR/$NAME.timer"

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

# Byte-identical to git/git_sync_default.sh:25-33 — see CONTRIBUTING.md for why
# this is copied rather than sourced from a shared library.
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

set_weekday() {
  if [[ "$1" == "daily" ]]; then
    DAILY=1
  elif [[ "$1" =~ ^[0-7]$ ]]; then
    WEEKDAY="$1"
    DAILY=0
  else
    err "--weekday must be 0-7 or 'daily'"
    exit 3
  fi
}

set_hour() {
  [[ "$1" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { err "--hour must be 0-23"; exit 3; }
  HOUR="$1"
}

set_minute() {
  [[ "$1" =~ ^([0-9]|[1-5][0-9])$ ]] || { err "--minute must be 0-59"; exit 3; }
  MINUTE="$1"
}

CMD=""
WEEKDAY=1
HOUR=10
MINUTE=30
DAILY=0
TIMER_DRY_RUN=0
PRINT_ONLY=0

# --help is handled here, before any preflight check, so it keeps working on a
# machine this script would otherwise refuse to run on.
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    install|uninstall|status|run-now)
      if [[ -n "$CMD" ]]; then err "only one command at a time"; exit 3; fi
      CMD="$1"
      ;;
    --weekday)   require_value "$1" "${2:-}"; set_weekday "$2"; shift ;;
    --weekday=*) require_value "--weekday" "${1#*=}"; set_weekday "${1#*=}" ;;
    --hour)      require_value "$1" "${2:-}"; set_hour "$2"; shift ;;
    --hour=*)    require_value "--hour" "${1#*=}"; set_hour "${1#*=}" ;;
    --minute)    require_value "$1" "${2:-}"; set_minute "$2"; shift ;;
    --minute=*)  require_value "--minute" "${1#*=}"; set_minute "${1#*=}" ;;
    --dry-run)    TIMER_DRY_RUN=1 ;;
    --print-only) PRINT_ONLY=1 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

[[ -n "$CMD" ]] || { usage; exit 3; }

if [[ "$(uname -s)" != "Linux" ]]; then
  err "systemd timers are Linux-only"
  exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }

# systemctl is only required by the paths that actually talk to systemd, so
# --print-only still works on a box that has none — which is also how the
# generated units get checked in a container.
require_user_manager() {
  if ! have systemctl; then
    err "systemctl not found — this needs systemd"
    exit 2
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    err "no systemd user manager for $(id -un) (systemctl --user cannot connect)"
    info "on a headless box: loginctl enable-linger $(id -un)"
    exit 2
  fi
}

case "$CMD" in
  install)
    if [[ ! -x "$STAY_FRESH" ]]; then
      err "stay_fresh.sh not found or not executable at $STAY_FRESH"
      exit 2
    fi

    exec_args="--yes --no-sudo"
    if (( TIMER_DRY_RUN )); then
      exec_args="$exec_args --dry-run"
    fi

    at="$(printf '%02d:%02d' "$HOUR" "$MINUTE")"
    if (( DAILY )); then
      on_calendar="*-*-* $at:00"
      when="daily at $at"
    else
      case "$WEEKDAY" in
        0|7) day="Sun" ;;
        1)   day="Mon" ;;
        2)   day="Tue" ;;
        3)   day="Wed" ;;
        4)   day="Thu" ;;
        5)   day="Fri" ;;
        6)   day="Sat" ;;
      esac
      on_calendar="$day *-*-* $at:00"
      when="$day at $at"
    fi

    service_body="$(cat <<UNIT_EOF
[Unit]
Description=Recurring maintenance for this machine (stay_fresh.sh)

[Service]
Type=oneshot
ExecStart=/bin/bash "$STAY_FRESH" $exec_args
# A oneshot service is killed after DefaultTimeoutStartSec, which is 90s on a
# stock install — long enough to abort a real maintenance run halfway through.
TimeoutStartSec=1h
# Never let housekeeping compete with interactive work.
Nice=10
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
UNIT_EOF
)"

    timer_body="$(cat <<UNIT_EOF
[Unit]
Description=Scheduled maintenance for this machine ($when)

[Timer]
Unit=$NAME.service
OnCalendar=$on_calendar
# Housekeeping missed because the machine was off should still happen, but
# only once after boot, not once per missed interval.
Persistent=true

[Install]
WantedBy=timers.target
UNIT_EOF
)"

    # Validate before writing, so a malformed unit never lands in the user unit
    # directory where systemd would keep complaining about it. --user is not
    # passed: it makes verify open the user runtime directory, which fails
    # outright where there is no login session, and the units here reference
    # nothing that only exists in the user manager.
    if have systemd-analyze; then
      lint_dir="$(mktemp -d)"
      printf '%s\n' "$service_body" >"$lint_dir/$NAME.service"
      printf '%s\n' "$timer_body"   >"$lint_dir/$NAME.timer"
      if ! systemd-analyze verify "$lint_dir/$NAME.service" "$lint_dir/$NAME.timer" >/dev/null 2>&1; then
        err "generated units are malformed — refusing to install"
        systemd-analyze verify "$lint_dir/$NAME.service" "$lint_dir/$NAME.timer" 2>&1 | sed 's/^/      /' >&2
        rm -rf "$lint_dir"
        exit 1
      fi
      rm -rf "$lint_dir"
    else
      warn "systemd-analyze not present — units are installed unverified"
    fi

    if (( PRINT_ONLY )); then
      printf '# %s\n%s\n\n# %s\n%s\n' \
        "$SERVICE_FILE" "$service_body" "$TIMER_FILE" "$timer_body"
      exit 0
    fi

    require_user_manager

    mkdir -p "$UNIT_DIR"
    printf '%s\n' "$service_body" >"$SERVICE_FILE"
    printf '%s\n' "$timer_body"   >"$TIMER_FILE"

    if ! systemctl --user daemon-reload; then
      err "systemctl --user daemon-reload failed"
      exit 1
    fi
    # --now starts the timer as well as enabling it, so the first run does not
    # wait for a reboot or a re-login.
    if ! systemctl --user enable --now "$NAME.timer"; then
      err "could not enable $NAME.timer"
      info "inspect with: systemctl --user status $NAME.timer"
      exit 1
    fi

    ok "installed $NAME — runs $when"
    info "as you, without sudo: package upgrades and the journal vacuum are"
    info "skipped. Run stay_fresh.sh by hand for those."
    if have loginctl && ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
      warn "lingering is off, so the timer only runs while you are logged in:"
      warn "  loginctl enable-linger $(id -un)"
    fi
    printf "  %slogs: journalctl --user -u %s%s\n" "$C_DIM" "$NAME.service" "$C_RESET"
    ;;

  uninstall)
    removed=0
    # Files are removed even when there is no user manager to disable the unit
    # in; refusing to clean up because systemd is unreachable would leave the
    # timer to come back on the next login.
    reachable=0
    if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
      reachable=1
    fi
    if (( reachable )); then
      if systemctl --user is-enabled "$NAME.timer" >/dev/null 2>&1 ||
         systemctl --user is-active "$NAME.timer" >/dev/null 2>&1; then
        systemctl --user disable --now "$NAME.timer" >/dev/null 2>&1 || true
        removed=1
      fi
    fi
    for f in "$TIMER_FILE" "$SERVICE_FILE"; do
      if [[ -f "$f" ]]; then
        rm -f "$f"
        removed=1
      fi
    done
    if (( reachable )); then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    if (( removed )); then
      ok "removed $NAME"
    else
      info "$NAME was not installed"
    fi
    ;;

  status)
    rc=0
    if [[ -f "$SERVICE_FILE" && -f "$TIMER_FILE" ]]; then
      ok "units present: $UNIT_DIR/$NAME.{service,timer}"
    else
      warn "no units at $UNIT_DIR/$NAME.{service,timer}"
      rc=1
    fi
    require_user_manager
    if systemctl --user is-enabled "$NAME.timer" >/dev/null 2>&1; then
      ok "timer enabled"
    else
      warn "timer not enabled"
      rc=1
    fi
    if systemctl --user is-active "$NAME.timer" >/dev/null 2>&1; then
      ok "timer active"
      systemctl --user list-timers --all --no-pager "$NAME.timer" 2>/dev/null \
        | sed 's/^/      /'
    else
      warn "timer not active"
      rc=1
    fi
    systemctl --user show "$NAME.service" \
      -p ActiveState -p Result -p ExecMainStatus 2>/dev/null | sed 's/^/      /'
    exit "$rc"
    ;;

  run-now)
    require_user_manager
    if [[ ! -f "$SERVICE_FILE" ]]; then
      err "$NAME is not installed — install it first"
      exit 1
    fi
    # --no-block returns immediately; a oneshot start would otherwise sit on
    # the terminal for the length of a whole maintenance run.
    if systemctl --user start --no-block "$NAME.service"; then
      ok "triggered $NAME.service"
      info "follow with: journalctl --user -u $NAME.service -f"
    else
      err "could not start $NAME.service"
      exit 1
    fi
    ;;
esac

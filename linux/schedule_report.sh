#!/usr/bin/env bash
# schedule_report.sh
# Read-only inventory of what is scheduled to run on a Linux machine.
#
# The question this answers is "what will fire when I am not looking?":
# systemd timers (user and system), the user crontab, and the distro cron
# directories. It changes nothing. A missing scheduler is a skip, not a
# failure — a container has none of these, and that must not turn the report
# red.
#
# Exit codes:
#   0   the report ran (warnings do not change the exit code)
#   2   preflight failed (not Linux)
#   3   bad CLI arguments
set -u
set -o pipefail

QUIET=0

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

OK_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

ok()   { OK_COUNT=$((OK_COUNT + 1)); (( QUIET )) || printf "  %s[ ok ]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
info() { (( QUIET )) || printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"
  return 0
}
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
schedule_report.sh - read-only inventory of scheduled jobs on a Linux machine

Lists systemd timers, the user crontab, and distro cron directories. Changes
nothing. A missing scheduler is reported, not treated as a failure.

Usage:
  $(basename "$0") [--quiet]

Options:
  --quiet       Print only warnings
  --help, -h    Show this help

Sections: systemd-user, systemd-system, crontab, cron.d

Exit codes: 0 report printed, 2 not Linux, 3 usage
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --quiet)   QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }
have()  { command -v "$1" >/dev/null 2>&1; }

list_timers() {
  local scope="$1"
  shift
  local out rc
  out="$("$@" --no-legend --no-pager 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then
    skip "systemctl ${scope} list-timers exited $rc"
    return 0
  fi
  local count
  count="$(printf '%s\n' "$out" | awk 'NF { c++ } END { print c+0 }')"
  if (( count == 0 )); then
    info "no ${scope} timers"
    return 0
  fi
  ok "$count ${scope} timer(s)"
  printf '%s\n' "$out" | awk 'NF { print "           " $0 }'
}

# --- systemd user ----------------------------------------------------------
group "systemd-user"
if have systemctl && [[ -d /run/systemd/system || -d /run/user/$(id -u)/systemd ]]; then
  list_timers "user" systemctl --user list-timers
  # A user timer that is installed but never fires is almost always linger.
  if have loginctl; then
    linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
    case "$linger" in
      yes) ok "lingering is on; user timers fire without a session" ;;
      no)
        warn "lingering is off; user timers only fire while you are logged in" \
          "loginctl enable-linger $(id -un)"
        ;;
      *) skip "could not read lingering (no logind?)" ;;
    esac
  else
    skip "loginctl not installed; lingering not checked"
  fi
else
  skip "no systemd user manager"
fi

# --- systemd system --------------------------------------------------------
group "systemd-system"
if have systemctl && [[ -d /run/systemd/system ]]; then
  list_timers "system" systemctl list-timers
else
  skip "no systemd system manager"
fi

# --- user crontab ----------------------------------------------------------
group "crontab"
if have crontab; then
  cron_out="$(crontab -l 2>/dev/null)"; cron_rc=$?
  if (( cron_rc != 0 )); then
    info "no user crontab"
  else
    # Comments and blank lines are not jobs.
    job_count="$(printf '%s\n' "$cron_out" | grep -cE '^[[:space:]]*[^#[:space:]]' || true)"
    if (( job_count == 0 )); then
      info "user crontab is empty"
    else
      ok "$job_count user crontab job(s)"
      printf '%s\n' "$cron_out" | grep -E '^[[:space:]]*[^#[:space:]]' | sed 's/^/           /'
    fi
  fi
else
  skip "crontab(1) is not installed"
fi

# --- /etc/cron.d and the run-parts directories -----------------------------
group "cron.d"
cron_files=0
if [[ -d /etc/cron.d ]]; then
  while IFS= read -r -d '' f; do
    [[ -n "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in
      .placeholder|*.dpkg-*|*.rpmsave|*.rpmnew) continue ;;
    esac
    cron_files=$((cron_files + 1))
    info "/etc/cron.d/$base"
  done < <(find /etc/cron.d -maxdepth 1 -type f -print0 2>/dev/null)
fi
for period in hourly daily weekly monthly; do
  dir="/etc/cron.$period"
  [[ -d "$dir" ]] || continue
  count="$(find "$dir" -maxdepth 1 -type f ! -name '.placeholder' 2>/dev/null | grep -c . || true)"
  if (( count > 0 )); then
    info "$count file(s) in $dir"
    cron_files=$((cron_files + count))
  fi
done
if (( cron_files == 0 )); then
  info "no distro cron drop-ins found"
else
  ok "$cron_files distro cron file(s)"
fi

# --- summary ---------------------------------------------------------------
printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s ok%s  %s%s warn%s  %s%s skip%s\n" \
  "$C_GREEN" "$OK_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"
info "the stay_fresh timer is installed with: ./systemd/stay_fresh_timer.sh status"
exit 0

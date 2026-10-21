#!/usr/bin/env bash
# schedule_report.sh
# Read-only inventory of what is scheduled to run on a Mac: launchd jobs
# (this user's agents, the /Library agents and daemons), the user crontab and
# queued at jobs, with each launchd schedule decoded.
#
# The question this answers is "what will fire when I am not looking?". A
# developer Mac collects launchd jobs from installers (VPN clients, sync
# agents, Docker and OrbStack helpers), old cron lines and forgotten at jobs.
# stay_fresh.sh only reports plists whose program is gone; this lists every
# job with its schedule in words (StartCalendarInterval, StartInterval,
# RunAtLoad, KeepAlive, WatchPaths) and flags the two findings that matter:
# a program that no longer exists, and a plist or program that someone other
# than its owner can write, which is how a scheduled job becomes somebody
# else's persistence.
#
# Strictly read-only. It never loads, unloads or edits a job: plutil is only
# asked to print a plist as XML, and the one launchctl call (print, behind
# --loaded) changes nothing. Removal stays with stay_fresh.sh's explicit
# --prune-orphan-agents. Plist and cron text is data, sanitised before it is
# printed and never evaluated. The macOS half of linux/schedule_report.sh.
#
# Exit codes:
#   0   the report ran (warnings do not change the exit code)
#   1   --strict and at least one warning
#   2   preflight failed (not macOS)
#   3   bad CLI arguments
set -u
set -o pipefail

QUIET=0
STRICT=0
INCLUDE_APPLE=0
LOADED=0
LIST_SECTIONS=0
ONLY=""
ROOT="/"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

OK_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0
JOB_COUNT=0

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

ALL_SECTIONS="launchd-user launchd-agents launchd-daemons crontab at"

usage() {
  cat <<EOF
schedule_report.sh - read-only inventory of scheduled jobs on a Mac

Lists launchd agents and daemons with their schedules decoded, the user
crontab and queued at jobs. Flags jobs whose program is missing and plists
or programs that group or other can write. Changes nothing.

Usage:
  $(basename "$0") [--only SECTIONS] [--include-apple] [--loaded] [--root DIR] [--strict] [--quiet]

Options:
  --only SECTIONS   Comma-separated subset (see --list-sections)
  --list-sections   Print the section ids and exit
  --include-apple   Also list com.apple.* jobs (hidden and counted by default)
  --loaded          Mark each user agent loaded or not (one launchctl print
                    per job)
  --root DIR        Where /Library is looked up (default: /)
  --strict          Exit 1 when the report has any warning
  --quiet           Print only warnings and the summary
  --help, -h        Show this help

Sections:
  launchd-user      ~/Library/LaunchAgents
  launchd-agents    /Library/LaunchAgents
  launchd-daemons   /Library/LaunchDaemons
  crontab           crontab -l
  at                atq

Exit codes: 0 report printed, 1 --strict and a warning, 2 not macOS, 3 usage
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
    --only)          require_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --only=*)        ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --root)          require_value "$1" "${2:-}"; ROOT="$2"; shift ;;
    --root=*)        ROOT="${1#*=}"; require_value "--root" "$ROOT" ;;
    --list-sections) LIST_SECTIONS=1 ;;
    --include-apple) INCLUDE_APPLE=1 ;;
    --loaded)        LOADED=1 ;;
    --strict)        STRICT=1 ;;
    --quiet)         QUIET=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( LIST_SECTIONS )); then
  # shellcheck disable=SC2086  # the id list is split on purpose
  printf '%s\n' $ALL_SECTIONS
  exit 0
fi

if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a requested <<< "$ONLY"
  for s in ${requested[@]+"${requested[@]}"}; do
    case " $ALL_SECTIONS " in
      *" $s "*) ;;
      *) err "unknown section: $s (see --list-sections)"; exit 3 ;;
    esac
  done
fi

if [[ ! -d "$ROOT" ]]; then
  err "--root is not a directory: $ROOT"
  exit 3
fi

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
have()  { command -v "$1" >/dev/null 2>&1; }

# Plist and cron text is data: control characters are stripped before it is
# printed.
clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# Permission bits as octal, following a symlink to what it points at. BSD stat
# answers on a Mac, GNU stat in the Linux test container; GNU `stat -f` means
# --file-system and prints junk while failing, so only a mode is accepted.
file_mode() {
  local m
  m="$(stat -L -f '%Lp' "$1" 2>/dev/null)"
  if [[ ! "$m" =~ ^[0-7]{3,4}$ ]]; then
    m="$(stat -L -c '%a' "$1" 2>/dev/null)"
  fi
  [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
  printf '%s\n' "$m"
}

# Writable by its group or by everyone?
foreign_writable() {
  local m
  m="$(file_mode "$1")" || return 1
  (( (8#$m & 18) != 0 ))
}

# Reads the XML that `plutil -convert xml1 -o -` prints and emits one
# "field value" line per fact the report needs. The whole document is read
# first and split on "<", so a value that spans lines (or several tags on one
# line) parses the same. Only the top-level dict is read for fields;
# StartCalendarInterval may be one dict or an array of them, emitted as
# "cal MONTH DAY WEEKDAY HOUR MINUTE" with "-" for a key that is absent.
# shellcheck disable=SC2016  # an awk program, not shell
PLIST_AWK='
function decode(v) {
  gsub(/[\r\n\t]/, " ", v)
  gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v)
  gsub(/&quot;/, "\"", v); gsub(/&apos;/, "\047", v)
  gsub(/&amp;/, "\\&", v)
  return v
}
function cal_start() { c_mo = "-"; c_dy = "-"; c_wd = "-"; c_hr = "-"; c_mi = "-" }
function cal_end() { cals = cals "cal " c_mo " " c_dy " " c_wd " " c_hr " " c_mi "\n" }
{ buf = buf $0 "\n" }
END {
  n = split(buf, part, "<")
  depth = 0; arrays = 0; topkey = ""; subkey = ""
  for (i = 2; i <= n; i++) {
    p = part[i]
    j = index(p, ">")
    if (j == 0) continue
    tag = substr(p, 1, j - 1)
    text = substr(p, j + 1)
    if (tag == "dict") {
      depth++
      if (depth == 2 && topkey == "StartCalendarInterval") cal_start()
      if (depth == 2 && topkey == "KeepAlive") keepalive = "cond"
    } else if (tag == "/dict") {
      if (depth == 2 && topkey == "StartCalendarInterval") cal_end()
      depth--
    } else if (tag == "array") {
      arrays++
    } else if (tag == "/array") {
      arrays--
    } else if (tag == "key") {
      if (depth == 1) topkey = text
      else if (depth == 2) subkey = text
    } else if (tag == "string") {
      v = decode(text)
      if (depth == 1 && topkey == "Label" && arrays == 0) label = v
      if (depth == 1 && topkey == "Program" && arrays == 0) program = v
      if (depth == 1 && topkey == "ProgramArguments" && argv0 == "" && v != "") argv0 = v
      if (depth == 1 && (topkey == "WatchPaths" || topkey == "QueueDirectories")) watch = 1
    } else if (tag == "integer") {
      v = text; gsub(/[^0-9]/, "", v)
      if (v == "") continue
      if (depth == 1 && topkey == "StartInterval") interval = v
      if (depth == 1 && topkey == "ThrottleInterval") throttle = v
      if (depth == 2 && topkey == "StartCalendarInterval") {
        if (subkey == "Month") c_mo = v
        else if (subkey == "Day") c_dy = v
        else if (subkey == "Weekday") c_wd = v
        else if (subkey == "Hour") c_hr = v
        else if (subkey == "Minute") c_mi = v
      }
    } else if (tag == "true/") {
      if (depth == 1 && topkey == "RunAtLoad") runatload = 1
      if (depth == 1 && topkey == "KeepAlive") keepalive = 1
      if (depth == 1 && topkey == "Disabled") disabled = 1
    }
  }
  if (label == "" && program == "" && argv0 == "") exit
  if (label != "") print "label " label
  if (program == "") program = argv0
  if (program != "") print "program " program
  if (runatload) print "runatload 1"
  if (keepalive != "") print "keepalive " keepalive
  if (disabled) print "disabled 1"
  if (interval != "") print "interval " interval
  if (throttle != "") print "throttle " throttle
  if (watch) print "watch 1"
  printf "%s", cals
}'

two() { printf '%02d' "$((10#$1))"; }

day_name() {
  case "$((10#$1))" in
    0|7) printf 'Sun' ;; 1) printf 'Mon' ;; 2) printf 'Tue' ;; 3) printf 'Wed' ;;
    4) printf 'Thu' ;; 5) printf 'Fri' ;; 6) printf 'Sat' ;;
    *) printf 'weekday %s' "$1" ;;
  esac
}

month_name() {
  case "$((10#$1))" in
    1) printf 'Jan' ;; 2) printf 'Feb' ;; 3) printf 'Mar' ;; 4) printf 'Apr' ;;
    5) printf 'May' ;; 6) printf 'Jun' ;; 7) printf 'Jul' ;; 8) printf 'Aug' ;;
    9) printf 'Sep' ;; 10) printf 'Oct' ;; 11) printf 'Nov' ;; 12) printf 'Dec' ;;
    *) printf 'month %s' "$1" ;;
  esac
}

# One StartCalendarInterval entry in words. A key launchd leaves out is a
# wildcard, shown as **: an entry with only Minute fires every hour.
render_cal() {
  local mo="$1" dy="$2" wd="$3" hr="$4" mi="$5" t
  if [[ "$hr" == "-" ]]; then t="**"; else t="$(two "$hr")"; fi
  if [[ "$mi" == "-" ]]; then t="$t:**"; else t="$t:$(two "$mi")"; fi
  if [[ "$wd" != "-" ]]; then
    printf '%s %s' "$(day_name "$wd")" "$t"
  elif [[ "$dy" != "-" && "$mo" != "-" ]]; then
    printf '%s %s %s' "$(month_name "$mo")" "$((10#$dy))" "$t"
  elif [[ "$dy" != "-" ]]; then
    printf 'monthly day %s %s' "$((10#$dy))" "$t"
  elif [[ "$hr" != "-" ]]; then
    printf 'daily %s' "$t"
  elif [[ "$mi" != "-" ]]; then
    printf 'hourly at :%s' "$(two "$mi")"
  else
    printf 'every minute'
  fi
}

# report_dir SECTION DIR SCOPE (user|agents|daemons)
report_dir() {
  local id="$1" dir="$2" scope="$3"
  local plist parsed field value label program runatload keepalive disabled
  local interval throttle watch sched n=0 hidden=0 row base uid=""
  group "$id"
  if [[ ! -d "$dir" ]]; then
    skip "$dir does not exist"
    return 0
  fi
  if (( LOADED )) && [[ "$scope" == "user" ]]; then
    uid="$(id -u 2>/dev/null)"
  fi
  for plist in "$dir"/*.plist; do
    [[ -f "$plist" ]] || continue
    base="$(basename "$plist" .plist)"
    if [[ ! -r "$plist" ]]; then
      skip "$(clean "$plist") is not readable"
      continue
    fi
    parsed="$(plutil -convert xml1 -o - "$plist" 2>/dev/null | awk "$PLIST_AWK")"
    if [[ -z "$parsed" ]]; then
      skip "could not read $(clean "$plist")"
      continue
    fi
    label=""; program=""; runatload=0; keepalive=""; disabled=0
    interval=""; throttle=""; watch=0; sched=""
    while read -r field value; do
      case "$field" in
        label)     label="$(clean "$value")" ;;
        program)   program="$(clean "$value")" ;;
        runatload) runatload=1 ;;
        keepalive) keepalive="$value" ;;
        disabled)  disabled=1 ;;
        interval)  interval="$value" ;;
        throttle)  throttle="$value" ;;
        watch)     watch=1 ;;
        cal)
          # shellcheck disable=SC2086  # five space-separated fields
          sched="${sched:+$sched, }$(render_cal $value)"
          ;;
      esac
    done <<< "$parsed"
    [[ -n "$label" ]] || label="$(clean "$base")"
    case "$label" in
      com.apple.*)
        if (( INCLUDE_APPLE == 0 )); then
          hidden=$((hidden + 1))
          continue
        fi
        ;;
    esac
    n=$((n + 1))
    JOB_COUNT=$((JOB_COUNT + 1))
    [[ "$interval" =~ ^[0-9]+$ ]] && sched="${sched:+$sched, }every ${interval}s"
    if [[ "$keepalive" == "1" ]]; then
      sched="${sched:+$sched, }keep-alive"
    elif [[ "$keepalive" == "cond" ]]; then
      sched="${sched:+$sched, }kept alive on conditions"
    fi
    if (( runatload )) && [[ "$keepalive" != "1" ]]; then
      sched="${sched:+$sched, }at load"
    fi
    (( watch )) && sched="${sched:+$sched, }on path change"
    [[ -n "$sched" ]] || sched="unscheduled"

    row="$label   $sched   ${program:-(no program)}"
    (( disabled )) && row="$row   (Disabled in the plist)"
    if [[ -n "$uid" ]] && [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
      if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        row="$row   [loaded]"
      else
        row="$row   [not loaded]"
      fi
    fi
    info "$row"

    if [[ "$program" == /* && ! -e "$program" ]]; then
      case "$scope" in
        user)
          warn "$label runs $program, which no longer exists" \
               "remove the orphan with: stay_fresh.sh --prune-orphan-agents (or delete $(clean "$plist"))" ;;
        agents)
          # shellcheck disable=SC2016  # $(id -u) is for the reader to run
          warn "$label runs $program, which no longer exists" \
               'launchctl bootout gui/$(id -u)/'"$label, then sudo rm $(clean "$plist")" ;;
        *)
          warn "$label runs $program, which no longer exists" \
               "sudo launchctl bootout system/$label, then sudo rm $(clean "$plist")" ;;
      esac
    elif [[ "$program" == /* ]] && foreign_writable "$program"; then
      warn "$label runs $program, which its group or every user can write" "chmod go-w $program"
    fi
    if foreign_writable "$plist"; then
      warn "$(clean "$plist") can be written by its group or every user" "chmod go-w $(clean "$plist")"
    fi
    if [[ "$keepalive" == "1" && -z "$throttle" ]]; then
      info "$label restarts whenever it exits (launchd's default 10s throttle)"
    fi
  done
  if (( n == 0 && hidden == 0 )); then
    skip "no plists in $dir"
  fi
  if (( hidden > 0 )); then
    info "$hidden com.apple.* job(s) not shown (--include-apple lists them)"
  fi
  return 0
}

if want launchd-user; then
  if [[ -n "${HOME:-}" ]]; then
    report_dir launchd-user "$HOME/Library/LaunchAgents" user
  else
    group "launchd-user"
    skip "HOME is not set"
  fi
fi

ROOT_DIR="${ROOT%/}"
want launchd-agents && report_dir launchd-agents "$ROOT_DIR/Library/LaunchAgents" agents
want launchd-daemons && report_dir launchd-daemons "$ROOT_DIR/Library/LaunchDaemons" daemons

# --- crontab ---------------------------------------------------------------
if want crontab; then
  group "crontab"
  if ! have crontab; then
    skip "crontab not found"
  else
    if cron_out="$(crontab -l 2>&1)"; then
      entries=0
      while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
          ''|\#*) continue ;;
        esac
        # NAME=value lines set the environment for the jobs; they are not jobs.
        [[ "$trimmed" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]] && continue
        entries=$((entries + 1))
        (( entries <= 20 )) && info "  $(clean "$trimmed")"
      done <<< "$cron_out"
      if (( entries == 0 )); then
        ok "the crontab has no entries"
      else
        word="entries"
        (( entries == 1 )) && word="entry"
        info "$entries cron $word"
        (( entries > 20 )) && info "  ... and $((entries - 20)) more: crontab -l"
        info "cron on macOS needs Full Disk Access to touch most user data"
      fi
    else
      case "$cron_out" in
        *"no crontab"*) skip "no crontab for this user" ;;
        *)              skip "crontab -l failed: $(clean "$(head -n 1 <<< "$cron_out")")" ;;
      esac
    fi
  fi
fi

# --- at --------------------------------------------------------------------
if want at; then
  group "at"
  if ! have atq; then
    skip "atq not found"
  elif ! at_out="$(atq 2>/dev/null)"; then
    skip "atq could not list jobs"
  elif [[ -z "$at_out" ]]; then
    ok "no queued at jobs"
  else
    at_n=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      at_n=$((at_n + 1))
      (( at_n <= 20 )) && info "  $(clean "$line")"
    done <<< "$at_out"
    info "$at_n queued at job(s); they run only while com.apple.atrun is enabled"
  fi
fi

printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s job(s)%s  %s%s warn%s  %s%s skip%s\n" \
  "$C_BLUE" "$JOB_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

if (( STRICT )) && (( WARN_COUNT > 0 )); then
  exit 1
fi
exit 0

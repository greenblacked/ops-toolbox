#!/usr/bin/env bash
# print_schedulers.sh
# Print the `/system scheduler add` commands for the RouterOS scripts in this
# folder, ready to review and paste into a router terminal.
#
# Installing a script is the easy half. Scheduling it is where this package goes
# quiet: a script that was never scheduled looks exactly like a script that has
# nothing to report, and the mistake is invisible until the month you needed the
# backup. Twenty scripts here are meant to run unattended and only eight of them
# have an interval written down in README.md.
#
# Usage:
#   ./print_schedulers.sh
#   ./print_schedulers.sh --include-notify-boot > schedulers.rsc
#
# No router is contacted and nothing is written — this only prints text.
#
# The intervals come from README.md's "Suggested schedules" table, and for the
# twelve scripts that table omits, from each script's own header comment — which
# is where its author already wrote one down. The deliberately manual ones are
# never printed: tg_send (a library, called by the others), detect_internet,
# reboot-and-flush, firewall_drift_baseline and change_WIFI_pw.

set -euo pipefail

# --- output ----------------------------------------------------------------
# Only the commentary is coloured, and only for a terminal, so redirecting to a
# file gives clean RouterOS input with no escape sequences in it.
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_DIM=''
fi

# Commentary is emitted as `#` lines rather than as [info] output, so the whole
# of stdout stays pasteable: RouterOS treats them as comments and ignores them.
comment() {
  if [[ -z "$*" ]]; then
    printf "%s#%s\n" "$C_DIM" "$C_RESET"
  else
    printf "%s# %s%s\n" "$C_DIM" "$*" "$C_RESET"
  fi
}

# --- defaults --------------------------------------------------------------
# `policy` is needed to read another script's source through :parse, `sensitive`
# for the secrets, `ftp` for /tool fetch. This is the same set the scripts
# themselves are installed with, per README.md.
DEFAULT_POLICY="read,write,policy,test,sensitive,ftp"
POLICY="$DEFAULT_POLICY"
DRY_RUN=0
NOTIFY_BOOT=0

usage() {
  cat <<EOF
$(basename "$0") - print the RouterOS scheduler entries for the scripts here

Usage:
  $(basename "$0") [--policy LIST] [--include-notify-boot] [--dry-run]

Prints one \`/system scheduler add\` command per script that is meant to run
unattended, using the intervals from README.md's suggested-schedules table and,
for the scripts that table omits, the one in each script's own header. No router
is contacted: read the output, then paste it into a RouterOS terminal.

Options:
  --policy LIST          Scheduler policy set
                         (default: $DEFAULT_POLICY)
  --include-notify-boot  Also print the start-time=startup "back online" entry
  --dry-run              Accepted for symmetry with the other scripts here. This
                         one only ever prints, so the flag adds a closing note
                         and changes nothing else.
  -h, --help             Show this help

Exit codes: 0 success, 3 usage
EOF
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

# --- arguments -------------------------------------------------------------
while (( $# > 0 )); do
  case "$1" in
    -h|--help)             usage; exit 0 ;;
    --dry-run)             DRY_RUN=1 ;;
    --include-notify-boot) NOTIFY_BOOT=1 ;;
    --policy)              require_value "$1" "${2:-}"; shift; POLICY="$1" ;;
    --policy=*)            POLICY="${1#*=}"; require_value "--policy" "$POLICY" ;;
    -*)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 3
      ;;
    *)
      printf 'unexpected argument: %s\n\n' "$1" >&2
      usage >&2
      exit 3
      ;;
  esac
  shift
done

# A policy list with a stray shell metacharacter or an uppercase word in it
# would be pasted into a router and rejected there, several steps away from the
# typo. Reject it here instead.
case "$POLICY" in
  ''|*[!a-z,]*)
    printf -- '--policy takes a comma-separated RouterOS policy list, got: %s\n' "$POLICY" >&2
    exit 3
    ;;
esac

# --- emitting --------------------------------------------------------------
# One entry per line of the tables below: `name interval [start-time]`.
emit() {
  local name="$1" interval="$2" start="${3:-}"
  local when="interval=$interval"
  if [[ -n "$start" ]]; then
    when="start-time=$start interval=$interval"
  fi
  printf '%s\n' \
    "/system scheduler add name=$name $when \\" \
    "    policy=$POLICY \\" \
    "    on-event=\"/system script run $name\""
  printf '\n'
}

emit_table() {
  local name interval start
  while read -r name interval start; do
    case "$name" in ''|\#*) continue ;; esac
    emit "$name" "$interval" "$start"
  done
}

# --- header ----------------------------------------------------------------
comment "RouterOS scheduler entries for the scripts in mikrotik/."
comment "Generated by print_schedulers.sh. Review before pasting."
comment
comment "Each script must already exist in /system script under exactly the name"
comment "used below (System > Scripts, or /system script print). A scheduler whose"
comment "on-event names a script that is not there fails at every run, and the only"
comment "trace is a line in /log."
comment
comment "Adding a name that already exists fails with \"already have such entry\"."
comment "To replace one:  /system scheduler remove [find name=\"backup\"]"
comment

comment "--- intervals from README.md's suggested-schedules table ---"
comment
comment "The daily entries carry an explicit start-time. On its own, interval=1d"
comment "anchors to the moment the entry was created, so a router rebuilt at 19:40"
comment "would take its nightly backup at 19:40. The times are spread out so the"
comment "daily jobs do not all land in the same minute."
comment
emit_table <<'EOF'
backup               1d   04:00:00
health_check         5m
update_check         1d   04:20:00
wan_failover_notify  1m
dhcp_lease_watch     5m
firewall_drift       15m
mac_allowlist_dhcp   5m
rogue_dns_check      10m
EOF

comment "--- not in that table; taken from each script's own header comment ---"
comment
comment "Eight of these name an interval outright and it is used as written."
comment "netwatch_notify and wireguard_watch each ask for \"1-5m\", where the slower"
comment "end is the safer default to paste. The last two are the ones whose headers"
comment "describe rather than specify: backup_file_cleanup says \"weekly or after"
comment "backup jobs\", so it runs 40 minutes after backup does, and cert_expiry_watch"
comment "asks for at most once a day."
comment
emit_table <<'EOF'
wan_link_flap_notify   1m
netwatch_notify        5m
latency_monitor        5m
bandwidth_spike        5m
brute_force_block      1m
vpn_health             2m
wireguard_watch        5m
wireless_client_watch  1m
ddns_update            5m
traffic_quota          1h
backup_file_cleanup    1d   04:40:00
cert_expiry_watch      1d   05:00:00
EOF

# --- reboot notification ---------------------------------------------------
if (( NOTIFY_BOOT == 1 )); then
  comment "--- reboot notification (inline; needs no script of its own) ---"
  comment
  comment "reboot-and-flush deliberately sends nothing before rebooting: the message"
  comment "would race the reboot. This fires once the router is back up, after a 20s"
  comment "delay that gives DHCP, WAN and DNS time to come up first."
  comment
  # Written with printf and single quotes so the RouterOS-level escapes below
  # (\$S, \", \\F0) reach the router exactly as they appear here. Not expanding
  # them is the point, and a trailing backslash inside the quotes is a RouterOS
  # line continuation rather than a shell one.
  # shellcheck disable=SC1003,SC2016
  printf '%s\n' \
    '/system scheduler add name=notify-boot start-time=startup \' \
    "    policy=$POLICY \\" \
    '    on-event=":delay 20s; :local S [:parse [/system script get tg_send source]]; \$S MessageText=(\"\\F0\\9F\\9F\\A2 <b>\" . [/system identity get name] . \":</b> back online\");"'
  printf '\n'
else
  comment "Pass --include-notify-boot to also print the start-time=startup"
  comment "\"back online\" entry described in README.md."
  comment
fi

if (( DRY_RUN == 1 )); then
  comment "--dry-run: nothing above has run. It is text; paste it when you are ready."
fi

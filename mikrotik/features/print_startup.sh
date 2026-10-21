#!/usr/bin/env bash
# Print the startup script that sets the RouterOS globals these scripts read.
#
# Every setting in this package is a :global, and a :global lives in memory: a
# reboot clears all of them. The way to keep them is one startup script that
# declares them again, run by a start-time=startup scheduler entry. Without it
# the token you set by hand works until the next reboot, and then every alert
# is dropped. That script used to be written by hand from notes scattered
# across README.md; this prints a reviewed one, the companion of
# print_schedulers.sh.
#
# Usage:
#   ./print_startup.sh
#   ./print_startup.sh --only backup --only stay_fresh
#   TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... ./print_startup.sh --from-env
#
# No router is contacted and nothing is written — this only prints text. The
# secret slots are placeholders unless --from-env fills them from the
# environment, never from the command line, where ps and shell history keep
# them. Output made with --from-env holds the secrets: paste it, do not commit
# it.
#
# No :global printed here has an underscore in its name. RouterOS 7.24 refuses
# to run a script that declares one, so a startup script carrying TG_BOT_TOKEN
# would set nothing at all on that release.

set -euo pipefail

# --- output ----------------------------------------------------------------
# Only the commentary around the script is coloured, and only for a terminal,
# so redirecting to a file gives clean RouterOS input.
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
DEFAULT_POLICY="read,write,policy,test,sensitive,ftp"
POLICY="$DEFAULT_POLICY"
NAME="startup"
DRY_RUN=0
FROM_ENV=0
LIST_ONLY=0
ONLY=()

usage() {
  cat <<EOF
$(basename "$0") - print the RouterOS startup script that sets the globals

Usage:
  $(basename "$0") [--only SCRIPT]... [--from-env] [--name NAME]
                    [--policy LIST] [--dry-run]
  $(basename "$0") --list

Prints a /system script add for a script that declares the globals these
scripts read, and the start-time=startup scheduler entry that runs it at every
boot. TgBotToken, TgChatId and OpsToolboxPaused are always in it; --only adds
the settings of one script, commented out at their defaults. No router is
contacted: read the output, fill in the placeholders, then paste it.

Options:
  --only SCRIPT   Add the settings of this script (repeatable; see --list)
  --from-env      Fill the secrets from TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
                  and, when a backup script is selected, ROUTER_BACKUP_PASSWORD
                  (optional) instead of printing placeholders. Never taken
                  from the command line. Do not commit this output.
  --name NAME     Name of the script and of its scheduler entry
                  (default: startup)
  --policy LIST   Policy set for both (default: $DEFAULT_POLICY)
  --list          List the scripts --only accepts and exit
  --dry-run       Accepted for symmetry with the other scripts here. This one
                  only ever prints, so the flag adds a closing note and
                  changes nothing else.
  -h, --help      Show this help

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
    -h|--help)  usage; exit 0 ;;
    --dry-run)  DRY_RUN=1 ;;
    --from-env) FROM_ENV=1 ;;
    --list)     LIST_ONLY=1 ;;
    --only)     require_value "$1" "${2:-}"; shift; ONLY+=("$1") ;;
    --only=*)   value="${1#*=}"; require_value "--only" "$value"; ONLY+=("$value") ;;
    --name)     require_value "$1" "${2:-}"; shift; NAME="$1" ;;
    --name=*)   NAME="${1#*=}"; require_value "--name" "$NAME" ;;
    --policy)   require_value "$1" "${2:-}"; shift; POLICY="$1" ;;
    --policy=*) POLICY="${1#*=}"; require_value "--policy" "$POLICY" ;;
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
# The name lands unquoted in name= and inside the on-event string.
case "$NAME" in
  ''|-*|*[!A-Za-z0-9_-]*)
    printf -- '--name takes letters, digits, - and _, got: %s\n' "$NAME" >&2
    exit 3
    ;;
esac

# --- the settings ----------------------------------------------------------
# One line per :global a script reads as a setting: the script, the global,
# the value to show, and one short line on what it does. State the scripts
# keep for themselves (SecLastFp, RdnsDeliveredSig and the like) is not here:
# a startup script that set it would erase their memory at every boot.
# Underscored names are not here either, because 7.24 refuses to declare them.
# test_lua_conventions.sh checks that every global below is declared by the
# script it is listed under.
knob_table() {
  cat <<'KNOBS'
backup               RouterBackupPassword        "<paste backup password>"           encrypts the binary backup; leave unset for none
backup               BackupRemovePrevious        true                                false keeps every generation for backup_file_cleanup
backup_update_check  RouterBackupPassword        "<paste backup password>"           encrypts the pre-upgrade binary backup
stay_fresh           StayFreshDryRun             false                               true checks and reports, never installs
stay_fresh           StayFreshWindowStart        3                                   first local hour it may install or reboot in
stay_fresh           StayFreshWindowEnd          6                                   hour the window closes, exclusive
stay_fresh           StayFreshInstall            true                                false never installs, only reports
stay_fresh           StayFreshFirmware           true                                false never upgrades the RouterBOARD firmware
stay_fresh           StayFreshRequireBackup      true                                false installs even when the backup failed
stay_fresh           StayFreshRequireNotify      true                                false installs with no Telegram helper
stay_fresh           StayFreshMinFreeMiB         16                                  free storage the install needs, 0 for off
stay_fresh           StayFreshRemovePrevious     true                                false keeps older backup generations
stay_fresh           StayFreshMaxWait            12                                  polls of 5 s to wait for the verdict
stay_fresh           StayFreshTgSend             "tg_send_new"                       Telegram helper to use
stay_fresh           RouterBackupPassword        "<paste backup password>"           encrypts the pre-upgrade binary backup
security_check       SecurityManagementList      "LAN"                               interface list meant for MAC management
security_check       SecurityManagementNetworks  "192.168.88.0/24"                   expected /ip service source restriction
security_check       SecurityManagementWifi      "wifi1"                             the management Wi-Fi interface
security_check       SecurityReportAlways        false                               true sends the report even when unchanged
security_check       SecuritySendScript          "tg_send_new"                       Telegram helper to use
rogue_dns_check      DnsExpected                 ";1.1.1.1;1.0.0.1;"                 answers the control name may resolve to
rogue_dns_check      DnsAllowedResolvers         ";1.1.1.1;1.0.0.1;8.8.8.8;8.8.4.4;" resolvers clients may use
rogue_dns_check      RdnsSendScript              "tg_send"                           Telegram helper to use
KNOBS
}

# Scripts --only accepts: the first column, once each, in table order.
known_scripts() {
  knob_table | awk '!seen[$1]++ { print $1 }'
}

for selected in ${ONLY[@]+"${ONLY[@]}"}; do
  known=0
  while IFS= read -r name; do
    [[ "$selected" == "$name" ]] && { known=1; break; }
  done < <(known_scripts)
  if (( known == 0 )); then
    printf 'unknown script for --only: %s (valid: %s)\n' \
      "$selected" "$(known_scripts | tr '\n' ' ' | sed 's/ $//')" >&2
    exit 3
  fi
done

if (( LIST_ONLY == 1 )); then
  known_scripts
  exit 0
fi

is_selected() {
  local candidate="$1" selected
  for selected in ${ONLY[@]+"${ONLY[@]}"}; do
    [[ "$selected" == "$candidate" ]] && return 0
  done
  return 1
}

# --- secrets from the environment -------------------------------------------
# A value goes inside a RouterOS string in a source={} block, so the characters
# that would end the string, start an expression or unbalance the block are
# refused. Messages name the variable and never echo its value.
check_secret() {
  local var="$1" value="$2"
  case "$value" in
    *'"'*|*\\*|*'$'*|*'['*|*']'*|*'{'*|*'}'*|*$'\n'*|*$'\r'*)
      printf '%s holds a character a RouterOS string cannot carry here (" \\ $ [ ] { } or a line break)\n' "$var" >&2
      exit 3
      ;;
  esac
}

BOT_TOKEN='<paste bot token>'
CHAT_ID='<paste chat id>'
BACKUP_PASSWORD=''
if (( FROM_ENV == 1 )); then
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    printf -- '--from-env needs TELEGRAM_BOT_TOKEN in the environment\n' >&2
    exit 3
  fi
  if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    printf -- '--from-env needs TELEGRAM_CHAT_ID in the environment\n' >&2
    exit 3
  fi
  check_secret TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
  check_secret TELEGRAM_CHAT_ID "$TELEGRAM_CHAT_ID"
  BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
  CHAT_ID="$TELEGRAM_CHAT_ID"
  # Encryption is optional for every backup script, so this one may be absent.
  if [[ -n "${ROUTER_BACKUP_PASSWORD:-}" ]]; then
    check_secret ROUTER_BACKUP_PASSWORD "$ROUTER_BACKUP_PASSWORD"
    BACKUP_PASSWORD="$ROUTER_BACKUP_PASSWORD"
  fi
fi

# --- emitting --------------------------------------------------------------
comment "RouterOS startup script for the scripts in mikrotik/."
comment "Generated by print_startup.sh. Review before pasting."
comment
comment "Globals are cleared by every reboot. This script declares them again,"
comment "and the scheduler entry after it runs the script at every boot."
if (( FROM_ENV == 1 )); then
  comment "The secrets below came from the environment: paste this, do not keep it."
else
  comment "Replace each <paste ...> value before pasting. Nothing secret is printed,"
  comment "so this output is safe to keep in git; the router's copy is not."
fi
comment "Settings are commented out at their defaults; uncomment the ones you change."
comment
comment "Adding a name that already exists fails with \"already have such entry\"."
comment "To replace both:  /system script remove [find name=\"$NAME\"]"
comment "                  /system scheduler remove [find name=\"$NAME\"]"
comment

# The body is printed plain, colour or not: it is the part that gets pasted.
printf '/system script add name=%s policy=%s source={\n' "$NAME" "$POLICY"
printf ':global TgBotToken "%s";\n' "$BOT_TOKEN"
printf ':global TgChatId "%s";\n' "$CHAT_ID"
printf '# false keeps every scheduled script running; true pauses them all.\n'
printf ':global OpsToolboxPaused false;\n'

emitted=" TgBotToken TgChatId OpsToolboxPaused "
while IFS= read -r selected; do
  is_selected "$selected" || continue
  printf '# --- %s ---\n' "$selected"
  printed=0
  while read -r script global value what; do
    [[ "$script" == "$selected" ]] || continue
    # Shared settings (RouterBackupPassword) are printed once, under the first
    # selected script that reads them.
    [[ "$emitted" == *" $global "* ]] && continue
    emitted="$emitted$global "
    printed=$((printed + 1))
    printf '# %s: %s\n' "$global" "$what"
    if [[ "$global" == "RouterBackupPassword" && -n "$BACKUP_PASSWORD" ]]; then
      printf ':global %s "%s";\n' "$global" "$BACKUP_PASSWORD"
    else
      printf '# :global %s %s;\n' "$global" "$value"
    fi
  done < <(knob_table)
  if (( printed == 0 )); then
    printf '# reads only settings already listed above\n'
  fi
done < <(known_scripts)

printf '}\n'
printf '/system scheduler add name=%s start-time=startup policy=%s \\\n' "$NAME" "$POLICY"
printf '    on-event="/system script run %s"\n' "$NAME"
printf '\n'

if (( DRY_RUN == 1 )); then
  comment "--dry-run: nothing above has run. It is text; paste it when you are ready."
fi

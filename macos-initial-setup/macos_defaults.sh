#!/usr/bin/env bash
# Report, apply and revert macOS system preferences via `defaults`.
#
# Exit codes:
#   0   success (nothing to change, or changes applied)
#   1   one or more settings failed to apply
#   2   preflight checks failed (not macOS)
#   3   bad CLI arguments
set -u
set -o pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${TMPDIR:-/tmp}"

MODE="report"
DRY_RUN=0
ONLY=""
RESTART_UI=0

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
macos_defaults.sh - report, apply and revert macOS preferences

Read-only by default. Running it with no flags changes nothing: it prints the
current value of each setting beside the desired one, so you can see what
--apply would do before doing it.

That default is deliberate. A defaults(1) collection is the most-regretted kind
of dotfile automation: the keys are undocumented, they move between macOS
releases, and a growing number are protected by SIP or TCC and silently do
nothing while reporting success. Treat every setting here as a suggestion you
have read, not a config you trust.

Usage:
  $(basename "$0")                    # report current vs desired
  $(basename "$0") --apply            # write the desired values
  $(basename "$0") --apply --dry-run  # show the commands without running them
  $(basename "$0") --revert           # restore values captured by the last --apply
  $(basename "$0") --list-groups

Options:
  --apply           Write the desired values (otherwise nothing is changed)
  --revert          Restore from the most recent backup written by --apply
  --dry-run         With --apply or --revert, print commands instead of running
  --only GROUPS     Comma-separated subset (see --list-groups)
  --restart-ui      Restart Finder and Dock so changes take effect immediately
  --list-groups     Print the group names and exit
  --help, -h        Show this help

Every --apply writes the previous values to:
  ${BACKUP_DIR}/macos_defaults-backup-<timestamp>.txt

Exit codes: 0 success, 1 one or more settings failed, 2 not macOS, 3 usage
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

# group|domain|key|type|value|what it does (verified on)
#
# Every row names the macOS version it was checked against. A defaults key that
# quietly stopped working is indistinguishable from one that never worked, so
# the version is the only way to know whether a surprise is worth investigating.
SETTINGS='
finder|com.apple.finder|AppleShowAllExtensions|bool|true|show all file extensions (14.x)
finder|com.apple.finder|ShowPathbar|bool|true|show the path bar (14.x)
finder|com.apple.finder|ShowStatusBar|bool|true|show the status bar (14.x)
finder|com.apple.finder|FXDefaultSearchScope|string|SCcf|search the current folder by default (14.x)
finder|com.apple.finder|FXEnableExtensionChangeWarning|bool|false|no warning when changing an extension (14.x)
finder|NSGlobalDomain|AppleShowAllFiles|bool|true|show dotfiles in Finder (14.x)
dock|com.apple.dock|autohide|bool|true|hide the Dock automatically (14.x)
dock|com.apple.dock|autohide-delay|float|0|no delay before the Dock appears (14.x)
dock|com.apple.dock|show-recents|bool|false|no recent applications in the Dock (14.x)
dock|com.apple.dock|mru-spaces|bool|false|do not reorder Spaces by use (14.x)
keyboard|NSGlobalDomain|KeyRepeat|int|2|fast key repeat (14.x)
keyboard|NSGlobalDomain|InitialKeyRepeat|int|15|short delay before repeat (14.x)
keyboard|NSGlobalDomain|ApplePressAndHoldEnabled|bool|false|key repeat instead of the accent menu (14.x)
keyboard|NSGlobalDomain|NSAutomaticQuoteSubstitutionEnabled|bool|false|no smart quotes, which corrupt code samples (14.x)
keyboard|NSGlobalDomain|NSAutomaticDashSubstitutionEnabled|bool|false|no smart dashes (14.x)
screenshots|com.apple.screencapture|location|string|${HOME}/Desktop/Screenshots|put screenshots in their own folder (14.x)
screenshots|com.apple.screencapture|type|string|png|save screenshots as png (14.x)
screenshots|com.apple.screencapture|disable-shadow|bool|true|no drop shadow on window screenshots (14.x)
'

groups_list() {
  printf '%s\n' "$SETTINGS" | while IFS='|' read -r group _ _ _ _ _; do
    [[ -n "$group" ]] && printf '%s\n' "$group"
  done | sort -u
}

while (( $# > 0 )); do
  case "$1" in
    --apply)   MODE="apply" ;;
    --revert)  MODE="revert" ;;
    --dry-run) DRY_RUN=1 ;;
    --restart-ui) RESTART_UI=1 ;;
    --only)    require_value "$1" "${2:-}"; shift; ONLY="$1" ;;
    --only=*)  ONLY="${1#*=}"; require_value "--only" "$ONLY" ;;
    --list-groups) groups_list; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

# --help and --list-groups are handled above so they work anywhere; everything
# past this point needs a real Mac.
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "this script targets macOS"
  exit 2
fi

wanted_group() {
  local group="$1" item
  [[ -z "$ONLY" ]] && return 0
  local IFS=','
  for item in $ONLY; do
    [[ "$item" == "$group" ]] && return 0
  done
  return 1
}

current_value() {
  local domain="$1" key="$2"
  if [[ "$domain" == "NSGlobalDomain" ]]; then
    defaults read -g "$key" 2>/dev/null
  else
    defaults read "$domain" "$key" 2>/dev/null
  fi
}

write_value() {
  local domain="$1" key="$2" type="$3" value="$4"
  if [[ "$domain" == "NSGlobalDomain" ]]; then
    defaults write -g "$key" "-$type" "$value"
  else
    defaults write "$domain" "$key" "-$type" "$value"
  fi
}

changed=0
failed=0
matched=0

case "$MODE" in
  report|apply)
    backup_file=""
    if [[ "$MODE" == "apply" ]] && (( DRY_RUN == 0 )); then
      backup_file="$BACKUP_DIR/macos_defaults-backup-$(date +%Y%m%d-%H%M%S).txt"
      : > "$backup_file"
      printf '# macos_defaults.sh backup - %s\n' "$(date)" >> "$backup_file"
      info "backup: $C_DIM$backup_file$C_RESET"
    fi

    printf "\n%s%-12s %-34s %-22s %s%s\n" "$C_BOLD" "GROUP" "KEY" "CURRENT" "DESIRED" "$C_RESET"

    while IFS='|' read -r group domain key type value description; do
      [[ -n "$group" ]] || continue
      wanted_group "$group" || continue
      # Only ${HOME} is expanded, deliberately: the table is data, and running
      # eval over it would make a typo into arbitrary code.
      value="${value//\$\{HOME\}/$HOME}"
      matched=$((matched + 1))

      current="$(current_value "$domain" "$key")"
      [[ -n "$current" ]] || current="(unset)"

      if [[ "$current" == "$value" ]]; then
        printf "  %-12s %-34s %-22s %s%s%s\n" "$group" "$key" "$current" "$C_DIM" "same" "$C_RESET"
        continue
      fi

      changed=$((changed + 1))
      printf "  %-12s %-34s %-22s %s%s%s  %s%s%s\n" \
        "$group" "$key" "$current" "$C_YELLOW" "$value" "$C_RESET" "$C_DIM" "$description" "$C_RESET"

      [[ "$MODE" == "apply" ]] || continue

      if (( DRY_RUN == 1 )); then
        printf "    dry-run: would run: defaults write %s %s -%s %s\n" "$domain" "$key" "$type" "$value"
        continue
      fi

      printf '%s|%s|%s|%s\n' "$domain" "$key" "$type" "$current" >> "$backup_file"
      if write_value "$domain" "$key" "$type" "$value"; then
        :
      else
        err "failed: $domain $key"
        failed=$((failed + 1))
      fi
    done <<EOF
$SETTINGS
EOF

    printf "\n"
    if (( matched == 0 )); then
      err "no settings matched --only=$ONLY (see --list-groups)"
      exit 3
    fi

    if [[ "$MODE" == "report" ]]; then
      if (( changed == 0 )); then
        ok "all $matched setting(s) already match"
      else
        info "$changed of $matched setting(s) differ; nothing was changed"
        info "run with --apply to write them"
      fi
      exit 0
    fi

    if (( DRY_RUN == 1 )); then
      printf "dry-run complete; no changes written\n"
      exit 0
    fi
    ;;

  revert)
    latest="$(ls -1t "$BACKUP_DIR"/macos_defaults-backup-*.txt 2>/dev/null | head -n 1)"
    if [[ -z "$latest" ]]; then
      err "no backup found in $BACKUP_DIR"
      exit 1
    fi
    info "restoring from $latest"
    while IFS='|' read -r domain key type previous; do
      [[ -n "$domain" ]] || continue
      case "$domain" in \#*) continue ;; esac
      if (( DRY_RUN == 1 )); then
        if [[ "$previous" == "(unset)" ]]; then
          printf "dry-run: would run: defaults delete %s %s\n" "$domain" "$key"
        else
          printf "dry-run: would run: defaults write %s %s -%s %s\n" "$domain" "$key" "$type" "$previous"
        fi
        continue
      fi
      if [[ "$previous" == "(unset)" ]]; then
        if [[ "$domain" == "NSGlobalDomain" ]]; then
          defaults delete -g "$key" 2>/dev/null || true
        else
          defaults delete "$domain" "$key" 2>/dev/null || true
        fi
      else
        write_value "$domain" "$key" "$type" "$previous" || failed=$((failed + 1))
      fi
      changed=$((changed + 1))
    done < "$latest"

    if (( DRY_RUN == 1 )); then
      printf "dry-run complete; no changes written\n"
      exit 0
    fi
    ok "restored $changed setting(s)"
    ;;
esac

if (( RESTART_UI == 1 )); then
  info "restarting Finder and Dock"
  killall Finder >/dev/null 2>&1 || true
  killall Dock >/dev/null 2>&1 || true
else
  info "some changes need a Finder/Dock restart or a logout — rerun with --restart-ui"
fi

# A defaults key protected by SIP or TCC accepts the write and keeps the old
# value, reporting success either way. Saying so is more honest than a green
# tick that may be a lie.
info "verify with: $(basename "$0") --only <group>"

if (( failed > 0 )); then
  err "$failed setting(s) failed to write"
  exit 1
fi
ok "done"

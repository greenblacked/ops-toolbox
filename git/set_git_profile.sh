#!/usr/bin/env bash
# Manage named Git author profiles and apply them to global Git config.

set -e
set -u
set -o pipefail

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_BLUE=''
fi

info() { printf "%s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf "%s[ ok ]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
err() { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" 1>&2; }

# The directory this repository used to be called. Profiles saved before the
# rename live under it, and silently not finding somebody's saved identities is
# far worse than carrying one extra lookup: the script would report no profiles
# and cheerfully save a new empty set over the top of a working setup.
LEGACY_DIR_NAME="pretty-useful-scripts"
STATE_DIR_NAME="ops-toolbox"

config_home() {
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf "%s\n" "$XDG_CONFIG_HOME"
  else
    printf "%s/.config\n" "$HOME"
  fi
}

default_state_file() {
  local base current legacy
  base="$(config_home)"
  current="$base/$STATE_DIR_NAME/git-profiles.conf"
  legacy="$base/$LEGACY_DIR_NAME/git-profiles.conf"

  # Prefer the current path. Fall back to the legacy one only when it exists
  # and the current one does not, so a machine that has migrated never gets
  # pulled back to the old file.
  if [[ ! -e "$current" && -e "$legacy" ]]; then
    printf "%s\n" "$legacy"
  else
    printf "%s\n" "$current"
  fi
}

STATE_FILE="$(default_state_file)"
DRY_RUN=0
NAME=""
EMAIL=""
PROFILE=""
SAVE_PROFILE=""
SAVE_CURRENT=""
LIST=0
SHOW=0
LOCAL_SCOPE=0

usage() {
  cat <<EOF
${C_BOLD}set_git_profile.sh${C_RESET} - manage global Git user.name and user.email

Usage:
  $(basename "$0") --name "Sergey" --email "your@email.com"
  $(basename "$0") --save personal --name "Sergey" --email "your@email.com"
  $(basename "$0") --profile personal
  $(basename "$0") --local --profile work
  $(basename "$0") --save-current work
  $(basename "$0") --list
  $(basename "$0") --show

Options:
  --name NAME            Git author name to write or save
  --email EMAIL          Git author email to write or save
  --profile PROFILE      Apply a saved profile (global, or local with --local)
  --save PROFILE         Save --name/--email as a named profile
  --save-current PROFILE Save the current global Git identity as a named profile
  --list                 List saved profiles
  --show                 Show current global profile and state file path
  --local                Apply/direct-set identity in the current repository
  --dry-run              Preview changes without writing Git config or state
  --state-file PATH      Override profile state file path
  --help, -h             Show this help

Examples:
  ./set_git_profile.sh --save personal --name "Sergey" --email "your@email.com"
  ./set_git_profile.sh --profile personal
  ./set_git_profile.sh --dry-run --profile personal
EOF
}

require_git() {
  if ! command -v git >/dev/null 2>&1; then
    err "git is not installed or not on PATH"
    exit 2
  fi
}

require_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    err "$option requires a value"
    exit 3
  fi
}

validate_email() {
  local email="$1"
  if [[ "$email" != *@*.* ]]; then
    err "email does not look valid: $email"
    exit 3
  fi
}

validate_profile_name() {
  local profile="$1"
  if [[ -z "$profile" ]]; then
    err "profile name cannot be empty"
    exit 3
  fi
  if [[ ! "$profile" =~ ^[A-Za-z0-9._-]+$ ]]; then
    err "profile name may only contain letters, numbers, dot, underscore, and dash: $profile"
    exit 3
  fi
}

ensure_state_dir() {
  local state_dir
  state_dir="$(dirname "$STATE_FILE")"
  if (( DRY_RUN == 1 )); then
    info "dry-run: would create state directory: $state_dir"
  else
    mkdir -p "$state_dir"
  fi
}

current_name() {
  git config --global --get user.name || true
}

current_email() {
  git config --global --get user.email || true
}

profile_name() {
  local profile="$1"
  git config --file "$STATE_FILE" --get "profile.${profile}.name" 2>/dev/null || true
}

profile_email() {
  local profile="$1"
  git config --file "$STATE_FILE" --get "profile.${profile}.email" 2>/dev/null || true
}

show_global_profile() {
  local git_name git_email
  git_name="$(current_name)"
  git_email="$(current_email)"

  printf "Git global profile:\n"
  printf "  user.name:  %s\n" "${git_name:-<not set>}"
  printf "  user.email: %s\n" "${git_email:-<not set>}"
}

show_applied_profile() {
  local git_name git_email label
  if (( LOCAL_SCOPE == 1 )); then
    git_name="$(git config --local --get user.name || true)"
    git_email="$(git config --local --get user.email || true)"
    label="repository-local"
  else
    git_name="$(current_name)"
    git_email="$(current_email)"
    label="global"
  fi

  printf "Git %s profile:\n" "$label"
  printf "  user.name:  %s\n" "${git_name:-<not set>}"
  printf "  user.email: %s\n" "${git_email:-<not set>}"
}

show_state() {
  show_global_profile
  printf "\nSaved profile state:\n"
  printf "  file: %s\n" "$STATE_FILE"
  # Say so rather than leaving it to be noticed. The fallback is meant to be
  # invisible in operation but obvious when inspected.
  case "$STATE_FILE" in
    */"$LEGACY_DIR_NAME"/git-profiles.conf)
      printf "  note: this is the pre-rename location; move it with\n"
      printf "        mv %s/%s %s/%s\n" \
        "$(config_home)" "$LEGACY_DIR_NAME" "$(config_home)" "$STATE_DIR_NAME"
      ;;
  esac
  if [[ -f "$STATE_FILE" ]]; then
    list_profiles
  else
    printf "  profiles: <none>\n"
  fi
}

list_profiles() {
  local sections section profile name email found
  found=0

  if [[ ! -f "$STATE_FILE" ]]; then
    printf "Saved profiles: <none>\n"
    return 0
  fi

  sections="$(git config --file "$STATE_FILE" --get-regexp '^profile\..*\.name$' 2>/dev/null || true)"
  if [[ -z "$sections" ]]; then
    printf "Saved profiles: <none>\n"
    return 0
  fi

  printf "Saved profiles:\n"
  while IFS= read -r section; do
    [[ -n "$section" ]] || continue
    profile="${section%%.name *}"
    profile="${profile#profile.}"
    name="$(profile_name "$profile")"
    email="$(profile_email "$profile")"
    printf "  %s: %s <%s>\n" "$profile" "${name:-<not set>}" "${email:-<not set>}"
    found=1
  done <<<"$sections"

  if (( found == 0 )); then
    printf "Saved profiles: <none>\n"
  fi
}

write_global_profile() {
  local name="$1"
  local email="$2"
  local scope_flag="--global"

  validate_email "$email"

  if (( LOCAL_SCOPE == 1 )); then
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      err "--local requires a Git working tree"
      exit 2
    fi
    scope_flag="--local"
  fi

  if (( DRY_RUN == 1 )); then
    info "dry-run: would run: git config $scope_flag user.name \"$name\""
    info "dry-run: would run: git config $scope_flag user.email \"$email\""
    return 0
  fi

  git config "$scope_flag" user.name "$name"
  git config "$scope_flag" user.email "$email"
}

finish_change() {
  local message="$1"

  if (( DRY_RUN == 1 )); then
    ok "dry-run complete; no changes written"
  else
    ok "$message"
  fi
}

save_profile() {
  local profile="$1"
  local name="$2"
  local email="$3"

  validate_profile_name "$profile"
  validate_email "$email"

  if (( DRY_RUN == 1 )); then
    info "dry-run: would save profile '$profile' to $STATE_FILE"
    info "dry-run: profile '$profile' name: $name"
    info "dry-run: profile '$profile' email: $email"
    return 0
  fi

  ensure_state_dir
  git config --file "$STATE_FILE" "profile.${profile}.name" "$name"
  git config --file "$STATE_FILE" "profile.${profile}.email" "$email"
}

apply_profile() {
  local profile="$1"
  local name email

  validate_profile_name "$profile"
  name="$(profile_name "$profile")"
  email="$(profile_email "$profile")"

  if [[ -z "$name" || -z "$email" ]]; then
    err "saved profile not found or incomplete: $profile"
    exit 4
  fi

  info "applying saved Git profile: $profile"
  write_global_profile "$name" "$email"
}

save_current_profile() {
  local profile="$1"
  local name email

  validate_profile_name "$profile"
  name="$(current_name)"
  email="$(current_email)"

  if [[ -z "$name" || -z "$email" ]]; then
    err "current global Git identity is incomplete; set user.name and user.email first"
    exit 4
  fi

  save_profile "$profile" "$name" "$email"
}

if (( $# == 2 )) && [[ "${1:-}" != -* ]] && [[ "${2:-}" != -* ]]; then
  NAME="$1"
  EMAIL="$2"
else
  while (( $# > 0 )); do
    case "$1" in
      --name)
        require_value "$1" "${2:-}"
        shift
        NAME="$1"
        ;;
      --name=*)
        NAME="${1#*=}"
        ;;
      --email)
        require_value "$1" "${2:-}"
        shift
        EMAIL="$1"
        ;;
      --email=*)
        EMAIL="${1#*=}"
        ;;
      --profile)
        require_value "$1" "${2:-}"
        shift
        PROFILE="$1"
        ;;
      --profile=*)
        PROFILE="${1#*=}"
        ;;
      --save)
        require_value "$1" "${2:-}"
        shift
        SAVE_PROFILE="$1"
        ;;
      --save=*)
        SAVE_PROFILE="${1#*=}"
        ;;
      --save-current)
        require_value "$1" "${2:-}"
        shift
        SAVE_CURRENT="$1"
        ;;
      --save-current=*)
        SAVE_CURRENT="${1#*=}"
        ;;
      --list)
        LIST=1
        ;;
      --show)
        SHOW=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --local)
        LOCAL_SCOPE=1
        ;;
      --state-file)
        require_value "$1" "${2:-}"
        shift
        STATE_FILE="$1"
        ;;
      --state-file=*)
        STATE_FILE="${1#*=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "unknown argument: $1"
        echo
        usage
        exit 3
        ;;
    esac
    shift
  done
fi

require_git

if [[ -z "$STATE_FILE" ]]; then
  err "--state-file cannot be empty"
  exit 3
fi

actions=0
[[ -n "$SAVE_PROFILE" ]] && actions=$((actions + 1))
[[ -n "$PROFILE" ]] && actions=$((actions + 1))
[[ -n "$SAVE_CURRENT" ]] && actions=$((actions + 1))
[[ -n "$NAME" || -n "$EMAIL" ]] && [[ -z "$SAVE_PROFILE" ]] && actions=$((actions + 1))
(( LIST == 1 )) && actions=$((actions + 1))
(( SHOW == 1 )) && actions=$((actions + 1))

if (( actions == 0 )); then
  err "no action requested"
  echo
  usage
  exit 3
fi

if (( actions > 1 )); then
  err "choose exactly one action"
  exit 3
fi

if (( LOCAL_SCOPE == 1 )) && { [[ -n "$SAVE_PROFILE" || -n "$SAVE_CURRENT" ]] || (( LIST == 1 || SHOW == 1 )); }; then
  err "--local is only valid with --profile or a direct --name/--email action"
  exit 3
fi

if (( LIST == 1 )); then
  list_profiles
  exit 0
fi

if (( SHOW == 1 )); then
  show_state
  exit 0
fi

if [[ -n "$SAVE_CURRENT" ]]; then
  save_current_profile "$SAVE_CURRENT"
  finish_change "saved current Git profile as '$SAVE_CURRENT'"
  exit 0
fi

if [[ -n "$SAVE_PROFILE" ]]; then
  if [[ -z "$NAME" || -z "$EMAIL" ]]; then
    err "--save requires --name and --email"
    exit 3
  fi
  save_profile "$SAVE_PROFILE" "$NAME" "$EMAIL"
  finish_change "saved Git profile '$SAVE_PROFILE'"
  exit 0
fi

if [[ -n "$PROFILE" ]]; then
  apply_profile "$PROFILE"
  if (( LOCAL_SCOPE == 1 )); then
    finish_change "Git repository-local profile updated"
  else
    finish_change "Git global profile updated"
  fi
  if (( DRY_RUN == 0 )); then
    show_applied_profile
  fi
  exit 0
fi

if [[ -z "$NAME" || -z "$EMAIL" ]]; then
  err "both --name and --email are required"
  exit 3
fi

if (( LOCAL_SCOPE == 1 )); then
  info "updating repository-local Git profile"
else
  info "updating global Git profile"
fi
write_global_profile "$NAME" "$EMAIL"
if (( LOCAL_SCOPE == 1 )); then
  finish_change "Git repository-local profile updated"
else
  finish_change "Git global profile updated"
fi
if (( DRY_RUN == 0 )); then
  show_applied_profile
fi

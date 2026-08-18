#!/usr/bin/env bash
# Print the Git identity that applies in the current directory.

set -u
set -o pipefail

usage() {
  cat <<EOF
git_whoami.sh - show the Git identity for the current directory

Usage:
  $(basename "$0") [--expect-email EMAIL] [--help]

Options:
  --expect-email EMAIL  Fail unless this is the effective email (repeatable)
EOF
}

EXPECTED_EMAILS=()
while (( $# > 0 )); do
  case "$1" in
    --expect-email)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        printf -- "--expect-email requires a value\n" >&2
        exit 3
      fi
      shift
      EXPECTED_EMAILS+=("$1")
      ;;
    --expect-email=*)
      value="${1#*=}"
      if [[ -z "$value" ]]; then
        printf -- "--expect-email requires a value\n" >&2
        exit 3
      fi
      EXPECTED_EMAILS+=("$value")
      ;;
    --help|-h) usage; exit 0 ;;
    *)
      printf "unknown argument: %s\n" "$1" >&2
      usage
      exit 3
      ;;
  esac
  shift
done

if ! command -v git >/dev/null 2>&1; then
  printf "git is not installed or not on PATH\n" 1>&2
  exit 2
fi

scope="global"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  scope="effective for this repository"
fi

name="$(git config --get user.name || true)"
email="$(git config --get user.email || true)"
global_name="$(git config --global --get user.name || true)"
global_email="$(git config --global --get user.email || true)"

printf "Git identity (%s):\n" "$scope"
printf "  user.name:  %s\n" "${name:-<not set>}"
printf "  user.email: %s\n" "${email:-<not set>}"

if [[ "$name" != "$global_name" || "$email" != "$global_email" ]]; then
  printf "\nGlobal fallback:\n"
  printf "  user.name:  %s\n" "${global_name:-<not set>}"
  printf "  user.email: %s\n" "${global_email:-<not set>}"
fi

if (( ${#EXPECTED_EMAILS[@]} > 0 )); then
  matched=0
  for expected in "${EXPECTED_EMAILS[@]}"; do
    [[ "$email" == "$expected" ]] && { matched=1; break; }
  done
  if (( matched == 0 )); then
    printf "effective Git email '%s' is not in the expected set\n" "${email:-<not set>}" >&2
    exit 1
  fi
fi

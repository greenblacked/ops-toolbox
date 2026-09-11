#!/usr/bin/env bash
# Fail when a watched pin file has no last-reviewed date, or that date is
# older than PIN_MAX_AGE_DAYS. Dependabot does not watch these files.
#
# Usage:
#   ./check_pin_age.sh
#   ./check_pin_age.sh --list
#   PIN_MAX_AGE_DAYS=90 ./check_pin_age.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
PIN_MAX_AGE_DAYS="${PIN_MAX_AGE_DAYS:-90}"

PINS=(
  "k8s-toolbox/versions.env"
  ".github/ci-tool-checksums.env"
  "mikrotik/tests/routeros-version.env"
)

usage() {
  cat <<EOF
$(basename "$0") - fail when a watched pin file is older than PIN_MAX_AGE_DAYS

Usage:
  $(basename "$0") [--list]

Options:
  --list          Print the watched paths and exit
  -h, --help      Show this help

Each file must contain a line of the form:

  # last-reviewed: YYYY-MM-DD

PIN_MAX_AGE_DAYS defaults to 90.

Exit codes: 0 all pins fresh, 1 one or more stale or missing dates,
            3 usage
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list)    printf '%s\n' "${PINS[@]}"; exit 0 ;;
    *)         printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 3 ;;
  esac
  shift
done

if ! [[ "$PIN_MAX_AGE_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'PIN_MAX_AGE_DAYS must be a positive integer\n' >&2
  exit 3
fi

failures=0
ok()  { printf '[ ok ] %s\n' "$*"; }
err() { printf '[fail] %s\n' "$*" >&2; failures=$((failures + 1)); }

today="$(date -u +%Y-%m-%d)"
today_s="$(date -u -d "$today" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$today" +%s)"

for rel in "${PINS[@]}"; do
  f="$REPO_ROOT/$rel"
  if [[ ! -f "$f" ]]; then
    err "$rel is missing"
    continue
  fi
  stamp="$(grep -E '^# last-reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$f" | head -1 | awk '{print $3}')"
  if [[ -z "$stamp" ]]; then
    err "$rel has no '# last-reviewed: YYYY-MM-DD' line"
    continue
  fi
  stamp_s="$(date -u -d "$stamp" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d' "$stamp" +%s 2>/dev/null || true)"
  if [[ -z "$stamp_s" ]]; then
    err "$rel last-reviewed date is not parseable: $stamp"
    continue
  fi
  age_days=$(( (today_s - stamp_s) / 86400 ))
  if (( age_days < 0 )); then
    err "$rel last-reviewed is in the future ($stamp)"
  elif (( age_days > PIN_MAX_AGE_DAYS )); then
    err "$rel last-reviewed $stamp is ${age_days}d old (limit ${PIN_MAX_AGE_DAYS}d)"
  else
    ok "$rel last-reviewed $stamp (${age_days}d)"
  fi
done

if (( failures > 0 )); then
  printf '%d pin-age check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '=== all pin-age checks passed (%d files) ===\n' "${#PINS[@]}"
exit 0

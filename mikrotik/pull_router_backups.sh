#!/usr/bin/env bash
# pull_router_backups.sh
# Host-side pull of RouterOS backup files created by backup.lua (names
# backup-*.{backup,rsc}) over SSH/SCP. Enable SSH + SFTP on the router
# (IP → Services), use a key-based user with sufficient rights.
#
# Usage:
#   ./pull_router_backups.sh user@router-host [dest-dir]
#
# Example:
#   ./pull_router_backups.sh admin@192.168.88.1 ~/Archive/mikrotik-backups
#
# Wildcard SCP requires RouterOS 7+ SFTP. If a pattern fails, re-run after
# backups exist or copy explicit filenames.

set -euo pipefail

TIMEOUT=10

usage() {
  cat <<'EOF'
pull_router_backups.sh - pull RouterOS backups to this machine over SFTP/SCP

Usage:
  pull_router_backups.sh user@router-host [dest-dir]

Pull backup-*.backup and backup-*.rsc from a RouterOS 7+ router over SFTP/SCP.
dest-dir defaults to ./router-backups. Expects non-interactive SSH (keys).

Options:
  --timeout SECONDS  SSH connect timeout (default: 10)
  -h, --help         Show this help

Example:
  pull_router_backups.sh admin@192.168.88.1 ~/Archive/mikrotik-backups

Exit codes: 0 success (files pulled, or the router has no backups yet),
1 reached the router but the transfer failed, 2 could not reach the router,
3 usage
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

# Anything starting with a dash that is not a known flag was previously taken as
# the hostname: scp then failed, the script reported "nothing pulled" and exited
# 0, so a typo looked exactly like a successful backup run. Reject it instead.
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    --timeout)   require_value "$1" "${2:-}"; shift; TIMEOUT="$1" ;;
    --timeout=*) TIMEOUT="${1#*=}"; require_value "--timeout" "$TIMEOUT" ;;
    -*)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 3
      ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

case "$TIMEOUT" in
  ''|*[!0-9]*)
    printf -- "--timeout requires a whole number of seconds, got: %s\n" "$TIMEOUT" >&2
    exit 3
    ;;
esac

if (( ${#ARGS[@]} == 0 )); then
  printf 'a router host is required\n\n' >&2
  usage >&2
  exit 3
fi

R="${ARGS[0]}"
D="${ARGS[1]:-./router-backups}"

# Preflight before anything else can be misread as a result. Without this a
# machine with no OpenSSH installed reached the transfer, scp failed with
# "command not found", and that was indistinguishable from the router simply
# having no backups yet.
for tool in ssh scp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '%s is required but not installed\n' "$tool" >&2
    exit 2
  fi
done

mkdir -p "$D"

SSH_OPTS=( -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "ConnectTimeout=$TIMEOUT" )

probe_err="$(mktemp)"
scp_err="$(mktemp)"
trap 'rm -f "$probe_err" "$scp_err"' EXIT

# Prove the router is reachable *before* an empty result is allowed to mean
# "no backups yet". Without this the two are indistinguishable: a dead host, a
# rejected key, or SFTP switched off in IP -> Services all produced the same
# "nothing pulled" line and the same exit 0, so a cron job kept reporting
# success while backups silently stopped for months.
#
# ssh reserves 255 for its own failures — refused, timed out, auth rejected —
# and passes any other status through from the remote command. So 255 is the
# one code that unambiguously means "never got there". Any other status means
# we reached the router, and the run continues exactly as it always did.
set +e
ssh "${SSH_OPTS[@]}" "$R" ':put "ok"' >/dev/null 2>"$probe_err"
probe_rc=$?
set -e

if (( probe_rc == 255 )); then
  printf 'cannot reach %s over ssh — backups were NOT pulled\n' "$R" >&2
  sed 's/^/  /' "$probe_err" >&2
  printf '\nCheck the host and key, and that SSH and SFTP are enabled under\n' >&2
  printf 'IP -> Services on the router.\n' >&2
  exit 2
fi

got=0
for ext in backup rsc; do
  if scp "${SSH_OPTS[@]}" -p "$R:backup-*.$ext" "$D/" 2>>"$scp_err"; then
    got=1
  fi
done

if (( got )); then
  echo "Pulled backup-* files into $D"
  exit 0
fi

# We reached the router, so the only benign explanation for an empty result is
# that no backup file exists yet. scp says so explicitly; anything else — SFTP
# disabled, permission denied on the file, a full disk — is a real failure and
# must not be reported as success.
#
# Matched narrowly and deliberately fail-closed: an unrecognised message exits
# 1 rather than 0. An earlier draft of this also accepted "not found", which
# matched the shell's own "command not found" and turned a missing scp binary
# back into a cheerful "no backups yet".
if grep -qi 'no such file' "$scp_err"; then
  printf 'No backup-*.backup / backup-*.rsc on %s yet — nothing to pull.\n' "$R" >&2
  exit 0
fi

printf 'reached %s but could not pull backups\n' "$R" >&2
if [[ -s "$scp_err" ]]; then
  sed 's/^/  /' "$scp_err" >&2
fi
exit 1

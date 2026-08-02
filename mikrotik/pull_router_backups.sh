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

usage() {
  cat <<'EOF'
pull_router_backups.sh - pull RouterOS backups to this machine over SFTP/SCP

Usage:
  pull_router_backups.sh user@router-host [dest-dir]

Pull backup-*.backup and backup-*.rsc from a RouterOS 7+ router over SFTP/SCP.
dest-dir defaults to ./router-backups. Expects non-interactive SSH (keys).

Options:
  -h, --help   Show this help

Example:
  pull_router_backups.sh admin@192.168.88.1 ~/Archive/mikrotik-backups

Exit codes: 0 success (including "nothing matched"), 3 usage
EOF
}

# Anything starting with a dash that is not --help was previously taken as the
# hostname: scp then failed, the script reported "nothing pulled" and exited 0,
# so a typo looked exactly like a successful backup run. Reject it instead.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -*)
    printf 'unknown option: %s\n\n' "$1" >&2
    usage >&2
    exit 3
    ;;
esac

if [[ -z "${1:-}" ]]; then
  printf 'a router host is required\n\n' >&2
  usage >&2
  exit 3
fi

R="$1"
D="${2:-./router-backups}"

mkdir -p "$D"

SCP_OPTS=( -o BatchMode=yes -o StrictHostKeyChecking=accept-new )

shopt -s nullglob
got=0
for ext in backup rsc; do
  if scp "${SCP_OPTS[@]}" -p "$R:backup-*.$ext" "$D/" 2>/dev/null; then
    got=1
  fi
done
shopt -u nullglob

if (( got )); then
  echo "Pulled backup-* files into $D"
else
  echo "No backup-*.backup / backup-*.rsc matched on $R — nothing pulled (exit 0)." >&2
fi

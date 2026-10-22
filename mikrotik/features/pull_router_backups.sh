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
PORT=22
IDENTITY=""
DRY_RUN=0
VERIFY=0
# Empty means the freshness check is off, which keeps an existing cron line
# behaving exactly as it did.
MAX_AGE=""

usage() {
  cat <<'EOF'
pull_router_backups.sh - pull RouterOS backups to this machine over SFTP/SCP

Usage:
  pull_router_backups.sh user@router-host [dest-dir]

Pull backup-*.backup and backup-*.rsc from a RouterOS 7+ router over SFTP/SCP.
dest-dir defaults to ./router-backups. Expects non-interactive SSH (keys).

Options:
  --timeout SECONDS  SSH connect timeout (default: 10)
  --port PORT        SSH port (default: 22)
  --identity FILE    SSH private key (also enables IdentitiesOnly)
  --verify           Check what this run pulled: no empty file, each .rsc
                     starts with the RouterOS export header, and every
                     .backup has its .rsc (and the reverse) in dest-dir
  --max-age HOURS    Fail unless a backup-*.backup pulled in this run was made
                     by the router within the last HOURS hours (a whole
                     number, 1 or more); other routers' files in dest-dir
                     do not count
  --dry-run          Preview the probe and transfers; contact nothing, write nothing
  -h, --help         Show this help

Example:
  pull_router_backups.sh admin@192.168.88.1 ~/Archive/mikrotik-backups
  pull_router_backups.sh --verify --max-age 26 admin@192.168.88.1 ~/Archive/mikrotik-backups

Exit codes: 0 success (files pulled, or the router has no backups yet, and
every requested check passed), 1 reached the router but the transfer failed,
or a --verify or --max-age check failed (with --max-age, a router with no
backups yet is 1), 2 could not reach the router, 3 usage
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
    --port)      require_value "$1" "${2:-}"; shift; PORT="$1" ;;
    --port=*)    PORT="${1#*=}"; require_value "--port" "$PORT" ;;
    --identity)  require_value "$1" "${2:-}"; shift; IDENTITY="$1" ;;
    --identity=*) IDENTITY="${1#*=}"; require_value "--identity" "$IDENTITY" ;;
    --verify)    VERIFY=1 ;;
    --max-age)   require_value "$1" "${2:-}"; shift; MAX_AGE="$1" ;;
    --max-age=*) MAX_AGE="${1#*=}"; require_value "--max-age" "$MAX_AGE" ;;
    --dry-run)   DRY_RUN=1 ;;
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
case "$PORT" in
  ''|*[!0-9]*)
    printf -- "--port requires a whole number from 1 to 65535, got: %s\n" "$PORT" >&2
    exit 3
    ;;
esac
# Check the string length before Bash arithmetic so an oversized decimal value
# cannot wrap into the accepted range. 10# also makes leading zeroes decimal.
if (( ${#PORT} > 5 )) || (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
  printf -- "--port requires a whole number from 1 to 65535, got: %s\n" "$PORT" >&2
  exit 3
fi

if [[ -n "$MAX_AGE" ]]; then
  case "$MAX_AGE" in
    *[!0-9]*)
      printf -- "--max-age requires a whole number of hours, got: %s\n" "$MAX_AGE" >&2
      exit 3
      ;;
  esac
  # Length first, as for --port: an oversized value must not wrap in Bash
  # arithmetic, and five digits is already eleven years.
  if (( ${#MAX_AGE} > 5 )) || (( 10#$MAX_AGE < 1 )); then
    printf -- "--max-age requires a whole number of hours, got: %s\n" "$MAX_AGE" >&2
    exit 3
  fi
fi

if (( ${#ARGS[@]} == 0 )); then
  printf 'a router host is required\n\n' >&2
  usage >&2
  exit 3
fi
if (( ${#ARGS[@]} > 2 )); then
  printf 'expected user@router-host and at most one destination directory\n\n' >&2
  usage >&2
  exit 3
fi

R="${ARGS[0]}"
D="${ARGS[1]:-./router-backups}"

SSH_OPTS=( -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o "ConnectTimeout=$TIMEOUT" -o "Port=$PORT" )
if [[ -n "$IDENTITY" ]]; then
  SSH_OPTS+=( -o IdentitiesOnly=yes -i "$IDENTITY" )
fi

print_cmd() {
  printf 'dry-run: would run:'
  printf ' %q' "$@"
  printf '\n'
}

if (( DRY_RUN == 1 )); then
  printf 'dry-run: would create destination: %s\n' "$D"
  print_cmd ssh "${SSH_OPTS[@]}" "$R" ':put "ok"'
  print_cmd scp "${SSH_OPTS[@]}" -p "$R:backup-*.backup" "$D/"
  print_cmd scp "${SSH_OPTS[@]}" -p "$R:backup-*.rsc" "$D/"
  if (( VERIFY == 1 )); then
    printf 'dry-run: would verify the pulled files (non-empty, export header, backup/rsc pairs)\n'
  fi
  if [[ -n "$MAX_AGE" ]]; then
    printf 'dry-run: would require a pulled backup-*.backup newer than %s hour(s)\n' \
      "$((10#$MAX_AGE))"
  fi
  printf 'dry-run complete; no changes written\n'
  exit 0
fi

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

probe_err="$(mktemp)"
scp_err="$(mktemp)"
stage="$(mktemp -d "$D/.pull-backups.XXXXXXXX")"
trap 'rm -f "$probe_err" "$scp_err"; rm -rf "$stage"' EXIT

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

# Stage each extension independently. A failed scp may leave truncated files;
# none of that attempt is allowed to replace an existing good generation.
failed=0
# What this run pulled into the staging directory, in order, and what it
# published into $D (for --max-age). Bash 3.2 has no mapfile and treats an
# empty array as unset under -u, so they are read back below with the
# ${arr[@]+...} guard, and the candidate count is kept in a plain variable.
cand_file=()
cand_name=()
ncand=0
pulled=()
for ext in backup rsc; do
  mkdir "$stage/$ext"
  : >"$scp_err"
  if scp "${SSH_OPTS[@]}" -p "$R:backup-*.$ext" "$stage/$ext/" 2>"$scp_err"; then
    for file in "$stage/$ext"/backup-*.$ext; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      cand_file+=("$file")
      cand_name+=("${file##*/}")
      ncand=$((ncand + 1))
    done
  else
    transfer_rc=$?
    # Only an entire, recognised missing-pattern diagnostic is benign. A
    # missing-file line mixed with permission/transport errors is a failure.
    missing=1
    lines=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      lines=$((lines + 1))
      if [[ "$line" != "scp: backup-*.$ext: No such file or directory" &&
            "$line" != "scp: /backup-*.$ext: No such file or directory" &&
            "$line" != "scp: stat remote: \"backup-*.$ext\": No such file or directory" ]]; then
        missing=0
      fi
    done <"$scp_err"
    if (( transfer_rc != 1 || missing == 0 || lines == 0 )); then
      printf 'reached %s but could not pull backup-*.%s\n' "$R" "$ext" >&2
      sed 's/^/  /' "$scp_err" >&2
      failed=1
    fi
  fi
done

# Reaching the router and copying files is not the same as having a backup
# that restores.
#
# --verify runs in the staging directory, before anything is published: a
# file that fails is reported and never copied into $D, so a rejected pull (a
# zero-byte file, an error page) cannot replace a good archived copy of the
# same name. The files that pass are still published and the run exits 1.
# Each file must be non-empty, an .rsc must open with the export header, and a
# .backup / .rsc must have its partner: pulled and accepted in this run, or,
# when the router sent no partner, already in $D. A partner pulled in this run
# and rejected does not count, whatever an older run left in $D.
cand_ok=()
i=0
while (( i < ncand )); do
  cand_ok+=(1)
  i=$((i + 1))
done
if (( VERIFY == 1 )); then
  checked=0
  problems=0
  i=0
  while (( i < ncand )); do
    checked=$((checked + 1))
    name="${cand_name[$i]}"
    file="${cand_file[$i]}"
    if [[ ! -s "$file" ]]; then
      printf 'verify: %s: empty file\n' "$name" >&2
      problems=$((problems + 1))
      cand_ok[i]=0
    elif [[ "$name" == *.rsc ]]; then
      # /export opens with "# <date> by RouterOS <version>". Anything else
      # is not an export: an error page, a truncated write, the wrong file.
      first=""
      IFS= read -r first <"$file" || true
      if [[ "$first" != \#* || "$first" != *RouterOS* ]]; then
        printf 'verify: %s: first line is not a RouterOS export header\n' "$name" >&2
        problems=$((problems + 1))
        cand_ok[i]=0
      fi
    fi
    i=$((i + 1))
  done
  # Pairing, judged on the individual results above so the order of the
  # files does not matter.
  cand_pair=()
  i=0
  while (( i < ncand )); do
    cand_pair+=("${cand_ok[i]}")
    i=$((i + 1))
  done
  i=0
  while (( i < ncand )); do
    if [[ "${cand_ok[i]}" == 1 ]]; then
      name="${cand_name[$i]}"
      case "$name" in
        *.rsc) partner="${name%.rsc}.backup" ;;
        *) partner="${name%.backup}.rsc" ;;
      esac
      found=-1
      j=0
      while (( j < ncand )); do
        if [[ "${cand_name[$j]}" == "$partner" ]]; then found=$j; break; fi
        j=$((j + 1))
      done
      if (( found >= 0 )); then
        if [[ "${cand_ok[$found]}" != 1 ]]; then
          printf 'verify: %s: its %s was rejected\n' "$name" "$partner" >&2
          problems=$((problems + 1))
          cand_pair[i]=0
        fi
      elif [[ ! -f "$D/$partner" ]]; then
        printf 'verify: %s: no matching %s in %s\n' "$name" "$partner" "$D" >&2
        problems=$((problems + 1))
        cand_pair[i]=0
      fi
    fi
    i=$((i + 1))
  done
  i=0
  while (( i < ncand )); do
    cand_ok[i]="${cand_pair[i]}"
    i=$((i + 1))
  done
  printf 'verify: %d file(s) checked, %d problem(s)\n' "$checked" "$problems" >&2
  if (( problems > 0 )); then
    failed=1
  fi
fi

# Publish what passed. Without --verify that is everything.
got=0
i=0
while (( i < ncand )); do
  if [[ "${cand_ok[i]}" == 1 ]]; then
    name="${cand_name[$i]}"
    if [[ -d "$D/$name" ]] || ! mv -f "${cand_file[$i]}" "$D/$name"; then
      printf 'could not publish %s into %s\n' "$name" "$D" >&2
      failed=1
    else
      got=1
      pulled+=("$name")
    fi
  fi
  i=$((i + 1))
done

if (( got )); then
  printf 'Pulled backup-* files into %s\n' "$D"
elif (( failed == 0 )); then
  printf 'No backup-*.backup / backup-*.rsc on %s yet — nothing to pull.\n' "$R" >&2
fi

# --max-age: the run can succeed every night while the router's own backup
# scheduler has died, re-pulling the one stale pair RemovePrevious left. scp
# -p keeps the router's timestamps, so the mtime of a file this run pulled is
# the age of a backup this router made. Only this run's files count: a
# destination shared by several routers also holds their backup-*.backup, and
# one router's fresh backup must not vouch for another's dead scheduler.
# find -mmin works on GNU and BSD alike.
if [[ -n "$MAX_AGE" ]]; then
  minutes=$((10#$MAX_AGE * 60))
  recent=""
  for name in ${pulled[@]+"${pulled[@]}"}; do
    [[ "$name" == *.backup ]] || continue
    if [[ -n "$(find "$D/$name" -maxdepth 0 -type f -mmin "-$minutes" 2>/dev/null || true)" ]]; then
      recent="$name"
      break
    fi
  done
  if [[ -z "$recent" ]]; then
    printf 'no backup-*.backup pulled from %s in this run is newer than %s hour(s) (or none was pulled)\n' \
      "$R" "$((10#$MAX_AGE))" >&2
    failed=1
  fi
fi

exit "$failed"

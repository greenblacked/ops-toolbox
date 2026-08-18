#!/usr/bin/env bash
# Exit-code contract for pull_router_backups.sh.
#
# Needs no Docker, no network and no router: ssh and scp are replaced with
# stubs on PATH so every branch can be driven deliberately. That matters
# because the bug this file exists to prevent is invisible from the outside —
# the script used to exit 0 whether it pulled backups or never reached the
# router at all, so a cron job reported success while backups silently stopped.
#
# The interesting cases are the ones where the script must NOT report success.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../pull_router_backups.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "expected an executable at $SCRIPT" >&2
  exit 1
fi

failures=0
ok()  { echo "[ ok ] $*"; }
err() { echo "[fail] $*" >&2; failures=$((failures + 1)); }

STUB_DIR="$(mktemp -d)"
DEST="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" "$DEST"' EXIT
mkdir -p "$STUB_DIR/bin"

# Build an ssh/scp pair that fails in a chosen way, run the script against
# them, and report the exit code.
run_case() {
  local label="$1" expected="$2" ssh_rc="$3" scp_rc="$4" scp_msg="$5" pulls="$6"

  cat >"$STUB_DIR/bin/ssh" <<EOF
#!/usr/bin/env bash
exit $ssh_rc
EOF
  cat >"$STUB_DIR/bin/scp" <<EOF
#!/usr/bin/env bash
dest="\${@: -1}"
if [ "$pulls" = "yes" ]; then printf 'backup\n' >"\$dest/backup-1.backup"; fi
[ -n "$scp_msg" ] && printf '%s\n' "$scp_msg" >&2
exit $scp_rc
EOF
  chmod +x "$STUB_DIR/bin/ssh" "$STUB_DIR/bin/scp"

  rm -rf "${DEST:?}"/*
  local rc
  set +e
  PATH="$STUB_DIR/bin:$PATH" "$SCRIPT" --timeout 2 admin@router "$DEST" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ "$rc" == "$expected" ]]; then
    ok "$label -> $rc"
  else
    err "$label: expected $expected, got $rc"
  fi
}

# The regression this file exists for. Every one of these used to exit 0.
run_case "unreachable router"          2 255 1 "ssh: connect to host: Connection refused" no
run_case "auth rejected"               2 255 1 "Permission denied (publickey)"            no
run_case "sftp subsystem disabled"     1 0   1 "subsystem request failed on channel 0"    no
run_case "permission denied on file"   1 0   1 "scp: /backup-1.backup: Permission denied" no

# The two cases that legitimately succeed.
run_case "connected, no backups yet"   0 0   1 "scp: backup-*.backup: No such file or directory" no
run_case "backups pulled"              0 0   0 ""                                          yes

# An unrecognised scp failure must fail closed. An earlier draft accepted the
# substring "not found", which also matched the shell's own "command not
# found" and turned a missing scp binary back into a cheerful success.
run_case "unrecognised scp failure"    1 0   1 "scp: some new message nobody predicted"   no
run_case "scp missing from PATH"       1 0   127 "bash: scp: command not found"            no

# Argument contract, checked here too so it cannot drift from the exit codes.
check_rc() {
  local label="$1" expected="$2"; shift 2
  local rc
  set +e
  "$SCRIPT" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" == "$expected" ]]; then ok "$label -> $rc"; else err "$label: expected $expected, got $rc"; fi
}

check_rc "--help"                0 --help
check_rc "unknown flag"          3 --definitely-not-a-flag
check_rc "no host"               3
check_rc "--timeout without value" 3 --timeout
check_rc "--timeout not a number"  3 --timeout abc admin@router
check_rc "--port not a number"     3 --port abc admin@router
check_rc "--port zero"             3 --port 0 admin@router
check_rc "--port above 65535"       3 --port 65536 admin@router
check_rc "--port rejects huge integers" 3 --port 18446744073709551616 admin@router
check_rc "too many positional args" 3 admin@router one two

# A preview must be useful before SSH is configured and must not even create
# the local directory it names.
DRY_DEST="$DEST/dry-run-destination"
dry_out="$($SCRIPT --dry-run --port 2222 --identity /keys/router \
  admin@router "$DRY_DEST")"
if [[ ! -e "$DRY_DEST" ]]; then
  ok "--dry-run creates no destination"
else
  err "--dry-run created $DRY_DEST"
fi
if [[ "$dry_out" == *"Port=2222"* && "$dry_out" == *"/keys/router"* ]]; then
  ok "--dry-run previews port and identity"
else
  err "--dry-run omitted port or identity from its preview"
fi
if [[ "$dry_out" == *"scp"* && "$dry_out" != *"scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p 2222"* ]]; then
  ok "--port uses an option understood by both ssh and scp"
else
  err "--port was rendered as scp's lowercase -p preserve flag"
fi

echo
if (( failures > 0 )); then
  echo "$failures pull_router_backups.sh check(s) failed" >&2
  exit 1
fi
echo "=== all pull_router_backups.sh checks passed ==="
exit 0

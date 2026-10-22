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
SCRIPT="$HERE/../features/pull_router_backups.sh"

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
msg="$scp_msg"
remote="\${@: -2:1}"
if [[ "\$remote" == *.rsc ]]; then msg="\${msg//.backup/.rsc}"; fi
[ -n "\$msg" ] && printf '%s\n' "\$msg" >&2
exit $scp_rc
EOF
  chmod +x "$STUB_DIR/bin/ssh" "$STUB_DIR/bin/scp"

  rm -rf "${DEST:?}"/*
  local rc
  PATH="$STUB_DIR/bin:$PATH" "$SCRIPT" --timeout 2 admin@router "$DEST" >/dev/null 2>&1
  rc=$?

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

# Each extension has its own result; failed transfers may leave partial files.
run_mixed_case() {
  local label="$1" backup_rc="$2" backup_msg="$3" rsc_rc="$4" rsc_msg="$5" expected="$6"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/bin/ssh"
  cat >"$STUB_DIR/bin/scp" <<EOF
#!/usr/bin/env bash
dest="\${@: -1}"
remote="\${@: -2:1}"
if [[ "\$remote" == *.backup ]]; then
  printf 'new backup\n' >"\$dest/backup-old.backup"
  printf '%s\n' '$backup_msg' >&2
  exit $backup_rc
fi
printf 'new export\n' >"\$dest/backup-old.rsc"
printf '%s\n' '$rsc_msg' >&2
exit $rsc_rc
EOF
  chmod +x "$STUB_DIR/bin/ssh" "$STUB_DIR/bin/scp"
  printf 'old backup\n' >"$DEST/backup-old.backup"
  printf 'old export\n' >"$DEST/backup-old.rsc"
  PATH="$STUB_DIR/bin:$PATH" "$SCRIPT" admin@router "$DEST" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" == "$expected" ]]; then ok "$label -> $rc"; else err "$label: expected $expected, got $rc"; fi
  if (( backup_rc == 0 )) && [[ "$(cat "$DEST/backup-old.backup")" != "new backup" ]]; then err "$label did not publish successful backup"; fi
  if (( rsc_rc == 0 )) && [[ "$(cat "$DEST/backup-old.rsc")" != "new export" ]]; then err "$label did not publish successful export"; fi
  if (( backup_rc != 0 )) && [[ "$(cat "$DEST/backup-old.backup")" != "old backup" ]]; then err "$label overwrote good backup with partial transfer"; fi
  if (( rsc_rc != 0 )) && [[ "$(cat "$DEST/backup-old.rsc")" != "old export" ]]; then err "$label overwrote good export with partial transfer"; fi
}
run_mixed_case "backup succeeds export fails" 0 "" 1 "Permission denied" 1
run_mixed_case "backup fails export succeeds" 1 "Permission denied" 0 "" 1
run_mixed_case "missing backup cannot mask export failure" 1 "scp: backup-*.backup: No such file or directory" 1 "Permission denied" 1
run_mixed_case "mixed missing and real error" 1 $'scp: backup-*.backup: No such file or directory\nPermission denied' 1 "scp: backup-*.rsc: No such file or directory" 1
run_mixed_case "nontransfer status with missing text" 127 "scp: backup-*.backup: No such file or directory" 1 "scp: backup-*.rsc: No such file or directory" 1
run_mixed_case "success plus absent extension" 0 "" 1 "scp: backup-*.rsc: No such file or directory" 0

# --verify and --max-age: what was pulled is usable, and the newest backup is
# recent. The scp stub publishes whatever the case asks for, with a real-looking
# export header on a good .rsc. Every case asserts an exit code. --verify runs
# in the staging directory, so a file it rejects is never published and an
# archived copy of the same name is never replaced by it; SEED=1 puts a good
# earlier pair in the destination first.
#   good          a .backup and its .rsc
#   empty-backup  a zero-byte .backup and a good .rsc
#   no-header     a .backup and an .rsc that is not an export
#   lone-backup   a .backup, and no .rsc on the router
#   none          nothing on the router
#   rsc-error     a .backup, and the .rsc transfer fails with a permission error
#   backup-error  a good .rsc, and the .backup transfer fails with a permission error
#   stale         a good pair, backdated to 2020
#   future        a good pair, stamped a day ahead of now (router clock ahead)
#   skew          a good pair, stamped one minute ahead (within the allowed skew)
run_check_case() {
  local label="$1" expected="$2" mode="$3"; shift 3
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/bin/ssh"
  cat >"$STUB_DIR/bin/scp" <<EOF
#!/usr/bin/env bash
dest="\${@: -1}"
remote="\${@: -2:1}"
pattern="\${remote#*:}"
missing() { printf 'scp: %s: No such file or directory\n' "\$pattern" >&2; exit 1; }
case "$mode:\$pattern" in
  none:*) missing ;;
  rsc-error:*.rsc) printf 'scp: /backup-1.rsc: Permission denied\n' >&2; exit 1 ;;
  backup-error:*.backup) printf 'scp: /backup-1.backup: Permission denied\n' >&2; exit 1 ;;
  lone-backup:*.rsc) missing ;;
  empty-backup:*.backup) : >"\$dest/backup-1.backup" ;;
  no-header:*.rsc) printf '/ip address\nadd address=192.0.2.1/24\n' >"\$dest/backup-1.rsc" ;;
  *:*.backup) printf 'backup\n' >"\$dest/backup-1.backup" ;;
  *:*.rsc) printf '# 2026-10-21 04:00:00 by RouterOS 7.24.5\n/system identity\n' >"\$dest/backup-1.rsc" ;;
esac
if [ "$mode" = stale ]; then touch -t 202001010000 "\$dest"/backup-1.*; fi
if [ "$mode" = future ]; then touch -t "\$(date -d '+1 day' +%Y%m%d%H%M.%S 2>/dev/null || date -v+1d +%Y%m%d%H%M.%S)" "\$dest"/backup-1.*; fi
if [ "$mode" = skew ]; then touch -t "\$(date -d '+1 minute' +%Y%m%d%H%M.%S 2>/dev/null || date -v+1M +%Y%m%d%H%M.%S)" "\$dest"/backup-1.*; fi
exit 0
EOF
  chmod +x "$STUB_DIR/bin/ssh" "$STUB_DIR/bin/scp"
  rm -rf "${DEST:?}"/*
  if [[ "${SEED:-0}" == 1 ]]; then
    printf 'good archived backup\n' >"$DEST/backup-1.backup"
    printf '# 2026-10-20 04:00:00 by RouterOS 7.24.5\n/system identity\n' >"$DEST/backup-1.rsc"
  fi
  local rc
  PATH="$STUB_DIR/bin:$PATH" "$SCRIPT" "$@" admin@router "$DEST" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" == "$expected" ]]; then ok "$label -> $rc"; else err "$label: expected $expected, got $rc"; fi
}

run_check_case "verify good pair"                  0 good         --verify
run_check_case "verify empty .backup"              1 empty-backup --verify
if [[ ! -e "$DEST/backup-1.backup" && ! -e "$DEST/backup-1.rsc" ]]; then
  ok "verify publishes neither an empty .backup nor its orphaned .rsc"
else
  err "verify published a rejected .backup or the .rsc that lost its pair"
fi
run_check_case "verify .rsc without export header" 1 no-header    --verify
if [[ ! -e "$DEST/backup-1.rsc" ]]; then
  ok "verify does not publish an .rsc it rejected"
else
  err "verify published the .rsc it rejected"
fi
# A zero-byte re-pull of a name already archived must not replace the archived
# copy: the prior destination is kept intact and the run fails.
SEED=1 run_check_case "verify zero-byte re-pull of an archived name" 1 empty-backup --verify
if [[ "$(cat "$DEST/backup-1.backup" 2>/dev/null)" == "good archived backup" ]] &&
   [[ "$(sed -n 2p "$DEST/backup-1.rsc" 2>/dev/null)" == "/system identity" ]] &&
   [[ "$(head -c 21 "$DEST/backup-1.rsc")" == "# 2026-10-20 04:00:00" ]]; then
  ok "verify keeps the archived pair when the re-pull is rejected"
else
  err "verify replaced or removed the archived copy with a rejected re-pull"
fi
SEED=1 run_check_case "verify headerless re-pull of an archived .rsc" 1 no-header --verify
if [[ "$(head -c 21 "$DEST/backup-1.rsc")" == "# 2026-10-20 04:00:00" ]]; then
  ok "verify keeps the archived .rsc when the re-pull has no export header"
else
  err "verify replaced the archived .rsc with a headerless re-pull"
fi
SEED=1 run_check_case "verify good re-pull replaces the archived pair" 0 good --verify
if [[ "$(head -c 21 "$DEST/backup-1.rsc")" == "# 2026-10-21 04:00:00" ]]; then
  ok "verify publishes a re-pull that passes"
else
  err "verify did not publish a re-pull that passes"
fi
run_check_case "verify .backup without .rsc"       1 lone-backup  --verify
# A companion transfer that failed (not the recognised "no such file") must
# not be papered over by an archived same-named partner: the staged file is
# rejected and the archived pair is left exactly as it was.
for mode in rsc-error backup-error; do
  SEED=1 run_check_case "verify $mode with an archived pair" 1 $mode --verify
  if [[ "$(cat "$DEST/backup-1.backup" 2>/dev/null)" == "good archived backup" ]] &&
     [[ "$(head -c 21 "$DEST/backup-1.rsc" 2>/dev/null)" == "# 2026-10-20 04:00:00" ]]; then
    ok "verify $mode leaves the archived pair unchanged"
  else
    err "verify $mode replaced or removed part of the archived pair"
  fi
done
SEED=1 run_check_case "verify recognised no-.rsc reuses the archived partner" 0 lone-backup --verify
run_check_case "verify nothing pulled"             0 none         --verify
run_check_case "max-age fresh"                     0 good         --max-age 24
run_check_case "max-age stale"                     1 stale        --max-age 24
run_check_case "max-age future timestamp"          1 future       --max-age 24
run_check_case "max-age small clock skew allowed"  0 skew         --max-age 24
run_check_case "max-age with no backups"           1 none         --max-age 24
run_check_case "max-age=HOURS form"                0 good         --max-age=1
run_check_case "verify and max-age together"       0 good         --verify --max-age 24
# The old contract, unchanged without the flags: connected and empty is fine,
# and so is a stale pair nobody asked about.
run_check_case "no flags and no backups still"     0 none
run_check_case "no flags and a stale pair still"   0 stale

# A destination shared by two routers: router B's fresh backup, already in the
# directory, must not vouch for router A, whose scheduler died and whose pulled
# pair is stale. And the reverse: A's own fresh pull passes beside B's stale one.
run_shared_case() {
  local label="$1" expected="$2" pulled_stale="$3" other_stale="$4"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/bin/ssh"
  cat >"$STUB_DIR/bin/scp" <<EOF
#!/usr/bin/env bash
dest="\${@: -1}"
remote="\${@: -2:1}"
pattern="\${remote#*:}"
case "\$pattern" in
  *.backup) printf 'backup\n' >"\$dest/backup-routerA.backup" ;;
  *.rsc) printf '# 2026-10-21 04:00:00 by RouterOS 7.24.5\n' >"\$dest/backup-routerA.rsc" ;;
esac
if [ "$pulled_stale" = yes ]; then touch -t 202001010000 "\$dest"/backup-routerA.*; fi
exit 0
EOF
  chmod +x "$STUB_DIR/bin/ssh" "$STUB_DIR/bin/scp"
  rm -rf "${DEST:?}"/*
  printf 'other\n' >"$DEST/backup-routerB.backup"
  if [[ "$other_stale" = yes ]]; then touch -t 202001010000 "$DEST/backup-routerB.backup"; fi
  local rc
  PATH="$STUB_DIR/bin:$PATH" "$SCRIPT" --max-age 24 admin@routerA "$DEST" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" == "$expected" ]]; then ok "$label -> $rc"; else err "$label: expected $expected, got $rc"; fi
}
run_shared_case "max-age ignores another router's fresh backup" 1 yes no
run_shared_case "max-age ignores another router's stale backup" 0 no yes

# Argument contract, checked here too so it cannot drift from the exit codes.
check_rc() {
  local label="$1" expected="$2"; shift 2
  local rc
  "$SCRIPT" "$@" >/dev/null 2>&1
  rc=$?
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
check_rc "--max-age without value"  3 --max-age
check_rc "--max-age abc"            3 --max-age abc admin@router
check_rc "--max-age 0"              3 --max-age 0 admin@router
check_rc "--max-age 99999999"       3 --max-age 99999999 admin@router
check_rc "--max-age=24 accepted"    0 --dry-run --max-age=24 admin@router "$DEST/dry-max-age"
if [[ ! -e "$DEST/dry-max-age" ]]; then
  ok "--max-age under --dry-run creates no destination"
else
  err "--max-age under --dry-run created $DEST/dry-max-age"
fi

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

dry_out="$($SCRIPT --dry-run --verify --max-age 24 admin@router "$DRY_DEST")"
if [[ ! -e "$DRY_DEST" ]]; then
  ok "--dry-run with --verify and --max-age creates no destination"
else
  err "--dry-run with --verify and --max-age created $DRY_DEST"
fi
if [[ "$dry_out" == *"would verify the pulled files"* ]]; then
  ok "--dry-run previews the --verify checks"
else
  err "--dry-run did not mention the --verify checks"
fi
if [[ "$dry_out" == *"newer than 24 hour(s)"* ]]; then
  ok "--dry-run previews the --max-age check"
else
  err "--dry-run did not mention the --max-age check"
fi
if [[ "$dry_out" == *"dry-run complete; no changes written" ]]; then
  ok "--dry-run still ends with its summary line"
else
  err "--dry-run no longer ends with its summary line"
fi

echo
if (( failures > 0 )); then
  echo "$failures pull_router_backups.sh check(s) failed" >&2
  exit 1
fi
echo "=== all pull_router_backups.sh checks passed ==="
exit 0

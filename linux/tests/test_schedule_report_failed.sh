#!/usr/bin/env bash
# schedule_report.sh --failed, --strict and --cron-dir against a stubbed
# systemctl and crontab and a fixture cron directory: nothing here asks the
# host's systemd or cron, and nothing is started, stopped or reset.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCHED="$REPO_ROOT/linux/schedule_report.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/cron.d" "$fixture/clean.d" || exit 1
STUB_DIR="$fixture"
export STUB_DIR
checks=0
failures=0
assert_eq() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (expected %s, got %s)\n' "$1" "$2" "$3" >&2
    failures=$((failures + 1))
  fi
}
assert_contains() {
  checks=$((checks + 1))
  if [[ "$2" == *"$3"* ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (missing %s)\n' "$1" "$3" >&2
    printf '%s\n' "$2" | head -20 >&2
    failures=$((failures + 1))
  fi
}
assert_not_contains() {
  checks=$((checks + 1))
  if [[ "$2" == *"$3"* ]]; then
    printf '[fail] %s (unexpected %s)\n' "$1" "$3" >&2
    printf '%s\n' "$2" | head -20 >&2
    failures=$((failures + 1))
  else
    printf '[ ok ] %s\n' "$1"
  fi
}

# An executable every distro has, by absolute path: `command -v true` would
# answer with the builtin.
TRUE_BIN="$(type -P true)"

# The system manager reports one failed service and the timer that runs it;
# the user manager reports nothing. SYSTEMCTL_RC makes every call fail, the
# way systemctl does in a container with no systemd.
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ -n "${SYSTEMCTL_RC:-}" ]] && exit "$SYSTEMCTL_RC"
user=0
if [[ "${1:-}" == --user ]]; then
  user=1
  shift
fi
case "${1:-}" in
  list-units)
    (( user )) && exit 0
    case "$*" in
      *--state=failed*) cat "$STUB_DIR/failed.out" ;;
      *--type=timer*)   cat "$STUB_DIR/timers.out" ;;
    esac
    exit 0
    ;;
  show)
    timer="${*: -1}"
    printf '%s\n' "${timer%.timer}.service"
    exit 0
    ;;
esac
exit 1
STUB
cat > "$fixture/bin/crontab" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == -l ]] && cat "$STUB_DIR/crontab.out"
STUB
# Lingering on, so a host that does run a user manager adds no warning of its
# own to the --strict checks below.
cat > "$fixture/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
printf 'yes\n'
STUB
chmod +x "$fixture/bin/systemctl" "$fixture/bin/crontab" "$fixture/bin/loginctl"

printf 'backup.service loaded failed failed Nightly backup\n' > "$fixture/failed.out"
printf 'backup.timer loaded active waiting Nightly backup timer\n' > "$fixture/timers.out"
printf '# nightly report\n30 2 * * * %s\n' "$TRUE_BIN" > "$fixture/crontab.out"
printf 'MAILTO=root\n# a comment\n17 3 * * * root /nonexistent/backup.sh\n' > "$fixture/cron.d/job"
printf 'SHELL=/bin/sh\n5 4 * * * root %s\n@daily root %s --quiet\n' "$TRUE_BIN" "$TRUE_BIN" > "$fixture/cron.d/ok"
printf '17 3 * * * root /nonexistent/old.sh\n' > "$fixture/cron.d/job.dpkg-old"
: > "$fixture/cron.d/.placeholder"
cp "$fixture/cron.d/ok" "$fixture/clean.d/ok"

run_sr() {
  out="$(PATH="$fixture/bin:$PATH" "$SCHED" "$@" 2>&1)"
  rc=$?
}

run_sr
assert_eq 'plain run exits 0' 0 "$rc"
assert_not_contains 'plain run has no failed group' "$out" '== failed =='
plain="$out"
run_sr --cron-dir /etc/cron.d
assert_eq 'the default --cron-dir changes nothing' "$plain" "$out"

run_sr --failed --cron-dir "$fixture/cron.d"
assert_eq '--failed exits 0 without --strict' 0 "$rc"
assert_contains '--failed adds its group' "$out" '== failed =='
assert_contains 'the failed timer is named' "$out" 'backup.timer'
assert_contains 'its failed service is named' "$out" 'its service backup.service failed'
assert_contains 'the journal command is the fix' "$out" 'journalctl -u backup.service -n 50 --no-pager'
assert_contains 'a missing cron command is reported' "$out" '/nonexistent/backup.sh does not exist or is not executable'
assert_eq 'exactly one cron warning (env lines, comments and dpkg leftovers are not jobs)' 1 \
  "$(grep -c 'does not exist or is not executable' <<<"$out")"
assert_not_contains 'an executable cron command is not reported' "$out" "$TRUE_BIN does not exist"
assert_contains 'the user manager reports nothing failed' "$out" 'no failed timer-activated services (user)'

run_sr --failed --strict --cron-dir "$fixture/cron.d"
assert_eq '--failed --strict with findings -> 1' 1 "$rc"

: > "$fixture/failed.out"
run_sr --failed --strict --cron-dir "$fixture/clean.d"
assert_eq 'a healthy machine passes --failed --strict' 0 "$rc"
assert_contains 'healthy timers are ok' "$out" 'no failed timer-activated services (system)'
assert_contains 'healthy cron paths are ok' "$out" '3 cron command path(s) resolve'

SYSTEMCTL_RC=1 run_sr --failed --strict --cron-dir "$fixture/clean.d"
assert_eq 'a systemctl that cannot answer is not a failure, even with --strict' 0 "$rc"
assert_contains 'a systemctl that cannot answer is a skip' "$out" 'list-units unavailable'

run_sr --failed --cron-dir
assert_eq '--cron-dir with no value -> 3' 3 "$rc"
run_sr --failed "--cron-dir=$fixture/cron.d"
assert_eq '--cron-dir=DIR exits 0' 0 "$rc"
assert_contains '--cron-dir=DIR is read' "$out" '/nonexistent/backup.sh'

# --strict without --failed still applies to the warnings the report already
# has (lingering off, where there is a user manager to ask): exit 1 exactly
# when a warning was printed.
run_sr --strict --cron-dir "$fixture/clean.d"
if grep -q '\[warn\]' <<<"$out"; then
  assert_eq '--strict alone with a warning -> 1' 1 "$rc"
else
  assert_eq '--strict alone on a clean machine -> 0' 0 "$rc"
fi

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s schedule report checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s schedule report checks passed ===\n' "$checks"

#!/usr/bin/env bash
# disk_cleanup.sh --include-logs and --journal-max-size against scratch
# fixtures and a stubbed journalctl, so no run touches /var/log or a journal.
set -uo pipefail

# Both are read by disk_cleanup.sh; neither may aim this suite at the host.
unset OS_RELEASE XDG_CACHE_HOME

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLEAN="$REPO_ROOT/linux/disk_cleanup.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/tmp" "$fixture/bin" || exit 1
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
present() { [[ -e "$1" ]] && printf 'present' || printf 'gone'; }
run_clean() {
  out="$(PATH="$fixture/bin:$PATH" "$CLEAN" --home "$fixture/home" --tmp "$fixture/tmp" "$@" 2>&1)"
  rc=$?
}

cat > "$fixture/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/journalctl.calls"
STUB
# sudo must never reach the real tools, whoever runs the suite.
cat > "$fixture/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
chmod +x "$fixture/bin/journalctl" "$fixture/bin/sudo"

# A log directory with one of everything the name filter has to tell apart.
logs="$fixture/log"
build_logs() {
  rm -rf "$logs"
  mkdir -p "$logs/journal" "$logs/nginx"
  for name in app.log app.log.1 app.log.12 app.log.2.gz syslog-20200101 wtmp wtmp.1 Xorg.0.log \
              nginx/access.log.4.gz journal/x.journal journal/old.log.1; do
    printf 'log bytes for %s\n' "$name" > "$logs/$name"
    touch -d '10 days ago' "$logs/$name"
  done
  printf 'fresh rotation\n' > "$logs/app.log.3.gz"
}
snapshot() {
  find "$logs" -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort
  find "$logs" | LC_ALL=C sort
}

build_logs
before="$(snapshot)"
run_clean --dry-run --include-logs --log-dir "$logs" --days 1
assert_eq 'logs dry run exits 0' 0 "$rc"
assert_contains 'the logs step runs' "$out" '== logs =='
assert_contains 'a numbered rotation is named' "$out" '/app.log.1 ('
assert_contains 'a two-digit numbered rotation is named' "$out" '/app.log.12 ('
assert_contains 'a compressed rotation is named' "$out" '/app.log.2.gz ('
assert_contains 'a dateext rotation is named' "$out" '/syslog-20200101 ('
assert_contains 'a nested rotation is named' "$out" '/nginx/access.log.4.gz ('
assert_not_contains 'the active log is never named' "$out" '/app.log ('
assert_not_contains 'an active log with a number in it is never named' "$out" 'Xorg.0.log ('
assert_not_contains 'a fresh rotation is age-filtered' "$out" 'app.log.3.gz'
assert_not_contains 'wtmp is never named' "$out" '/wtmp ('
assert_not_contains 'a rotated wtmp is never named' "$out" '/wtmp.1 ('
assert_not_contains 'the journal directory is pruned' "$out" '/journal/'
assert_contains 'the dry run counts what it found' "$out" '5 file(s) in'
assert_contains 'the dry run closes with the summary' "$out" 'dry-run complete; no changes written'
assert_eq 'the dry run changed nothing' "$before" "$(snapshot)"

run_clean --yes --include-logs --log-dir "$logs" --days 1
assert_eq 'logs --yes exits 0' 0 "$rc"
for name in app.log.1 app.log.12 app.log.2.gz syslog-20200101 nginx/access.log.4.gz; do
  assert_eq "--yes removes old rotated $name" gone "$(present "$logs/$name")"
done
for name in app.log app.log.3.gz wtmp wtmp.1 Xorg.0.log journal/x.journal journal/old.log.1; do
  assert_eq "--yes keeps $name" present "$(present "$logs/$name")"
done

build_logs
run_clean --yes --include-logs --log-dir "$logs" --days 0
assert_eq 'logs --days 0 exits 0' 0 "$rc"
assert_eq '--days 0 drops the age filter' gone "$(present "$logs/app.log.3.gz")"
for name in app.log wtmp wtmp.1 Xorg.0.log journal/old.log.1; do
  assert_eq "--days 0 still keeps $name" present "$(present "$logs/$name")"
done

build_logs
run_clean --yes --days 1
assert_eq 'without --include-logs the run exits 0' 0 "$rc"
assert_contains 'without --include-logs the skip is announced' "$out" 'skipped: logs (pass --include-logs)'
assert_eq 'without --include-logs nothing is removed' present "$(present "$logs/app.log.1")"

# Every spelling of the root directory is refused before anything is walked.
roots_tried=0
for log_root in '/' '//' '/.' '/../' '/var/..'; do
  roots_tried=$((roots_tried + 1))
  run_clean --dry-run --include-logs --log-dir "$log_root" --days 0
  assert_eq "--log-dir $log_root -> 3" 3 "$rc"
done
assert_eq 'five root spellings tried' 5 "$roots_tried"

run_clean --dry-run --log-dir "$logs"
assert_eq '--log-dir without --include-logs -> 3' 3 "$rc"
run_clean --dry-run --journal-max-size 500M
assert_eq '--journal-max-size without --include-journal -> 3' 3 "$rc"
run_clean --dry-run --include-journal --journal-max-size 5Q
assert_eq '--journal-max-size 5Q -> 3' 3 "$rc"
run_clean --dry-run --include-journal --journal-max-size=0
assert_eq '--journal-max-size=0 -> 3' 3 "$rc"
run_clean --dry-run --include-journal --journal-max-size
assert_eq '--journal-max-size with no value -> 3' 3 "$rc"

: > "$fixture/journalctl.calls"
run_clean --include-journal --journal-max-size 200M --days 3 --yes --no-sudo
assert_eq 'journal under --no-sudo exits 0' 0 "$rc"
assert_contains 'journal under --no-sudo is skipped' "$out" 'skipped (needs root)'
assert_eq 'journal under --no-sudo runs nothing' '' "$(cat "$fixture/journalctl.calls")"

: > "$fixture/journalctl.calls"
run_clean --include-journal --journal-max-size=200M --days 3 --dry-run
assert_eq 'journal dry run exits 0' 0 "$rc"
assert_contains 'journal dry run previews the size cap' "$out" '--vacuum-size=200M'
assert_eq 'journal dry run runs nothing' '' "$(cat "$fixture/journalctl.calls")"

: > "$fixture/journalctl.calls"
run_clean --include-journal --journal-max-size 200M --days 3 --yes
assert_eq 'journal --yes exits 0' 0 "$rc"
calls="$(cat "$fixture/journalctl.calls")"
assert_eq 'journalctl ran twice' 2 "$(grep -c . <<<"$calls")"
assert_contains 'the age vacuum still runs' "$calls" '--vacuum-time=3d'
assert_contains 'the size cap runs' "$calls" '--vacuum-size=200M'

# A readable log directory can hold subdirectories this user cannot enter. The
# stub find hides apache2/ unless it runs under the stub sudo, which is how an
# unprivileged find would behave; the old code never retried with sudo there.
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$fixture/hidebin"
  cat > "$fixture/hidebin/find" <<'STUB'
#!/usr/bin/env bash
if [[ "${STUB_AS_ROOT:-}" == 1 ]]; then
  exec /usr/bin/find "$@"
fi
/usr/bin/find "$@" | grep -zv '/apache2/'
exit 0
STUB
  cat > "$fixture/hidebin/sudo" <<'STUB'
#!/usr/bin/env bash
STUB_AS_ROOT=1 exec "$@"
STUB
  chmod +x "$fixture/hidebin/find" "$fixture/hidebin/sudo"
  build_logs
  mkdir -p "$logs/apache2"
  printf 'hidden\n' > "$logs/apache2/error.log.1"
  touch -d '10 days ago' "$logs/apache2/error.log.1"
  out="$(PATH="$fixture/hidebin:$fixture/bin:$PATH" "$CLEAN" --home "$fixture/home" --tmp "$fixture/tmp" \
    --dry-run --include-logs --log-dir "$logs" --days 1 2>&1)"
  assert_contains 'a readable dir with unreadable children is walked as root' "$out" '/apache2/error.log.1 ('
  out="$(PATH="$fixture/hidebin:$fixture/bin:$PATH" "$CLEAN" --home "$fixture/home" --tmp "$fixture/tmp" \
    --dry-run --include-logs --log-dir "$logs" --days 1 --no-sudo 2>&1)"
  assert_not_contains 'under --no-sudo the unreadable children stay out' "$out" '/apache2/error.log.1 ('
else
  printf '[skip] unreadable-subdirectory checks need a non-root user\n'
fi

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s disk cleanup log checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s disk cleanup log checks passed ===\n' "$checks"

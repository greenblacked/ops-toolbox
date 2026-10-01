#!/usr/bin/env bash
# Exercise archive publication entirely in private temporary fixtures.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BACKUP="$REPO_ROOT/linux/config_backup.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/src" "$fixture/bin" || exit 1
printf 'backup fixture\n' > "$fixture/src/payload"
REAL_TAR="$(command -v tar)"
REAL_LN="$(command -v ln)"
export REAL_TAR REAL_LN
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
count_archives() {
  local path count=0
  for path in "$dest"/config-*.tar.gz; do
    [[ -f "$path" && ! -L "$path" ]] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}
new_dest() {
  dest="$(mktemp -d "$fixture/dest.XXXXXXXX")" || exit 1
}
run_backup() {
  PATH="$fixture/bin:$PATH" "$BACKUP" --yes --paths "$fixture/src" --dest "$dest" "$@" > "$fixture/output" 2>&1
  rc=$?
}
assert_clean() {
  local path count=0
  for path in "$dest"/.config-stage.*; do
    [[ -e "$path" ]] && count=$((count + 1))
  done
  assert_eq 'staging removed after run' 0 "$count"
}
cat > "$fixture/bin/date" <<'STUB'
#!/usr/bin/env bash
printf '20261001-120000\n'
STUB
cat > "$fixture/bin/tar" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" != -czf ]]; then
  exec "$REAL_TAR" "$@"
fi
if [[ "${CHECK_MODE:-0}" == 1 ]]; then
  [[ "$(stat -c %a "$2")" == 600 && "$(stat -c %a "${2%/*}")" == 700 ]] || exit 2
fi
case "${TAR_MODE:-complete}" in
  warning) "$REAL_TAR" "$@" || exit 2; exit 1 ;;
  fatal) printf 'fatal output\n' > "$2"; exit 2 ;;
  corrupt0) printf 'not gzip\n' > "$2"; exit 0 ;;
  corrupt1) printf 'not gzip\n' > "$2"; exit 1 ;;
  short0) printf 'not a tar stream' | gzip > "$2"; exit 0 ;;
  short1) printf 'not a tar stream' | gzip > "$2"; exit 1 ;;
  empty0) printf '' | gzip > "$2"; exit 0 ;;
  empty1) printf '' | gzip > "$2"; exit 1 ;;
  writefail) shift 2; exec "$REAL_TAR" -czf /dev/full "$@" ;;
  *) exec "$REAL_TAR" "$@" ;;
esac
STUB
chmod +x "$fixture/bin/date" "$fixture/bin/tar"

new_dest
PATH="$fixture/bin:$PATH" "$BACKUP" --dry-run --paths "$fixture/src" --dest "$dest" > "$fixture/output" 2>&1
assert_eq 'dry run succeeds' 0 "$?"
assert_eq 'dry run creates no files, staging or locks' '' "$(ls -A "$dest")"

# Fixed date guarantees the old predictable name collides on every run.
new_dest
printf 'victim unchanged\n' > "$fixture/victim"
chmod 644 "$fixture/victim"
ln -s "$fixture/victim" "$dest/config-20261001-120000.tar.gz"
run_backup --keep 0
assert_eq 'preexisting archive symlink permits unique publication' 0 "$rc"
assert_eq 'symlink target bytes preserved' 'victim unchanged' "$(cat "$fixture/victim")"
assert_eq 'symlink target mode preserved' 644 "$(stat -c %a "$fixture/victim")"
assert_eq 'preexisting symlink itself preserved' 1 "$(test -L "$dest/config-20261001-120000.tar.gz" && printf 1)"
assert_eq 'one complete unique archive published' 1 "$(count_archives)"
assert_clean

new_dest
printf 'old archive unchanged\n' > "$dest/config-20261001-120000.tar.gz"
run_backup --keep 0
assert_eq 'preexisting file permits unique publication' 0 "$rc"
assert_eq 'preexisting archive bytes preserved' 'old archive unchanged' "$(cat "$dest/config-20261001-120000.tar.gz")"
assert_eq 'same second retains both files' 2 "$(count_archives)"

# A newline in a matching filename must never turn into a different deletion
# target when retention reads the directory listing.
new_dest
printf 'unrelated generation\n' > "$dest/otherfile.tar.gz"
printf 'unrecognised filename\n' > "$dest/"$'config-foo\notherfile.tar.gz'
run_backup --keep 1
assert_eq 'rotation safely ignores malformed basenames' 0 "$rc"
assert_eq 'newline filename cannot delete another basename' 'unrelated generation' "$(cat "$dest/otherfile.tar.gz")"
assert_eq 'newline filename itself is preserved' 1 "$(test -f "$dest/"$'config-foo\notherfile.tar.gz' && printf 1)"

for backup_umask in 000 022 077; do
  new_dest
  (umask "$backup_umask"; CHECK_MODE=1 run_backup --keep 0; exit "$rc")
  assert_eq "private staging under umask $backup_umask" 0 "$?"
  for archive in "$dest"/config-*.tar.gz; do
    assert_eq "published archive mode under umask $backup_umask" 600 "$(stat -c %a "$archive" 2>/dev/null)"
  done
  assert_clean
done

# Valid warnings are partial; partial retention cannot remove complete copies,
# even when --keep is reduced on the partial run.
new_dest
run_backup --keep 0
assert_eq 'first complete generation succeeds' 0 "$rc"
run_backup --keep 0
assert_eq 'second same-second complete generation succeeds' 0 "$rc"
for attempt in 1 2; do
  TAR_MODE=warning run_backup --keep 1
  assert_eq 'valid tar warning returns partial status' 1 "$rc"
  output="$(cat "$fixture/output")"
  explicit_partial=0
  [[ "$output" == *'partial backup:'* ]] && explicit_partial=1
  assert_eq 'partial status is explicit in output' 1 "$explicit_partial"
  assert_clean
done
assert_eq 'partial retention preserves both complete generations' 3 "$(count_archives)"
partial_count=0
for archive in "$dest"/*.partial.tar.gz; do
  [[ -f "$archive" ]] && partial_count=$((partial_count + 1))
  "$REAL_TAR" -tzf "$archive" >/dev/null 2>&1
  assert_eq 'published partial archive is readable' 0 "$?"
done
assert_eq 'partial retention keeps one partial generation' 1 "$partial_count"
run_backup --paths "$fixture/missing" --keep 1
assert_eq 'missing requested path makes a partial backup' 1 "$rc"
assert_eq 'missing source does not evict complete generations' 3 "$(count_archives)"

# A failed build, gzip validation, write or publication must not rotate a good
# old generation even with --keep 1. Compare the whole generation's digest.
for mode in fatal corrupt0 corrupt1 short0 short1 empty0 empty1 writefail; do
  new_dest
  run_backup --keep 0
  assert_eq "setup good generation for $mode" 0 "$rc"
  before="$(sha256sum "$dest"/config-*.tar.gz)"
  TAR_MODE="$mode" run_backup --keep 1
  assert_eq "$mode fails visibly" 1 "$rc"
  assert_eq "$mode preserves old generation" "$before" "$(sha256sum "$dest"/config-*.tar.gz)"
  assert_eq "$mode publishes no artifact" 1 "$(count_archives)"
  assert_clean
done

new_dest
run_backup --keep 0
before="$(sha256sum "$dest"/config-*.tar.gz)"
cat > "$fixture/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$fixture/bin/mktemp"
run_backup --keep 1
assert_eq 'failed staging creation fails visibly' 1 "$rc"
assert_eq 'failed staging creation preserves good generation' "$before" "$(sha256sum "$dest"/config-*.tar.gz)"
assert_clean
rm "$fixture/bin/mktemp"

cat > "$fixture/bin/ln" <<'STUB'
#!/usr/bin/env bash
case "${LINK_MODE:-fail}" in
  symlink) "$REAL_LN" -s "$LINK_TARGET" "${@: -1}" || exit 2 ;;
  directory) "$REAL_LN" -s "$LINK_TARGET" "${@: -1}" || exit 2 ;;
  file) printf 'occupied publication\n' > "${@: -1}" ;;
  *) exit 1 ;;
esac
exec "$REAL_LN" "$@"
STUB
chmod +x "$fixture/bin/ln"
for link_mode in fail symlink directory file; do
  new_dest
  # Seed with real tools before enabling the publication-failure stub.
  "$BACKUP" --yes --paths "$fixture/src" --dest "$dest" --keep 0 >/dev/null 2>&1
  assert_eq "setup good generation for publication $link_mode" 0 "$?"
  before="$(sha256sum "$dest"/config-*.tar.gz)"
  if [[ "$link_mode" == directory ]]; then
    LINK_TARGET="$fixture/src"
  else
    LINK_TARGET="$fixture/victim"
  fi
  export LINK_TARGET
  LINK_MODE="$link_mode" run_backup --keep 1
  assert_eq "publication $link_mode fails visibly" 1 "$rc"
  assert_eq "publication $link_mode preserves good generation" "$before" "$(sha256sum "${before#*  }")"
  assert_eq "publication $link_mode preserves symlink target" 'victim unchanged' "$(cat "$fixture/victim")"
  assert_eq "publication $link_mode writes nothing through directory symlink" 1 "$(find "$fixture/src" -type f | wc -l | tr -d ' ')"
  assert_clean
done
rm "$fixture/bin/ln"

new_dest
pids=()
for attempt in 1 2 3 4 5 6; do
  PATH="$fixture/bin:$PATH" "$BACKUP" --yes --paths "$fixture/src" --dest "$dest" --keep 0 > "$fixture/concurrent.$attempt" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
  assert_eq 'concurrent same-second publication succeeds' 0 "$?"
done
assert_eq 'concurrency publishes six distinct generations' 6 "$(count_archives)"
for archive in "$dest"/config-*.tar.gz; do
  gzip -t "$archive" && "$REAL_TAR" -tzf "$archive" >/dev/null
  assert_eq 'concurrent generation validates' 0 "$?"
done
assert_clean
pids=()
for attempt in 1 2 3 4; do
  PATH="$fixture/bin:$PATH" "$BACKUP" --yes --paths "$fixture/src" --dest "$dest" --keep 1 > "$fixture/retention.$attempt" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
  assert_eq 'concurrent publication and rotation succeeds' 0 "$?"
done
assert_eq 'concurrent retention leaves one complete generation' 1 "$(count_archives)"
assert_clean

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s config backup checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s config backup checks passed ===\n' "$checks"

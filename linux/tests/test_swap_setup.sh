#!/usr/bin/env bash
# swap_setup.sh against a fixture fstab and stubbed swap tools: the suite never
# formats, enables or disables real swap, and never edits /etc/fstab.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SW="$REPO_ROOT/linux/swap_setup.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/statbin" || exit 1
STUB_DIR="$fixture"
export STUB_DIR
swapfile="$fixture/swapfile"
fstab="$fixture/fstab"
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

# fallocate leaves a small file where the swapfile goes; swapon and swapoff
# keep $STUB_DIR/active the way the kernel's swap list would look.
cat > "$fixture/bin/fallocate" <<'STUB'
#!/usr/bin/env bash
printf 'fallocate %s\n' "$*" >> "$STUB_DIR/calls"
printf 'not really swap\n' > "${@: -1}"
STUB
cat > "$fixture/bin/mkswap" <<'STUB'
#!/usr/bin/env bash
printf 'mkswap %s\n' "$*" >> "$STUB_DIR/calls"
STUB
cat > "$fixture/bin/swapon" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --show*) cat "$STUB_DIR/active" 2>/dev/null; exit 0 ;;
esac
printf 'swapon %s\n' "$*" >> "$STUB_DIR/calls"
printf '%s file 128M 0B\n' "$1" >> "$STUB_DIR/active"
STUB
cat > "$fixture/bin/swapoff" <<'STUB'
#!/usr/bin/env bash
printf 'swapoff %s\n' "$*" >> "$STUB_DIR/calls"
awk -v p="$1" '$1 != p' "$STUB_DIR/active" > "$STUB_DIR/active.new"
mv "$STUB_DIR/active.new" "$STUB_DIR/active"
STUB
# Only the filesystem-type refusal test puts this one on PATH. Anything but
# `stat -f` goes to the real stat, by absolute path so it cannot find itself.
REAL_STAT="$(command -v stat)"
export REAL_STAT
cat > "$fixture/statbin/stat" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == -f ]]; then
  printf 'tmpfs\n'
  exit 0
fi
exec "$REAL_STAT" "$@"
STUB
chmod +x "$fixture/bin/"* "$fixture/statbin/stat"

: > "$fixture/active"
: > "$fixture/calls"
printf 'UUID=0000-fixture / ext4 defaults 0 1\n' > "$fstab"

run_sw() {
  out="$(PATH="$fixture/bin:$PATH" "$SW" --path "$swapfile" --fstab "$fstab" "$@" 2>&1)"
  rc=$?
}
digest() { sha256sum "$fstab" | awk '{ print $1 }'; }
tree() { find "$fixture" | LC_ALL=C sort; }
marker_lines() { grep -c 'ops-toolbox swapfile' "$fstab"; }

run_sw
assert_eq 'report exits 0' 0 "$rc"
assert_contains 'report says when there is no swap' "$out" 'no swap configured'
assert_contains 'report suggests a size' "$out" 'suggested size:'

printf '/dev/fixture2 partition 1G 0B\n' > "$fixture/active"
run_sw
assert_eq 'report with active swap exits 0' 0 "$rc"
assert_contains 'report lists the active swap' "$out" '/dev/fixture2'
assert_not_contains 'report does not call active swap missing' "$out" 'no swap configured'
: > "$fixture/active"

run_sw --dry-run
assert_eq 'bare --dry-run is the report and exits 0' 0 "$rc"

run_sw --create --size 128M
assert_eq '--create without --yes -> 3' 3 "$rc"
for bad in '--size 64K' '--size=abc' '--size 100G' '--path relative' '--path /proc/x' '--path /' '--path /sys/../dev/x'; do
  # shellcheck disable=SC2086  # each entry is one or two words on purpose
  run_sw --create --dry-run $bad
  assert_eq "--create $bad -> 3" 3 "$rc"
done
# A path with whitespace or a backslash would be split or unescaped by fstab.
for bad_path in "$fixture/with space" "$fixture/with"$'\t'"tab" "$fixture/with\\slash" "$fixture/with"$'\n'"newline"; do
  run_sw --create --dry-run --path "$bad_path"
  assert_eq "--path with whitespace or backslash -> 3 ($(printf '%q' "$bad_path" | tail -c 12))" 3 "$rc"
  assert_contains '--path rejection says why' "$out" 'must not contain whitespace'
done
run_sw --create --remove --dry-run
assert_eq '--create with --remove -> 3' 3 "$rc"
run_sw --remove --size 1G --dry-run
assert_eq '--size without --create -> 3' 3 "$rc"

: > "$fixture/calls"
tree_before="$(tree)"
fstab_before="$(digest)"
run_sw --create --size 128M --dry-run
assert_eq '--create --dry-run exits 0' 0 "$rc"
assert_contains 'dry run previews fallocate' "$out" 'fallocate -l 128M'
assert_contains 'dry run previews mkswap' "$out" 'mkswap'
assert_contains 'dry run previews swapon' "$out" 'swapon'
assert_contains 'dry run previews the fstab line' "$out" 'would append'
assert_contains 'dry run closes with the summary' "$out" 'dry-run complete; no changes written'
assert_eq 'dry run creates nothing' "$tree_before" "$(tree)"
assert_eq 'dry run leaves fstab unchanged' "$fstab_before" "$(digest)"
assert_eq 'dry run runs no swap tool' '' "$(cat "$fixture/calls")"

if [[ "$(id -u)" != 0 ]]; then
  run_sw --create --size 128M --yes
  assert_eq '--create --yes without root -> 2' 2 "$rc"
  assert_eq 'a refused create runs nothing' '' "$(cat "$fixture/calls")"
else
  run_sw --create --size 128M --yes
  assert_eq '--create --yes exits 0' 0 "$rc"
  calls="$(cat "$fixture/calls")"
  assert_eq 'the swap tools ran' 1 "$([[ -n "$calls" ]] && printf 1)"
  assert_eq 'the steps run in order' 'fallocate mkswap swapon' \
    "$(awk '{ print $1 }' <<<"$calls" | tr '\n' ' ' | sed 's/ $//')"
  assert_eq 'the swapfile is mode 600' 600 "$(stat -c %a "$swapfile" 2>/dev/null)"
  assert_eq 'fstab gains exactly one swap line' 1 "$(marker_lines)"
  assert_contains 'the fstab line is complete' "$(cat "$fstab")" "$swapfile none swap sw 0 0 # ops-toolbox swapfile"
  assert_contains 'the original fstab lines stay' "$(cat "$fstab")" 'UUID=0000-fixture / ext4 defaults 0 1'
  backups=0
  for backup in "$fstab".ops-toolbox.*.bak; do
    [[ -f "$backup" ]] && backups=$((backups + 1))
  done
  assert_eq 'fstab was backed up once' 1 "$backups"

  : > "$fixture/calls"
  run_sw --create --size 128M --yes
  assert_eq 'a second --create -> 4 (the file exists)' 4 "$rc"
  assert_eq 'a second --create leaves fstab alone' 1 "$(marker_lines)"
  assert_eq 'a second --create runs nothing' '' "$(cat "$fixture/calls")"

  : > "$fixture/calls"
  run_sw --remove --yes
  assert_eq '--remove --yes exits 0' 0 "$rc"
  assert_contains '--remove disables the swapfile' "$(cat "$fixture/calls")" "swapoff $swapfile"
  assert_eq '--remove deletes the file' gone "$([[ -e "$swapfile" ]] && printf present || printf gone)"
  assert_eq '--remove drops the line it added' 0 "$(marker_lines)"
  assert_contains '--remove keeps the other fstab lines' "$(cat "$fstab")" 'UUID=0000-fixture / ext4 defaults 0 1'

  # An fstab whose last record has no newline must not swallow the new entry.
  printf 'UUID=0000-fixture / ext4 defaults 0 1' > "$fstab"
  : > "$fixture/calls"
  run_sw --create --size 128M --yes
  assert_eq '--create on an fstab without a final newline exits 0' 0 "$rc"
  assert_eq 'the old last record stays on its own line' 1 \
    "$(grep -cFx 'UUID=0000-fixture / ext4 defaults 0 1' "$fstab")"
  assert_eq 'the swap entry is a line of its own' 1 \
    "$(grep -cFx "$swapfile none swap sw 0 0 # ops-toolbox swapfile" "$fstab")"
  run_sw --remove --yes
  assert_eq '--remove after that exits 0' 0 "$rc"
  assert_eq '--remove leaves the old record alone' 1 \
    "$(grep -cFx 'UUID=0000-fixture / ext4 defaults 0 1' "$fstab")"
fi

# --dry-run from here on: the answers below are the same for any user, and a
# non-root run of --yes would stop at the root check first.
run_sw --remove --dry-run
assert_eq '--remove with nothing present -> 4' 4 "$rc"

# A line somebody else wrote for the same file is never edited from here.
other="$fixture/other-swap"
printf 'other\n' > "$other"
printf '%s none swap sw 0 0\n' "$other" >> "$fstab"
fstab_before="$(digest)"
run_sw --remove --dry-run --path "$other"
assert_eq 'an fstab line this script did not write -> 4' 4 "$rc"
assert_eq 'that fstab line is left alone' "$fstab_before" "$(digest)"
assert_eq 'and so is the file' present "$([[ -e "$other" ]] && printf present || printf gone)"

mkdir -p "$fixture/not-a-file"
run_sw --remove --dry-run --path "$fixture/not-a-file"
assert_eq '--remove refuses anything but a regular file -> 3' 3 "$rc"

printf '/dev/fixture2 partition 1G 0B\n' > "$fixture/active"
run_sw --create --size 128M --dry-run
assert_eq 'swap already active -> 4' 4 "$rc"
assert_contains 'the active swap is named' "$out" '/dev/fixture2'
run_sw --create --size 128M --dry-run --force
assert_eq '--force adds a swapfile beside active swap' 0 "$rc"
: > "$fixture/active"

out="$(PATH="$fixture/statbin:$fixture/bin:$PATH" "$SW" --path "$swapfile" --fstab "$fstab" \
  --create --size 128M --dry-run 2>&1)"; rc=$?
assert_eq 'a swapfile on tmpfs is refused -> 2' 2 "$rc"
assert_contains 'the filesystem is named' "$out" 'tmpfs'

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s swap setup checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s swap setup checks passed ===\n' "$checks"

#!/usr/bin/env bash
# config_backup.sh --diff against private temporary fixtures: it must report
# what changed since an archive and write nothing anywhere while doing so.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BACKUP="$REPO_ROOT/linux/config_backup.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
src="$fixture/src"
dest="$fixture/dest"
mkdir -p "$src/nested" "$dest" || exit 1
printf 'backup fixture\n' > "$src/payload.txt"
printf 'nested fixture\n' > "$src/nested/file.txt"
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
run_diff() {
  out="$("$BACKUP" "$@" 2>&1)"
  rc=$?
}
live_digest() {
  find "$src" -type f -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort
}

"$BACKUP" --yes --paths "$src" --dest "$dest" --keep 0 > "$fixture/output" 2>&1
assert_eq 'setup archive written' 0 "$?"
archive=""
for candidate in "$dest"/config-*.tar.gz; do
  [[ -f "$candidate" ]] && archive="$candidate"
done
assert_eq 'setup archive exists' 1 "$([[ -n "$archive" && -f "$archive" ]] && printf 1)"

run_diff --diff --dest "$dest" --paths "$src"
assert_eq 'unchanged tree -> 0' 0 "$rc"
assert_contains 'unchanged tree says so' "$out" 'no differences'
assert_contains 'the compared archive is named' "$out" 'comparing'

# One change of each kind: a file that grew, a file that went, a file that came.
printf 'appended\n' >> "$src/payload.txt"
rm -f "$src/nested/file.txt"
printf 'brand new\n' > "$src/new.txt"
live_before="$(live_digest)"
dest_before="$(ls -A "$dest")"

run_diff --diff --dest "$dest" --paths "$src"
assert_eq 'differences -> 1' 1 "$rc"
assert_contains 'a changed file is CHANGED' "$out" 'CHANGED'
assert_contains 'the changed file is named' "$(grep CHANGED <<<"$out")" 'payload.txt'
assert_contains 'the reason is given' "$(grep CHANGED <<<"$out")" 'Size differs'
assert_contains 'a deleted file is GONE' "$out" 'GONE'
assert_contains 'the deleted file is named' "$(grep GONE <<<"$out")" 'file.txt'
assert_contains 'an added file is NEW' "$out" 'NEW'
assert_contains 'the added file is named' "$(grep NEW <<<"$out")" 'new.txt'
assert_contains 'the summary counts one of each' "$out" '1 changed, 1 gone, 1 new'
assert_not_contains 'a parent directory is not reported for its mtime' "$out" "CHANGED $src "
assert_contains 'the one-file restore is suggested' "$out" 'tar -xzf'
assert_eq 'the restore is printed, never run' 0 "$([[ -e "$src/nested/file.txt" ]] && printf 1 || printf 0)"
assert_eq 'live files are byte-identical after --diff' "$live_before" "$(live_digest)"
assert_eq '--diff writes nothing into --dest (no staging, locks or archives)' "$dest_before" "$(ls -A "$dest")"

run_diff --diff "$archive" --paths "$src"
assert_eq '--diff FILE compares the named archive' 1 "$rc"
assert_contains '--diff FILE reports the change' "$out" 'CHANGED'

run_diff "--diff=$archive" --paths "$src"
assert_eq '--diff=FILE compares the named archive' 1 "$rc"
assert_contains '--diff=FILE reports the change' "$out" 'CHANGED'

run_diff --diff "$fixture/no-such-archive.tar.gz" --paths "$src"
assert_eq 'a missing FILE -> 3' 3 "$rc"

empty_dest="$fixture/empty-dest"
mkdir -p "$empty_dest"
run_diff --diff --dest "$empty_dest" --paths "$src"
assert_eq 'no archive in --dest -> 3' 3 "$rc"
assert_eq 'a refused --diff creates nothing in --dest' '' "$(ls -A "$empty_dest")"

run_diff --diff --list --dest "$dest"
assert_eq '--diff with --list -> 3' 3 "$rc"
run_diff --diff --yes --dest "$dest"
assert_eq '--diff with --yes -> 3' 3 "$rc"
run_diff --diff --dry-run --dest "$dest"
assert_eq '--diff with --dry-run -> 3' 3 "$rc"
run_diff --diff --dest "$dest" --paths /
assert_eq '--diff refuses to walk / -> 3' 3 "$rc"

# The newest archive is picked within --prefix, the same scope --keep uses: an
# archive under another prefix is not a "config" generation.
other_dest="$fixture/other-dest"
mkdir -p "$other_dest"
"$BACKUP" --yes --paths "$src" --dest "$other_dest" --prefix other --keep 0 >/dev/null 2>&1
assert_eq 'setup other-prefix archive written' 0 "$?"
run_diff --diff --dest "$other_dest" --paths "$src"
assert_eq 'an archive under another prefix is not picked -> 3' 3 "$rc"
run_diff --diff --dest "$other_dest" --prefix other --paths "$src"
assert_eq '--prefix selects that archive, and it matches the tree' 0 "$rc"

# An unreadable file is a SKIP, never a quiet pass. Root reads everything, and
# the Docker testers run as root, so there the check is that nothing is skipped.
chmod 000 "$src/payload.txt"
run_diff --diff --dest "$other_dest" --prefix other --paths "$src"
if [[ "$(id -u)" != 0 ]]; then
  assert_eq 'an unreadable file is not a clean result -> 1' 1 "$rc"
  assert_contains 'an unreadable file is a SKIP' "$out" 'SKIP'
  assert_contains 'the SKIP says how to fix it' "$out" 'rerun with sudo'
else
  assert_not_contains 'root can read every file, so nothing is skipped' "$out" 'SKIP'
  assert_contains 'root still sees the mode change' "$out" 'Mode differs'
fi
chmod 644 "$src/payload.txt"

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s config backup diff checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s config backup diff checks passed ===\n' "$checks"

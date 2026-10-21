#!/usr/bin/env bash
# config_backup.sh --exclude and --exclude-secrets: what the archive leaves
# out, how a bad pattern is refused, and that a dry run still writes nothing.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BACKUP="$REPO_ROOT/linux/config_backup.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
src="$fixture/src"
mkdir -p "$src/private" "$src/sub" || exit 1
printf 'keep\n' > "$src/keep.conf"
printf 'not a real key\n' > "$src/secret.key"
printf 'not a real identity\n' > "$src/private/id_x"
printf 'ok\n' > "$src/sub/ok.txt"
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
new_dest() {
  dest="$(mktemp -d "$fixture/dest.XXXXXXXX")" || exit 1
}
run_backup() {
  out="$("$BACKUP" --paths "$src" --dest "$dest" "$@" 2>&1)"
  rc=$?
}
# Member names of the one archive in $dest, or nothing.
members() {
  local archive
  for archive in "$dest"/*.tar.gz; do
    [[ -f "$archive" ]] && tar -tzf "$archive"
  done
}

new_dest
run_backup --yes --exclude '*.key'
assert_eq '--exclude *.key exits 0' 0 "$rc"
assert_contains '--exclude announces the pattern' "$out" 'exclude: *.key'
listing="$(members)"
assert_contains 'kept file is archived' "$listing" 'keep.conf'
assert_contains 'nested file is archived' "$listing" 'sub/ok.txt'
assert_not_contains 'excluded file is not archived' "$listing" 'secret.key'

new_dest
run_backup --yes --exclude '*.key' --exclude "${src#/}/private"
assert_eq 'two --exclude flags exit 0' 0 "$rc"
listing="$(members)"
assert_not_contains 'first pattern applied' "$listing" 'secret.key'
assert_not_contains 'second pattern drops the directory' "$listing" 'private'
assert_contains 'the rest is still archived' "$listing" 'keep.conf'

new_dest
run_backup --yes '--exclude=*.key'
assert_eq '--exclude=PATTERN exits 0' 0 "$rc"
assert_not_contains '--exclude=PATTERN applies' "$(members)" 'secret.key'

new_dest
run_backup --yes --exclude "$src/secret.key"
assert_eq 'an absolute pattern -> 3' 3 "$rc"
assert_contains 'an absolute pattern says why' "$out" 'relative to /'
run_backup --yes --exclude ''
assert_eq 'an empty pattern -> 3' 3 "$rc"
run_backup --yes --exclude
assert_eq '--exclude as the last argument -> 3' 3 "$rc"
run_backup --yes --exclude $'a\nb'
assert_eq 'a pattern with a newline -> 3' 3 "$rc"
run_backup --list --exclude '*.key'
assert_eq '--exclude with --list -> 3' 3 "$rc"
assert_eq 'refused runs wrote nothing' '' "$(ls -A "$dest")"

new_dest
run_backup --dry-run --exclude '*.key'
assert_eq '--dry-run --exclude exits 0' 0 "$rc"
assert_contains 'dry run names the exclusion' "$out" 'would exclude: *.key'
assert_contains 'dry run still closes with its summary' "$out" 'dry-run complete; no changes written'
assert_eq 'dry run writes nothing' '' "$(ls -A "$dest")"

# Excluding everything leaves tar nothing to write. The existing validation
# refuses an archive with no members, so nothing is published.
new_dest
run_backup --yes --exclude '*'
assert_eq 'excluding every member -> 1' 1 "$rc"
assert_contains 'excluding every member fails validation' "$out" 'failed validation'
assert_eq 'excluding every member leaves no archive or staging' '' "$(ls -A "$dest")"

new_dest
out="$("$BACKUP" --dry-run --exclude-secrets --paths /etc --dest "$dest" 2>&1)"; rc=$?
assert_eq '--exclude-secrets --dry-run exits 0' 0 "$rc"
assert_contains 'the preset excludes shadow' "$out" 'would exclude: etc/shadow*'
assert_contains 'the preset excludes ssl/private' "$out" 'would exclude: etc/ssl/private'
assert_contains 'the preset excludes host private keys' "$out" 'would exclude: etc/ssh/ssh_host_*_key'
assert_eq '--exclude-secrets --dry-run writes nothing' '' "$(ls -A "$dest")"

# A real /etc backup with the preset. The testers run as root, so shadow is
# readable and would be archived without it. A transient unreadable file can
# still make the run partial (exit 1); both outcomes publish an archive.
new_dest
out="$("$BACKUP" --yes --exclude-secrets --paths /etc --dest "$dest" --prefix excl --keep 0 2>&1)"; rc=$?
assert_eq '--exclude-secrets over /etc publishes an archive (exit 0 or 1)' yes \
  "$([[ "$rc" == 0 || "$rc" == 1 ]] && printf yes || printf 'no (exit %s)' "$rc")"
listing="$(members)"
etc_checks=0
if [[ -e /etc/shadow ]]; then
  etc_checks=$((etc_checks + 1))
  assert_eq '/etc/shadow is left out' '' "$(grep -x 'etc/shadow' <<<"$listing")"
fi
if [[ -e /etc/passwd ]]; then
  etc_checks=$((etc_checks + 1))
  assert_eq '/etc/passwd is still archived' 'etc/passwd' "$(grep -x 'etc/passwd' <<<"$listing")"
fi
if [[ -e /etc/passwd- ]]; then
  etc_checks=$((etc_checks + 1))
  assert_eq 'the passwd- backup copy is left out' '' "$(grep -x 'etc/passwd-' <<<"$listing")"
fi
assert_eq 'the /etc checks ran' yes "$( (( etc_checks >= 2 )) && printf yes || printf 'no (%s)' "$etc_checks")"

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s config backup exclude checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s config backup exclude checks passed ===\n' "$checks"

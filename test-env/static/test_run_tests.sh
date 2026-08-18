#!/usr/bin/env bash
# Behavioural checks for the repository test aggregator's automation options.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/ops-toolbox-run-tests.XXXXXX")" || exit 1
trap 'rm -rf "$tmp_root"' EXIT

cp "$REPO_ROOT/run-tests.sh" "$tmp_root/run-tests.sh"
mkdir -p "$tmp_root/k8s-toolbox/tests"
cat >"$tmp_root/k8s-toolbox/tests/run.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp_root/run-tests.sh" "$tmp_root/k8s-toolbox/tests/run.sh"

failures=0
check() {
  local description="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description" >&2
    failures=$(( failures + 1 ))
  fi
}

list_output="$tmp_root/list.txt"
# The exit status used to be discarded here, so --list could have regressed to
# exit 3 and still passed; and only two of the suites were checked for, so it
# could have dropped the other six unnoticed.
if "$tmp_root/run-tests.sh" --list >"$list_output"; then
  printf 'ok - --list exits 0\n'
else
  printf 'not ok - --list exits 0\n' >&2
  failures=$(( failures + 1 ))
fi
for suite in git macos linux k8s python static windows mikrotik; do
  check "--list emits the $suite suite" grep -q "^$suite"$'\t' "$list_output"
done

summary_file="$tmp_root/results.json"
run_output="$tmp_root/run.txt"
if "$tmp_root/run-tests.sh" --summary-file "$summary_file" k8s >"$run_output"; then
  printf 'ok - a passing run exits 0\n'
else
  printf 'not ok - a passing run exits 0\n' >&2
  failures=$(( failures + 1 ))
fi
check "the selected fake suite runs" grep -q '^=== k8s ===$' "$run_output"
check "the JSON summary is published" test -f "$summary_file"
check "the JSON summary records a passing suite" \
  grep -Eq '^\{"overall":"pass","suites":\[\{"name":"k8s","status":"pass","duration_seconds":[0-9]+,"exit_code":0\}\]\}$' \
  "$summary_file"

if "$tmp_root/run-tests.sh" --summary-file >/dev/null 2>&1; then
  printf 'not ok - --summary-file rejects a missing value\n' >&2
  failures=$(( failures + 1 ))
else
  printf 'ok - --summary-file rejects a missing value\n'
fi

mkdir "$tmp_root/summary-directory"
if "$tmp_root/run-tests.sh" --summary-file "$tmp_root/summary-directory" k8s >/dev/null 2>&1; then
  printf 'not ok - --summary-file rejects a directory target\n' >&2
  failures=$(( failures + 1 ))
else
  printf 'ok - --summary-file rejects a directory target\n'
fi

# A suite whose runner is missing is a skip, and a skip left `overall` alone —
# so a checkout where every runner was absent reported "all selected suites
# passed" and wrote {"overall":"pass"} having run nothing. CI consuming that
# JSON would see a green build over zero executed tests.
empty_root="$tmp_root/empty"
mkdir -p "$empty_root"
cp "$tmp_root/run-tests.sh" "$empty_root/run-tests.sh"
empty_summary="$empty_root/results.json"
if "$empty_root/run-tests.sh" --summary-file "$empty_summary" k8s python >/dev/null 2>&1; then
  printf 'not ok - a run with every suite skipped must not exit 0\n' >&2
  failures=$(( failures + 1 ))
else
  printf 'ok - a run with every suite skipped must not exit 0\n'
fi
check "the JSON summary reports an empty run rather than a pass" \
  grep -q '^{"overall":"empty"' "$empty_summary"

if (( failures > 0 )); then
  printf '%s run-tests.sh contract check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all run-tests.sh contract checks passed\n'

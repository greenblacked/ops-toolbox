#!/usr/bin/env bash
# Behavioural checks for the repository test aggregator's automation options.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/ops-toolbox-run-tests.XXXXXX")" || exit 1
trap 'rm -rf "$tmp_root"' EXIT

cp "$REPO_ROOT/run-tests.sh" "$tmp_root/run-tests.sh"
chmod +x "$tmp_root/run-tests.sh"

# A fake suite runner in the scratch tree, so what is under test is the
# aggregator and nothing else. Each one appends the arguments it was handed to
# an argv file beside it, one line per invocation, one bracket pair per word.
# That file is the evidence an assertion needs: a suite that ran and failed and
# a suite that was never there both make run-tests.sh exit non-zero, and only
# the file tells them apart. Bracketing each word separately catches the other
# half — an argument list that arrives re-split rather than not at all.
make_runner() {
  local runner="$1" code="$2" dir
  dir="${runner%/*}"
  mkdir -p "$dir"
  cat >"$runner" <<EOF
#!/usr/bin/env bash
argv=""
for a in "\$@"; do argv="\$argv[\$a]"; done
printf '%s\n' "\$argv" >>"$dir/argv.txt"
exit $code
EOF
  chmod +x "$runner"
}

# dotfiles fails with 3 rather than 1 so that an exit code reported in the JSON
# summary has to have come from the suite instead of from a constant. None of
# the three needs Docker, which is what lets this file run in the static suite.
make_runner "$tmp_root/k8s-toolbox/tests/run.sh" 0
make_runner "$tmp_root/windows/tests/run.sh" 0
make_runner "$tmp_root/dotfiles/tests/run.sh" 3

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

# argv_is FILE EXPECTED — the runner beside FILE ran, and was handed exactly
# EXPECTED (bracketed words; empty for no arguments). The absent-file case is
# reported on its own because it is the interesting one: it means the suite
# never ran, and an assertion resting on an exit code alone would have passed.
argv_is() {
  local file="$1" want="$2" got
  if [[ ! -f "$file" ]]; then
    printf 'the runner never ran: %s was not written\n' "$file" >&2
    return 1
  fi
  got="$(cat "$file")"
  [[ "$got" == "$want" ]] && return 0
  printf 'expected argv %s, got %s\n' "${want:-<none>}" "${got:-<none>}" >&2
  return 1
}

# ran_count FILE N — the runner beside FILE ran exactly N times.
ran_count() {
  local file="$1" want="$2" got=0
  [[ -f "$file" ]] && got=$(( $(wc -l <"$file") ))
  [[ "$got" == "$want" ]] && return 0
  printf 'expected %s run(s) of %s, got %s\n' "$want" "${file%/argv.txt}/run.sh" "$got" >&2
  return 1
}

# json_suite_count FILE NAME N — the summary names suite NAME exactly N times.
# Counted by chewing through the string rather than with `grep -o ... | wc -l`:
# under `set -o pipefail` a reader that exits before the writer is done turns
# the whole pipeline into a 141, so a match reads as a miss. This repository
# has been bitten by that three times, most recently in changelog.sh preview.
json_suite_count() {
  local file="$1" name="$2" want="$3" rest needle got=0
  if [[ ! -f "$file" ]]; then
    printf 'no summary was written: %s\n' "$file" >&2
    return 1
  fi
  rest="$(cat "$file")"
  needle="\"name\":\"$name\""
  while [[ "$rest" == *"$needle"* ]]; do
    got=$(( got + 1 ))
    rest="${rest#*"$needle"}"
  done
  [[ "$got" == "$want" ]] && return 0
  printf 'expected %s %s row(s) in %s, got %s\n' "$want" "$name" "$file" "$got" >&2
  return 1
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
for suite in git macos linux k8s dotfiles python static windows mikrotik; do
  check "--list emits the $suite suite" grep -q "^$suite"$'\t' "$list_output"
done
# The second column is the package directory CI matches changed files
# against. A suite whose column is empty or points at a directory that does
# not exist would silently never run on a pull request.
packages_exist() {
  local name pkg
  while IFS=$'\t' read -r name pkg _; do
    [ -n "$pkg" ] && [ -d "$REPO_ROOT/$pkg" ] && continue
    printf '%s -> %s is not a directory\n' "$name" "${pkg:-<empty>}" >&2
    return 1
  done < "$list_output"
}
check "--list names an existing package directory for every suite" packages_exist

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

# --- a failing suite -------------------------------------------------------
# The single property every CI verdict rests on: a suite that fails makes
# run-tests.sh exit non-zero and says so in the JSON. Until this block, every
# fake runner in this file exited 0, so the `overall=1` branch of run_suite and
# the fail arm of write_json_summary's state mapping had never once been
# executed here. A regression in either leaves each `Test / <suite>` job green,
# and the `exit "$rc"` in ci.yml and chr.yml green with it, while the suites
# underneath are failing.
fail_summary="$tmp_root/failing.json"
fail_output="$tmp_root/failing.txt"
rm -f "$tmp_root/dotfiles/tests/argv.txt"
if "$tmp_root/run-tests.sh" --summary-file "$fail_summary" dotfiles >"$fail_output" 2>&1; then
  printf 'not ok - a failing suite must not exit 0\n' >&2
  failures=$(( failures + 1 ))
else
  printf 'ok - a failing suite must not exit 0\n'
fi
# Without this the assertion above is just as happy when the runner was never
# there: a missing runner is a skip, and a run of nothing but skips is also
# non-zero. Same code, entirely different reason.
check "the failing suite actually ran, rather than being skipped" \
  argv_is "$tmp_root/dotfiles/tests/argv.txt" ""
check "the summary line reports the failure and the suite's own exit code" \
  grep -Eq 'FAIL[[:space:]]+dotfiles .*exit 3' "$fail_output"
check "the run ends by saying a suite failed" \
  grep -q '^one or more suites failed$' "$fail_output"
check "the JSON summary records the failure" \
  grep -Eq '^\{"overall":"fail","suites":\[\{"name":"dotfiles","status":"fail","duration_seconds":[0-9]+,"exit_code":3\}\]\}$' \
  "$fail_summary"

# --- a mixed run -----------------------------------------------------------
# The failing suite is named first and the passing one last, so an aggregator
# that kept only the most recent result — `overall=$rc` in run_suite, which is
# one edit away — would call this run a pass. Both rows have to reach the
# summary, in the order they ran: CI reads that matrix by name.
mixed_summary="$tmp_root/mixed.json"
mixed_output="$tmp_root/mixed.txt"
rm -f "$tmp_root/dotfiles/tests/argv.txt" "$tmp_root/k8s-toolbox/tests/argv.txt"
if "$tmp_root/run-tests.sh" --summary-file "$mixed_summary" dotfiles k8s >"$mixed_output" 2>&1; then
  printf 'not ok - a failing suite followed by a passing one must not exit 0\n' >&2
  failures=$(( failures + 1 ))
else
  printf 'ok - a failing suite followed by a passing one must not exit 0\n'
fi
check "the failing suite ran in the mixed run" \
  argv_is "$tmp_root/dotfiles/tests/argv.txt" ""
check "the passing suite ran in the mixed run" \
  argv_is "$tmp_root/k8s-toolbox/tests/argv.txt" ""
mixed_re='^\{"overall":"fail","suites":\['
mixed_re="$mixed_re"'\{"name":"dotfiles","status":"fail","duration_seconds":[0-9]+,"exit_code":3\},'
mixed_re="$mixed_re"'\{"name":"k8s","status":"pass","duration_seconds":[0-9]+,"exit_code":0\}\]\}$'
check "the JSON summary keeps both verdicts, in the order they ran" \
  grep -Eq "$mixed_re" "$mixed_summary"

# --- arguments after `--` --------------------------------------------------
# --help has promised since the beginning that trailing arguments reach the
# last named suite, and .github/workflows/chr.yml and routeros-version.yml take
# it up: both run `run-tests.sh mikrotik -- -k ...` to select a single test out
# of the CHR suite. Arguments that stopped arriving would not fail anything —
# the workflow would silently run the whole suite instead, which looks like a
# slow pass. The words are bracketed one at a time because the failure mode is
# re-splitting as much as loss: an argument with a space has to arrive whole.
passthru_output="$tmp_root/passthru.txt"
rm -f "$tmp_root/k8s-toolbox/tests/argv.txt" "$tmp_root/windows/tests/argv.txt"
if "$tmp_root/run-tests.sh" k8s windows -- -k "version matches" --maxfail=1 \
  >"$passthru_output" 2>&1; then
  printf 'ok - a run with passthrough arguments exits 0\n'
else
  printf 'not ok - a run with passthrough arguments exits 0\n' >&2
  failures=$(( failures + 1 ))
fi
check "everything after -- reaches the last named suite, unsplit" \
  argv_is "$tmp_root/windows/tests/argv.txt" '[-k][version matches][--maxfail=1]'
check "an earlier suite in the same run is handed nothing" \
  argv_is "$tmp_root/k8s-toolbox/tests/argv.txt" ""

if "$tmp_root/run-tests.sh" --summary-file >/dev/null 2>&1; then
  printf 'not ok - --summary-file rejects a missing value\n' >&2
  failures=$(( failures + 1 ))
else
  printf 'ok - --summary-file rejects a missing value\n'
fi

# --- --summary-file=VALUE --------------------------------------------------
# The space-separated form is covered above. The equals form is a separate
# branch of the argument loop with its own empty-value check, and nothing else
# in the repository exercises it, so it could have stopped writing the file —
# or stopped rejecting `--summary-file=` — without anything noticing.
equals_summary="$tmp_root/equals.json"
rm -f "$tmp_root/k8s-toolbox/tests/argv.txt"
if "$tmp_root/run-tests.sh" "--summary-file=$equals_summary" k8s >/dev/null 2>&1; then
  printf 'ok - --summary-file=VALUE is accepted\n'
else
  printf 'not ok - --summary-file=VALUE is accepted\n' >&2
  failures=$(( failures + 1 ))
fi
check "the named suite ran under the equals form" \
  argv_is "$tmp_root/k8s-toolbox/tests/argv.txt" ""
check "the equals form writes the same JSON to the path it names" \
  grep -Eq '^\{"overall":"pass","suites":\[\{"name":"k8s","status":"pass","duration_seconds":[0-9]+,"exit_code":0\}\]\}$' \
  "$equals_summary"

if "$tmp_root/run-tests.sh" --summary-file= k8s >/dev/null 2>&1; then
  printf 'not ok - --summary-file= rejects an empty value\n' >&2
  failures=$(( failures + 1 ))
else
  printf 'ok - --summary-file= rejects an empty value\n'
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

# --- deduplication ---------------------------------------------------------
# `run-tests.sh all git` is the documented way to add one suite to the default
# set, and both halves of it name git. Run twice, a Docker suite spends its
# minutes twice, and the JSON summary carries two rows under one name into a
# matrix CI keys by name.
dedup_root="$tmp_root/dedup"
mkdir -p "$dedup_root/bin"
cp "$tmp_root/run-tests.sh" "$dedup_root/run-tests.sh"
# `all` selects the Docker suites, and the preflight refuses to go any further
# without a reachable daemon — which is the state of every host this file is
# meant to run on, the static suite being the one that needs no Docker. The
# stub answers the three probes (command -v, compose version, info) so the
# selection logic behind them can be reached at all. No fake runner calls it.
cat >"$dedup_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$dedup_root/run-tests.sh" "$dedup_root/bin/docker"
make_runner "$dedup_root/git/tests/run.sh" 0
dedup_summary="$dedup_root/results.json"
if PATH="$dedup_root/bin:$PATH" "$dedup_root/run-tests.sh" \
  --summary-file "$dedup_summary" all git >"$dedup_root/run.txt" 2>&1; then
  printf 'ok - all git gets past the Docker preflight and exits 0\n'
else
  printf 'not ok - all git gets past the Docker preflight and exits 0\n' >&2
  failures=$(( failures + 1 ))
fi
check "all git runs the git suite exactly once" \
  ran_count "$dedup_root/git/tests/argv.txt" 1
check "all git writes exactly one git row into the JSON summary" \
  json_suite_count "$dedup_summary" git 1

if (( failures > 0 )); then
  printf '%s run-tests.sh contract check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all run-tests.sh contract checks passed\n'

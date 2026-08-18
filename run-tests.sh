#!/usr/bin/env bash
# Single entrypoint for every test suite in this repository.
#
# CI calls this exact script, so "it passed locally" and "it passed in CI" mean
# the same thing. Each suite is delegated to its own tests/run.sh rather than
# reimplemented here — this file only selects, sequences, and reports.
#
#   ./run-tests.sh              # the fast default
#   ./run-tests.sh all          # the above, plus the CHR integration suite
#   ./run-tests.sh git macos    # an explicit subset
#   ./run-tests.sh --list       # machine-friendly suite inventory
#   ./run-tests.sh --summary-file results.json linux
#   ./run-tests.sh mikrotik -- -k version_matches   # trailing args go to the suite
#
# Exit code is 0 only if every selected suite passed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || { echo "cannot enter $HERE" >&2; exit 1; }

C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_BOLD=""
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
fi

# --- the suite table -------------------------------------------------------
# One place to add a suite. Everything below — the help text, the argument
# validation, the fast/all sets, the Docker preflight and the dispatch — is
# derived from these four definitions rather than repeating the list.
#
# Kept as space-separated strings and case statements because these scripts
# must run under the Bash 3.2 that ships on macOS, which has no associative
# arrays. See CONTRIBUTING.md.

SUITE_ALL="git macos linux k8s python static windows mikrotik"
SUITE_FAST="git macos linux k8s python static windows"

suite_runner() {
  case "$1" in
    git)      printf '%s\n' "$HERE/git/tests/run.sh" ;;
    macos)    printf '%s\n' "$HERE/macos-initial-setup/tests/run.sh" ;;
    linux)    printf '%s\n' "$HERE/linux/tests/run.sh" ;;
    k8s)      printf '%s\n' "$HERE/k8s-toolbox/tests/run.sh" ;;
    python)   printf '%s\n' "$HERE/test-env/python/run.sh" ;;
    static)   printf '%s\n' "$HERE/test-env/static/run.sh" ;;
    windows)  printf '%s\n' "$HERE/windows/tests/run.sh" ;;
    mikrotik) printf '%s\n' "$HERE/mikrotik/tests/run.sh" ;;
  esac
}

# Whether a suite needs a working Docker daemon. This used to be decided by
# name — `[[ "$s" == "python" ]] || need_docker=1` — which meant every suite
# added afterwards was assumed to need Docker and would hard-fail on a host
# without it, even when it needed nothing but bash.
suite_needs_docker() {
  case "$1" in
    git|macos|linux|mikrotik) return 0 ;;
    # k8s is contract checks only. The package builds a container image, but
    # the suite deliberately does not: that build is opt-in behind
    # K8S_IMAGE_SMOKE=1, and its own runner checks for Docker when asked.
    *)                        return 1 ;;
  esac
}

suite_blurb() {
  case "$1" in
    git)      printf '%s\n' "Git helper scripts        (Docker, ~30s)" ;;
    macos)    printf '%s\n' "macOS setup scripts       (Docker, ~30s)" ;;
    linux)    printf '%s\n' "Linux scripts, run for real (Docker; LINUX_DISTROS=all for 3 distros)" ;;
    k8s)      printf '%s\n' "k8s-toolbox script contracts (bash only; K8S_IMAGE_SMOKE=1 builds the image)" ;;
    python)   printf '%s\n' "Python libs: ruff + pytest (host python3, no Docker)" ;;
    static)   printf '%s\n' "Repo-wide conventions     (bash + git only, no Docker)" ;;
    windows)  printf '%s\n' "PowerShell contract checks (pwsh, no Docker; skipped without it)" ;;
    mikrotik) printf '%s\n' "RouterOS CHR integration  (Docker + QEMU, minutes — not in default)" ;;
  esac
}

suite_is_known() {
  local candidate="$1" s
  for s in $SUITE_ALL; do
    [[ "$s" == "$candidate" ]] && return 0
  done
  return 1
}

usage() {
  local s
  printf 'Usage: run-tests.sh [suite...] [-- suite-args...]\n\n'
  printf 'Suites:\n'
  for s in $SUITE_ALL; do
    printf '  %-9s %s\n' "$s" "$(suite_blurb "$s")"
  done
  printf '\n'
  printf '  %-9s %s\n' "fast" "$SUITE_FAST  (the default when no suite is named)"
  printf '  %-9s %s\n' "all"  "fast + mikrotik"
  printf '\n'
  printf 'Options:\n'
  printf '  --list                List suite names and descriptions, then exit\n'
  printf '  --summary-file PATH   Write a JSON result matrix after the run\n'
  printf '  -h, --help            Show this help\n\n'
  printf 'Any arguments after a lone `--` are forwarded to the last named suite.\n'
}

# --- suite selection -------------------------------------------------------
suites=()
passthru=()
seen_ddash=0
LIST_ONLY=0
SUMMARY_FILE=""
while (( $# > 0 )); do
  arg="$1"
  shift
  if (( seen_ddash )); then
    passthru+=("$arg"); continue
  fi
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --list)    LIST_ONLY=1 ;;
    --summary-file)
      if (( $# == 0 )) || [[ -z "$1" || "$1" == --* ]]; then
        echo "--summary-file requires a value" >&2
        exit 3
      fi
      SUMMARY_FILE="$1"
      shift
      ;;
    --summary-file=*)
      SUMMARY_FILE="${arg#*=}"
      if [[ -z "$SUMMARY_FILE" ]]; then
        echo "--summary-file requires a value" >&2
        exit 3
      fi
      ;;
    --)        seen_ddash=1 ;;
    fast)      for s in $SUITE_FAST; do suites+=("$s"); done ;;
    all)       for s in $SUITE_ALL;  do suites+=("$s"); done ;;
    *)
      if suite_is_known "$arg"; then
        suites+=("$arg")
      else
        echo "unknown suite: $arg" >&2
        echo >&2
        usage >&2
        exit 3
      fi
      ;;
  esac
done

if (( LIST_ONLY )); then
  for s in $SUITE_ALL; do
    printf '%s\t%s\n' "$s" "$(suite_blurb "$s")"
  done
  exit 0
fi
if (( ${#suites[@]} == 0 )); then
  for s in $SUITE_FAST; do suites+=("$s"); done
fi

# `run-tests.sh all git` or `fast python` would otherwise run a suite twice.
deduped=()
for s in "${suites[@]}"; do
  seen=0
  for d in ${deduped[@]+"${deduped[@]}"}; do
    [[ "$d" == "$s" ]] && { seen=1; break; }
  done
  (( seen )) || deduped+=("$s")
done
suites=("${deduped[@]}")

need_docker=0
for s in "${suites[@]}"; do
  suite_needs_docker "$s" && need_docker=1
done
if (( need_docker )); then
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required for the selected suites" >&2
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "docker compose v2 plugin is required for the selected suites" >&2
    exit 1
  fi
  # A stopped daemon is the single most common local failure; say so plainly
  # rather than letting each suite fail with a socket error.
  if ! docker info >/dev/null 2>&1; then
    echo "the docker daemon is not reachable — start Docker/OrbStack first" >&2
    exit 1
  fi
fi

# --- run -------------------------------------------------------------------
declare -a results=()
declare -a result_names=()
declare -a result_states=()
declare -a result_durations=()
declare -a result_codes=()
overall=0

run_suite() {
  local name="$1"; shift
  local start end dur rc
  # A suite whose runner isn't present is reported as skipped, not failed, so a
  # partially-built checkout still gives a useful summary instead of noise.
  if [[ ! -x "$1" ]]; then
    results+=("$C_YELLOW skip $C_RESET $name ${C_DIM}(no runner at ${1#"$HERE"/})${C_RESET}")
    result_names+=("$name")
    result_states+=("skip")
    result_durations+=("0")
    result_codes+=("0")
    printf "\n%s=== %s (skipped) ===%s\n" "$C_BOLD" "$name" "$C_RESET"
    return 0
  fi
  printf "\n%s=== %s ===%s\n" "$C_BOLD" "$name" "$C_RESET"
  start=$(date +%s)
  "$@"
  rc=$?
  end=$(date +%s)
  dur=$(( end - start ))
  if (( rc == 0 )); then
    results+=("$C_GREEN pass $C_RESET $name ${C_DIM}(${dur}s)${C_RESET}")
    result_states+=("pass")
  else
    results+=("$C_RED FAIL $C_RESET $name ${C_DIM}(${dur}s, exit $rc)${C_RESET}")
    result_states+=("fail")
    overall=1
  fi
  result_names+=("$name")
  result_durations+=("$dur")
  result_codes+=("$rc")
  return 0
}

# Trailing args go to the last named suite, which is what --help has always
# promised. Suites that take no arguments ignore them.
last_index=$(( ${#suites[@]} - 1 ))
for i in "${!suites[@]}"; do
  s="${suites[$i]}"
  if (( i == last_index )); then
    run_suite "$s" "$(suite_runner "$s")" ${passthru[@]+"${passthru[@]}"}
  else
    run_suite "$s" "$(suite_runner "$s")"
  fi
done

printf "\n%s=== summary ===%s\n" "$C_BOLD" "$C_RESET"
for line in "${results[@]}"; do
  printf "  %s\n" "$line"
done

write_json_summary() {
  local target="$1" dir tmp i comma overall_state
  dir="${target%/*}"
  [[ "$dir" == "$target" ]] && dir="."
  if [[ -e "$target" && ! -f "$target" ]]; then
    printf 'summary-file target is not a regular file: %s\n' "$target" >&2
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    printf 'summary-file parent directory does not exist: %s\n' "$dir" >&2
    return 1
  fi
  tmp="${target}.tmp.$$"
  if (( suites_ran == 0 )); then
    overall_state="empty"
  elif (( overall == 0 )); then
    overall_state="pass"
  else
    overall_state="fail"
  fi
  if ! {
    printf '{"overall":"%s","suites":[' "$overall_state"
    comma=""
    for i in "${!result_names[@]}"; do
      printf '%s{"name":"%s","status":"%s","duration_seconds":%s,"exit_code":%s}' \
        "$comma" "${result_names[$i]}" "${result_states[$i]}" \
        "${result_durations[$i]}" "${result_codes[$i]}"
      comma=","
    done
    printf ']}\n'
  } >"$tmp"; then
    rm -f "$tmp"
    printf 'could not write summary file: %s\n' "$target" >&2
    return 1
  fi
  if ! mv "$tmp" "$target"; then
    rm -f "$tmp"
    printf 'could not publish summary file: %s\n' "$target" >&2
    return 1
  fi
  printf 'JSON summary: %s\n' "$target"
}

# A suite whose runner is missing is recorded as a skip and leaves `overall`
# alone, which is right for one suite out of several. When it is *every* suite —
# a partial checkout, a bad path, a wrong working directory — the old summary
# said "all selected suites passed" and wrote {"overall":"pass"} having executed
# nothing at all. Reporting success without checking anything is the failure
# this repository cares most about, so count what actually ran.
suites_ran=0
for state in ${result_states[@]+"${result_states[@]}"}; do
  [[ "$state" == "skip" ]] || suites_ran=$((suites_ran + 1))
done
if (( ${#result_states[@]} > 0 && suites_ran == 0 )); then
  overall=1
fi

if [[ -n "$SUMMARY_FILE" ]] && ! write_json_summary "$SUMMARY_FILE"; then
  overall=1
fi

if (( ${#result_states[@]} > 0 && suites_ran == 0 )); then
  printf "\n%sno suite actually ran — every selected suite was skipped%s\n" \
    "$C_RED" "$C_RESET"
  printf "check that the runners exist; a partial checkout looks like this\n"
elif (( overall == 0 )); then
  printf "\n%sall selected suites passed%s\n" "$C_GREEN" "$C_RESET"
else
  printf "\n%sone or more suites failed%s\n" "$C_RED" "$C_RESET"
fi
exit "$overall"

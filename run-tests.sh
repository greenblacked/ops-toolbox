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

SUITE_ALL="git macos python static mikrotik"
SUITE_FAST="git macos python static"

suite_runner() {
  case "$1" in
    git)      printf '%s\n' "$HERE/git/tests/run.sh" ;;
    macos)    printf '%s\n' "$HERE/macos-initial-setup/tests/run.sh" ;;
    python)   printf '%s\n' "$HERE/test-env/python/run.sh" ;;
    static)   printf '%s\n' "$HERE/test-env/static/run.sh" ;;
    mikrotik) printf '%s\n' "$HERE/mikrotik/tests/run.sh" ;;
  esac
}

# Whether a suite needs a working Docker daemon. This used to be decided by
# name — `[[ "$s" == "python" ]] || need_docker=1` — which meant every suite
# added afterwards was assumed to need Docker and would hard-fail on a host
# without it, even when it needed nothing but bash.
suite_needs_docker() {
  case "$1" in
    git|macos|mikrotik) return 0 ;;
    *)                  return 1 ;;
  esac
}

suite_blurb() {
  case "$1" in
    git)      printf '%s\n' "Git helper scripts        (Docker, ~30s)" ;;
    macos)    printf '%s\n' "macOS setup scripts       (Docker, ~30s)" ;;
    python)   printf '%s\n' "Python libs: ruff + pytest (host python3, no Docker)" ;;
    static)   printf '%s\n' "Repo-wide conventions     (bash + git only, no Docker)" ;;
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
  printf '  -h, --help   Show this help\n\n'
  printf 'Any arguments after a lone `--` are forwarded to the last named suite.\n'
}

# --- suite selection -------------------------------------------------------
suites=()
passthru=()
seen_ddash=0
for arg in "$@"; do
  if (( seen_ddash )); then
    passthru+=("$arg"); continue
  fi
  case "$arg" in
    -h|--help) usage; exit 0 ;;
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
overall=0

run_suite() {
  local name="$1"; shift
  local start end dur rc
  # A suite whose runner isn't present is reported as skipped, not failed, so a
  # partially-built checkout still gives a useful summary instead of noise.
  if [[ ! -x "$1" ]]; then
    results+=("$C_YELLOW skip $C_RESET $name ${C_DIM}(no runner at ${1#"$HERE"/})${C_RESET}")
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
  else
    results+=("$C_RED FAIL $C_RESET $name ${C_DIM}(${dur}s, exit $rc)${C_RESET}")
    overall=1
  fi
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

if (( overall == 0 )); then
  printf "\n%sall selected suites passed%s\n" "$C_GREEN" "$C_RESET"
else
  printf "\n%sone or more suites failed%s\n" "$C_RED" "$C_RESET"
fi
exit "$overall"

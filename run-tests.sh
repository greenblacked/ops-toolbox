#!/usr/bin/env bash
# Single entrypoint for every test suite in this repository.
#
# CI calls this exact script, so "it passed locally" and "it passed in CI" mean
# the same thing. Each suite is delegated to its own tests/run.sh rather than
# reimplemented here — this file only selects, sequences, and reports.
#
#   ./run-tests.sh              # git + macos + python  (the fast default)
#   ./run-tests.sh all          # the above, plus the CHR integration suite
#   ./run-tests.sh git macos    # an explicit subset
#   ./run-tests.sh mikrotik -k version_matches   # trailing args go to the suite
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

usage() {
  cat <<'EOF'
Usage: run-tests.sh [suite...] [-- suite-args...]

Suites:
  git        Git helper scripts        (Docker, ~30s)
  macos      macOS setup scripts       (Docker, ~30s)
  python     Python libs: ruff + pytest (host /usr/bin/python3, no Docker)
  mikrotik   RouterOS CHR integration  (Docker + QEMU, minutes — not in default)

  fast       git + macos + python  (the default when no suite is named)
  all        fast + mikrotik

Options:
  -h, --help   Show this help

Any arguments after a lone `--` are forwarded to the last named suite.
EOF
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
    fast)      suites+=(git macos python) ;;
    all)       suites+=(git macos python mikrotik) ;;
    git|macos|python|mikrotik) suites+=("$arg") ;;
    *)
      echo "unknown suite: $arg" >&2
      echo >&2
      usage >&2
      exit 3
      ;;
  esac
done
if (( ${#suites[@]} == 0 )); then
  suites=(git macos python)
fi

need_docker=0
for s in "${suites[@]}"; do
  [[ "$s" == "python" ]] || need_docker=1
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

for s in "${suites[@]}"; do
  case "$s" in
    git)      run_suite "git"      "$HERE/git/tests/run.sh" ;;
    macos)    run_suite "macos"    "$HERE/macos-initial-setup/tests/run.sh" ;;
    python)   run_suite "python"   "$HERE/test-env/python/run.sh" ;;
    mikrotik) run_suite "mikrotik" "$HERE/mikrotik/tests/run.sh" ${passthru[@]+"${passthru[@]}"} ;;
  esac
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

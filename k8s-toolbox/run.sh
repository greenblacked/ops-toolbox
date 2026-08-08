#!/usr/bin/env bash
# run.sh
# Run an interactive k8s-toolbox container with the current directory mounted.
#
# Usage:
#   ./run.sh [--tag TAG] [--root] [--no-kubeconfig] [--dry-run] [-- CMD...]
#
# Exit codes:
#   0 success
#   1 docker failed
#   2 preflight failed
#   3 bad arguments
set -euo pipefail

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

usage() {
  cat <<EOF
$(basename "$0") - run the k8s-toolbox image interactively

Usage:
  $(basename "$0") [--tag TAG] [--root] [--no-kubeconfig] [--dry-run] [-- CMD...]

Options:
  --tag TAG         Image tag (default: k8s-toolbox:local)
  --root            Run as uid 0 (kubeconfig mounts at /root/.kube)
  --no-kubeconfig   Do not mount ~/.kube
  --dry-run         Print the docker run command and exit
  -h, --help        Show this help
  --                Pass remaining args to the container

Defaults:
  CMD: bash

Exit codes: 0 success, 1 failure, 2 wrong environment, 3 usage
EOF
}

tag="k8s-toolbox:local"
run_as_root="false"
mount_kubeconfig="true"
DRY_RUN=0
cmd=()

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tag) require_value "$1" "${2:-}"; tag="$2"; shift ;;
    --tag=*) tag="${1#*=}"; require_value "--tag" "$tag" ;;
    --root) run_as_root="true" ;;
    --no-kubeconfig) mount_kubeconfig="false" ;;
    --dry-run) DRY_RUN=1 ;;
    --) shift; cmd+=("$@"); break ;;
    -*)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
    *) cmd+=("$1") ;;
  esac
  shift
done

if [[ ${#cmd[@]} -eq 0 ]]; then
  cmd=("bash")
fi

# A preview answers on a machine without Docker; see build.sh for the reasoning.
if ! command -v docker >/dev/null 2>&1; then
  if (( DRY_RUN == 1 )); then
    warn "docker is not installed; printing the command anyway"
  else
    err "docker is not installed or not on PATH"
    exit 2
  fi
fi

args=(run --rm -it)

if [[ "$run_as_root" == "true" ]]; then
  args+=(--user 0)
fi

args+=(
  -v "${PWD}:/work"
  -w /work
)

if [[ "$mount_kubeconfig" == "true" && -d "${HOME}/.kube" ]]; then
  if [[ "$run_as_root" == "true" ]]; then
    args+=(-v "${HOME}/.kube:/root/.kube:ro")
  else
    args+=(-v "${HOME}/.kube:/home/toolbox/.kube:ro")
  fi
elif [[ "$mount_kubeconfig" == "true" ]]; then
  warn "${HOME}/.kube not found; continuing without a kubeconfig mount"
fi

docker_cmd=(docker "${args[@]}" "$tag" "${cmd[@]}")

if (( DRY_RUN == 1 )); then
  printf "dry-run: would run:"
  printf " %q" "${docker_cmd[@]}"
  printf "\n"
  printf "dry-run complete; no changes written\n"
  exit 0
fi

exec "${docker_cmd[@]}"

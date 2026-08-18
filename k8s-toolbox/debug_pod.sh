#!/usr/bin/env bash
# debug_pod.sh
# Wrap kubectl debug for an ephemeral troubleshooting container.
#
# Usage:
#   ./debug_pod.sh --pod NAME [--namespace NS] [--target CONTAINER]
#                  [--image IMAGE] [--no-tty] [--dry-run] [-- COMMAND...]
#
# Exit codes:
#   0 success
#   1 kubectl failed
#   2 kubectl missing
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
$(basename "$0") - attach an ephemeral debug container with kubectl debug

Usage:
  $(basename "$0") --pod NAME [--namespace NS] [--target CONTAINER]
                 [--image IMAGE] [--context CTX] [--no-tty] [--dry-run]
                 [-- COMMAND...]

Options:
  --pod NAME            Pod to debug (required)
  --namespace NS, -n NS Namespace (default: current context namespace)
  --target CONTAINER    Container to share the process namespace with
  --image IMAGE         Debug image (default: k8s-toolbox:local)
  --context CTX         kubectl context
  --no-tty              Do not attach stdin/TTY (for one-shot commands and CI)
  --dry-run             Print the kubectl debug command and exit
  -- COMMAND...         Command in the debug container (default: bash)
  -h, --help            Show this help

Exit codes: 0 success, 1 failure, 2 wrong environment, 3 usage
EOF
}

POD=""
NAMESPACE=""
TARGET=""
IMAGE="k8s-toolbox:local"
CONTEXT=""
DRY_RUN=0
NO_TTY=0
DEBUG_COMMAND=()

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pod) require_value "$1" "${2:-}"; POD="$2"; shift ;;
    --pod=*) POD="${1#*=}"; require_value "--pod" "$POD" ;;
    -n|--namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; shift ;;
    --namespace=*) NAMESPACE="${1#*=}"; require_value "--namespace" "$NAMESPACE" ;;
    --target) require_value "$1" "${2:-}"; TARGET="$2"; shift ;;
    --target=*) TARGET="${1#*=}"; require_value "--target" "$TARGET" ;;
    --image) require_value "$1" "${2:-}"; IMAGE="$2"; shift ;;
    --image=*) IMAGE="${1#*=}"; require_value "--image" "$IMAGE" ;;
    --context) require_value "$1" "${2:-}"; CONTEXT="$2"; shift ;;
    --context=*) CONTEXT="${1#*=}"; require_value "--context" "$CONTEXT" ;;
    --no-tty) NO_TTY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --) shift; DEBUG_COMMAND=("$@"); break ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

if (( ${#DEBUG_COMMAND[@]} == 0 )); then
  DEBUG_COMMAND=(bash)
fi

if [[ -z "$POD" ]]; then
  err "--pod is required"
  usage >&2
  exit 3
fi

# A preview answers on a machine without kubectl; see build.sh for the
# reasoning. Anything that would actually touch a cluster still needs the tool.
if ! command -v kubectl >/dev/null 2>&1; then
  if (( DRY_RUN == 1 )); then
    warn "kubectl is not installed; printing the command anyway"
  else
    err "kubectl is not installed or not on PATH"
    exit 2
  fi
fi

cmd=(kubectl)
if [[ -n "$CONTEXT" ]]; then
  cmd+=(--context "$CONTEXT")
fi
cmd+=(debug)
if (( NO_TTY == 0 )); then
  cmd+=(-it)
fi
cmd+=("$POD" --image="$IMAGE" --profile=general)
if [[ -n "$NAMESPACE" ]]; then
  cmd+=(--namespace "$NAMESPACE")
fi
if [[ -n "$TARGET" ]]; then
  cmd+=(--target "$TARGET")
fi
cmd+=(-- "${DEBUG_COMMAND[@]}")

if (( DRY_RUN == 1 )); then
  printf "dry-run: would run:"
  printf " %q" "${cmd[@]}"
  printf "\n"
  printf "dry-run complete; no changes written\n"
  exit 0
fi

info "debugging pod ${NAMESPACE:+$NAMESPACE/}$POD with image $IMAGE"
exec "${cmd[@]}"

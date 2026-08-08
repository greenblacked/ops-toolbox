#!/usr/bin/env bash
# build.sh
# Build the k8s-toolbox image with pinned toolchain versions from versions.env.
#
# Usage:
#   ./build.sh [--tag TAG] [--platform PLATFORMS] [--push] [--dry-run]
#
# Exit codes:
#   0 success
#   1 build failed
#   2 preflight failed
#   3 bad arguments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
$(basename "$0") - build the k8s-toolbox image

Usage:
  $(basename "$0") [--tag TAG] [--platform PLATFORMS] [--push] [--dry-run]

Options:
  --tag TAG         Image tag (default: k8s-toolbox:local)
  --platform LIST   Comma-separated platforms (default: linux/amd64,linux/arm64)
  --push            Push multi-arch instead of --load locally
  --dry-run         Print the docker buildx command and exit
  -h, --help        Show this help

Exit codes: 0 success, 1 failure, 2 wrong environment, 3 usage
EOF
}

tag="k8s-toolbox:local"
platforms="linux/amd64,linux/arm64"
push="false"
DRY_RUN=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tag) require_value "$1" "${2:-}"; tag="$2"; shift ;;
    --tag=*) tag="${1#*=}"; require_value "--tag" "$tag" ;;
    --platform) require_value "$1" "${2:-}"; platforms="$2"; shift ;;
    --platform=*) platforms="${1#*=}"; require_value "--platform" "$platforms" ;;
    --push) push="true" ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

versions_file="$SCRIPT_DIR/versions.env"
if [[ ! -f "$versions_file" ]]; then
  err "missing $versions_file"
  exit 2
fi
# shellcheck disable=SC1090
set -a
# shellcheck source=versions.env
. "$versions_file"
set +a

for var in YQ_VERSION KUBECTL_VERSION HELM_VERSION KUSTOMIZE_VERSION GCLOUD_VERSION; do
  if [[ -z "${!var:-}" ]]; then
    err "$var is empty in versions.env"
    exit 2
  fi
done

# --dry-run is a preview, so it answers on a machine that could not run the
# build — the same reasoning that puts --help ahead of every preflight check.
# It is also what lets the k8s suite assert the dry-run contract without Docker.
if ! command -v docker >/dev/null 2>&1; then
  if (( DRY_RUN == 1 )); then
    warn "docker is not installed; printing the command anyway"
  else
    err "docker is not installed or not on PATH"
    exit 2
  fi
fi

build_args=(
  --build-arg "YQ_VERSION=${YQ_VERSION}"
  --build-arg "KUBECTL_VERSION=${KUBECTL_VERSION}"
  --build-arg "HELM_VERSION=${HELM_VERSION}"
  --build-arg "KUSTOMIZE_VERSION=${KUSTOMIZE_VERSION}"
  --build-arg "GCLOUD_VERSION=${GCLOUD_VERSION}"
  -f "$SCRIPT_DIR/Dockerfile"
  --tag "$tag"
  "$SCRIPT_DIR"
)

if [[ "$push" == "true" ]]; then
  cmd=(docker buildx build --platform "$platforms" --push "${build_args[@]}")
else
  local_platform="${platforms%%,*}"
  cmd=(docker buildx build --platform "$local_platform" --load "${build_args[@]}")
fi

info "yq=${YQ_VERSION} kubectl=${KUBECTL_VERSION} helm=${HELM_VERSION} kustomize=${KUSTOMIZE_VERSION} gcloud=${GCLOUD_VERSION}"

if (( DRY_RUN == 1 )); then
  printf "dry-run: would run:"
  printf " %q" "${cmd[@]}"
  printf "\n"
  printf "dry-run complete; no changes written\n"
  exit 0
fi

"${cmd[@]}"
ok "built $tag"

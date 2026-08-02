#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build the k8s-toolbox image.

Usage:
  ./k8s-toolbox/build.sh [--tag TAG] [--platform PLATFORMS] [--push]

Defaults:
  TAG:       k8s-toolbox:local
  PLATFORMS: linux/amd64,linux/arm64

Examples:
  ./k8s-toolbox/build.sh --tag k8s-toolbox:local
  ./k8s-toolbox/build.sh --tag k8s-toolbox:local --platform linux/amd64
  ./k8s-toolbox/build.sh --tag gcr.io/PROJECT/k8s-toolbox:latest --push
EOF
}

tag="k8s-toolbox:local"
platforms="linux/amd64,linux/arm64"
push="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:?missing value}"; shift 2 ;;
    --platform) platforms="${2:?missing value}"; shift 2 ;;
    --push) push="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 3 ;;
  esac
done

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${push}" == "true" ]]; then
  docker buildx build \
    --platform "${platforms}" \
    --tag "${tag}" \
    --push \
    -f "${root_dir}/k8s-toolbox/Dockerfile" \
    "${root_dir}"
else
  # `--load` supports a single platform; for local builds pick the first.
  local_platform="${platforms%%,*}"
  docker buildx build \
    --platform "${local_platform}" \
    --tag "${tag}" \
    --load \
    -f "${root_dir}/k8s-toolbox/Dockerfile" \
    "${root_dir}"
fi

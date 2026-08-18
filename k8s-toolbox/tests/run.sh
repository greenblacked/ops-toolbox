#!/usr/bin/env bash
# Run the k8s-toolbox suite.
#
# Needs nothing but bash. The image build is the slow, network-bound part of
# this package and is deliberately not on the default path; the scripts that
# drive it are checked here instead, so the suite runs on the same machines the
# static one does. Opt into the real build with K8S_IMAGE_SMOKE=1, which also
# needs Docker.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${K8S_IMAGE_SMOKE:-0}" == "1" ]] && ! command -v docker >/dev/null 2>&1; then
  echo "K8S_IMAGE_SMOKE=1 was asked for, but docker is not installed" >&2
  exit 1
fi

exec "$HERE/test_k8s_toolbox.sh" "$@"

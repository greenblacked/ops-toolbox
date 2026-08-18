#!/usr/bin/env bash
set -euo pipefail

cd /chef

# Safety net for Gemfile drift; normal path is `./run.sh --rebuild`.
if ! bundle check >/dev/null 2>&1; then
  bundle install >&2
fi

[[ $# -eq 0 ]] && set -- kitchen list

# Tools that ship outside the Ruby bundle bypass `bundle exec`.
case "${1}" in
  bash|sh|sleep|tail|yamllint|shellcheck|hadolint|docker) exec "$@" ;;
  *)                                                      exec bundle exec "$@" ;;
esac

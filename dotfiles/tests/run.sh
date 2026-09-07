#!/usr/bin/env bash
# Run the dotfiles suite.
#
# Needs nothing but bash and git. The configs are static files and the
# installer only makes symlinks, so there is nothing a container would add:
# this suite runs on the same machines the static one does. python3 is used
# to parse the TOML, YAML and JSON files when it is present, and each parser
# is skipped with a note when it is not - none of them is required for a
# verdict on the installer itself.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

exec "$HERE/test_dotfiles.sh" "$@"

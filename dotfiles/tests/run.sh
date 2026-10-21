#!/usr/bin/env bash
# Run the dotfiles suites: the installer and the tracked configs in
# test_dotfiles.sh, the read-only doctor in test_doctor.sh.
#
# Needs nothing but bash and git. The configs are static files and the
# installer only makes symlinks, so there is nothing a container would add:
# this suite runs on the same machines the static one does. python3 is used
# to parse the TOML, YAML and JSON files when it is present, and each parser
# is skipped with a note when it is not - none of them is required for a
# verdict on the installer itself.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

rc=0
"$HERE/test_dotfiles.sh" "$@" || rc=1
"$HERE/test_doctor.sh" || rc=1
exit "$rc"

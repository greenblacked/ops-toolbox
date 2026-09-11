#!/usr/bin/env bash
#
# old_stay_fresh.sh — legacy macOS housekeeping. Self-contained: no
# dependencies outside of bash + the system tools each step exercises.
#
# Companion to stay_fresh.sh. Uses a built-in step/next/try reporting style
# (originally derived from ~/scripts/functions, now inlined below so the
# script can be dropped anywhere and run standalone).
#
# Steps:
#   - refresh Quick Look + Finder caches
#   - purge inactive memory
#   - clear shell history leftovers
#   - clear ~/Library caches (incl. Xcode Archives / DerivedData)
#   - update Homebrew taps + formulae and clean caches
#   - refresh toolchains behind version managers:
#       Terraform (tfenv), Helm, Python (pyenv), Go (gvm)
#   - refresh gcloud components, print aws CLI version
#   - print free space on /
#
# Safe to run repeatedly. Missing tools are skipped with a note; one failing
# step never aborts the rest of the run.

# -e is intentionally omitted: step/next/try already propagate status, and
# we want later steps to keep running when an earlier tool is missing.
# -u is also omitted because we rely on third-party shell helpers
# (~/scripts/functions, gvm) that reference unset variables by design;
# turning -u on would abort on their internal [ -z "$2" ] / $ZSH_VERSION
# checks instead of on real bugs in this script.
#
# The entire body is wrapped in `{ ... ; exit; }` so bash slurps and parses
# the whole script before executing anything. Without this, saving the file
# while it's running (very common during iteration) can leave bash with a
# stale line counter and cause phantom "unexpected EOF" errors at line
# numbers past the current end of file.
{
set -o pipefail

usage() {
  cat <<EOF
$(basename "$0") — legacy macOS housekeeping.

DEPRECATED: preserved for compatibility only. It has broad, fixed cleanup
behavior (including Xcode Archives) and receives no new features. Prefer
stay_fresh.sh, which has dry-run, explicit scoping, and safer retention.

Usage:
  $(basename "$0") --legacy-run
  $(basename "$0") [--help|-h]

A bare invocation prints this message and exits 3. The fixed sequence below
only runs with --legacy-run. There are no skip flags — for per-step toggles,
dry-run, and a summary report, use stay_fresh.sh instead.

Steps (in order):
  1.  Refresh Quick Look & Finder caches   (qlmanage -r, killall Finder)
  2.  Purge inactive memory                (sudo purge)
  3.  Clear history leftovers              (~/.lesshst, ~/.mysql_history)
  4.  Clear user caches                    (~/Library/Caches, Xcode
                                            Archives & DerivedData,
                                            composer clearcache)
  5.  Update Homebrew taps                 (gc + brew update --force)
  6.  Upgrade Homebrew formulae            (brew upgrade)
  7.  Clean Homebrew caches                (brew cleanup, drop --cache,
                                            brew tap --repair)
  8.  Terraform update                     (via tfenv)
  9.  Helm update                          (upstream get-helm-3 installer)
  10. Python update                        (via pyenv, 3.x only)
  11. Go update                            (via gvm)
  12. gcloud components update
  13. AWS CLI version                      (print only, no update)
  14. Disk free on /                       (diskutil info /)

Behavior:
  * Safe to run repeatedly.
  * Missing tools are skipped with a note; one failing step never aborts
    the rest of the run.
  * Requires sudo for the memory purge. You'll be prompted once at start;
    the script keeps sudo alive for the full run.

Options:
  --legacy-run  Run the fixed sequence. Required; a bare invocation refuses.
  -h, --help    Show this help and exit.

Files:
  ~/scripts/functions   step/next/try output helpers (required).

See also:
  stay_fresh.sh        Modern companion with dry-run, skip flags, logging,
                       disk-freed accounting, and broader coverage.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --legacy-run)
    if [[ -n "${2:-}" ]]; then
      printf 'unknown option: %s\n\n' "$2" >&2
      usage >&2
      exit 3
    fi
    ;;
  "")
    printf 'DEPRECATED: refusing to run. Use stay_fresh.sh, or pass --legacy-run if you mean this script.\n' >&2
    usage >&2
    exit 3
    ;;
  *)
    printf 'unknown option: %s\n\n' "$1" >&2
    usage >&2
    exit 3
    ;;
esac

printf 'DEPRECATED: use stay_fresh.sh for previewable, scoped maintenance.\n' >&2

# Resolve the invoking user's real home directory, independent of $HOME —
# the script may be invoked with a sanitized env (sudo, launchd, etc.) where
# $HOME is /var/root or unset. Falls back to $HOME only if dscl can't answer.
USER_NAME=${SUDO_USER:-$(id -un)}
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null \
              | awk '{print $2}')
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || USER_HOME=$HOME
if [ ! -d "$USER_HOME" ]; then
  printf 'cannot determine a usable home directory (tried %s); aborting.\n' \
    "$USER_HOME" >&2
  exit 1
fi

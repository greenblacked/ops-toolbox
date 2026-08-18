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

# -e is intentionally omitted: step/next + try already propagate status, and
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
  $(basename "$0") [--help|-h]

Runs a fixed sequence of housekeeping steps. There are no skip flags — for
per-step toggles, dry-run, and a summary report, use stay_fresh.sh instead.

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
  "")        ;;
  *)         printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 3 ;;
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

# ---------------------------------------------------------------------------
# Inlined step/next/try helpers (originally ~/scripts/functions).
#
# Reporting model:
#   step "Title"         prints the title, resets the step status file.
#     try cmd args...    runs the command, prints its output, records the
#                        exit code into $STEP_FILE if non-zero.
#     output_start       dim-color region for raw command output.
#     output_end         end of dim-color region.
#   next                 reads $STEP_FILE and prints [ OK ] or [FAILED].
#
# $STEP_FILE is file-based (not a variable) so status survives subshells
# (`try` runs under command substitution) which is how the original helper
# was designed.
# ---------------------------------------------------------------------------
umask 022

RES_COL=60
MOVE_TO_COL=$'\033[60G'

# Use colors only when stdout is a TTY, NO_COLOR is unset, and terminfo
# promises at least 8 colours.
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] \
   && command -v tput >/dev/null 2>&1 \
   && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  USE_COLOR=true
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RESET=$'\033[0m'
else
  USE_COLOR=false
  C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_RESET=''
fi

: "${TMPDIR:=/tmp/}"
STEP_FILE=${TMPDIR%/}/step.$$

# Tear down the step file on exit (in addition to the sudo keep-alive trap
# already registered earlier — we'll combine them when we set it later).
cleanup_step_file() { rm -f "$STEP_FILE"; }

_echo_status() {
  local color=$1 status=$2
  [ "$USE_COLOR" = true ] && printf '%s' "$MOVE_TO_COL"
  printf '['
  [ "$USE_COLOR" = true ] && printf '%s' "$color"
  printf '%s' "$status"
  [ "$USE_COLOR" = true ] && printf '%s' "$C_RESET"
  printf ']\r\n'
}

title() {
  [ "$USE_COLOR" = true ] && printf '%s' "$C_BOLD"
  printf '\r * %s' "$*" | fold -s -w 59
  [ "$USE_COLOR" = true ] && printf '%s' "$C_RESET"
}

step() {
  title "$@"
  # Initial exit status = 0 (success); individual try calls overwrite this
  # with a non-zero rc if any fail.
  [ -w "$TMPDIR" ] && printf '0' > "$STEP_FILE"
}

success() { _echo_status "$C_GREEN"  "  OK  "; }
failure() { _echo_status "$C_RED"    "FAILED"; }

next() {
  local rc=1
  if [ -f "$STEP_FILE" ]; then
    rc=$(<"$STEP_FILE")
    rm -f "$STEP_FILE"
  fi
  if [ "${rc:-1}" -eq 0 ] 2>/dev/null; then
    success
  else
    failure
  fi
  return "$rc"
}

output_start() {
  printf '\n'
  [ "$USE_COLOR" = true ] && printf '%s' "$C_DIM"
}
output_end() {
  [ "$USE_COLOR" = true ] && printf '%s' "$C_RESET"
}

output() {
  local text="$*"
  if [ -n "$text" ]; then
    output_start
    printf '%s\n' "$text"
    output_end
  fi
}

error() {
  local rc=$1 line=$2 cmd=$3
  if [ "$rc" -ne 0 ] 2>/dev/null; then
    [ -w "$TMPDIR" ] && printf '%s' "$rc" > "$STEP_FILE"
    printf '%s: line %s: `%s` failed: %s.\n' \
      "$(basename "$0")" "$line" "$cmd" "$rc"
  fi
}

try() {
  local out rc
  out=$(eval "$@" 2>&1)
  rc=$?
  output "$out"
  error "$rc" "${BASH_LINENO[0]:-0}" "$*"
  return "$rc"
}

# Show hidden files in globs (so */.* patterns work as expected).
shopt -s dotglob

# Prompt for sudo password once, then keep it alive for the whole run.
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
# Drop from the job table so tearing it down in EXIT does not make bash print
# "Terminated: 15 ( while true; ... )" job-control noise.
disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || disown || true
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
      wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
      cleanup_step_file' EXIT

# ---------------------------------------------------------------------------
# Generic version-manager update helper.
#
# Every tool we manage (tfenv, pyenv, gvm, helm) follows the same flow:
#   1. Is the manager/tool installed?
#   2. What version is currently active?
#   3. What's the latest version upstream?
#   4. If different, install it, switch to it, remove the old one.
#
# The pattern was duplicated 4× in the original script; this helper drops
# each tool to a few function definitions.
#
# Usage:
#   version_update <label> <have_fn> <current_fn> <latest_fn> \
#                  <install_fn> <use_fn> <remove_fn>
#
# Each *_fn is a shell function name. install/use/remove receive the target
# version as $1. All calls are best-effort: the helper itself never errors out.
# ---------------------------------------------------------------------------
version_update() {
  local label=$1 have=$2 current=$3 latest=$4 install=$5 use=$6 remove=$7
  local cur lat

  if ! "$have"; then
    printf "  %s: version manager not installed; skipping.\n" "$label"
    return 0
  fi

  cur=$("$current" 2>/dev/null || true)
  [ -n "$cur" ] || cur="none"
  lat=$("$latest" 2>/dev/null || true)

  if [ -z "$lat" ]; then
    printf "  %s: could not determine latest version; skipping.\n" "$label"
    return 0
  fi

  if [ "$cur" = "$lat" ]; then
    printf "  %s is already up-to-date: %s\n" "$label" "$cur"
    return 0
  fi

  printf "  Updating %s from %s to %s...\n" "$label" "$cur" "$lat"
  if ! "$install" "$lat"; then
    printf "  Failed to install %s %s; keeping %s.\n" "$label" "$lat" "$cur"
    return 0
  fi
  "$use" "$lat" || printf "  Warning: failed to activate %s %s.\n" "$label" "$lat"

  if [ "$cur" != "none" ] && [ "$cur" != "$lat" ]; then
    printf "  Removing old %s version: %s\n" "$label" "$cur"
    "$remove" "$cur" || printf "  Warning: failed to uninstall %s %s.\n" "$label" "$cur"
  fi
}

# ---------------------------------------------------------------------------
# Per-tool definitions (kept tiny on purpose).
# ---------------------------------------------------------------------------

# Terraform via tfenv.
tf_have()    { command -v tfenv >/dev/null 2>&1; }
tf_current() { terraform version 2>/dev/null | head -n1 | awk '{print $2}' | tr -d 'v'; }
tf_latest()  { tfenv list-remote 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1; }
tf_install() { tfenv install "$1"; }
tf_use()     { tfenv use "$1"; }
tf_remove()  { tfenv uninstall "$1"; }

# Helm: no version manager, but upstream ships an installer script that takes
# a target version. The "use" and "remove" steps are no-ops because the
# installer overwrites the single binary in-place.
helm_have()    { command -v helm >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }
helm_current() { helm version --template '{{.Version}}' 2>/dev/null; }
helm_latest()  { curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name'; }
helm_install() {
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | bash -s -- --version "$1"
}
helm_use()    { :; }
helm_remove() { :; }

# Python via pyenv. Restrict to 3.x.y so we don't downgrade to Python 2 or
# pick up free-form lines (miniconda, pypy, stackless) from pyenv's listing.
py_have()    { command -v pyenv >/dev/null 2>&1; }
py_current() { python --version 2>/dev/null | awk '{print $2}'; }
py_latest()  {
  pyenv install --list 2>/dev/null \
    | awk '{$1=$1};1' \
    | grep -E '^3\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -1
}
py_install() { pyenv install "$1"; }
py_use()     { pyenv global "$1" && pyenv rehash; }
py_remove()  { pyenv uninstall -f "$1"; }

# Go via gvm. gvm is a shell function, so source it before probing.
# shellcheck source=/dev/null
[ -s "$HOME/.gvm/scripts/gvm" ] && . "$HOME/.gvm/scripts/gvm"
go_have()    { command -v gvm >/dev/null 2>&1; }
go_current() { go version 2>/dev/null | awk '{print $3}' | sed 's/^go//'; }
go_latest()  { curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1 | sed 's/^go//'; }
go_install() { gvm install "go$1"; }
go_use()     { gvm use "go$1" --default; }
go_remove()  { gvm uninstall "go$1"; }

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

step "Refresh Quick Look & Finder caches"
  try qlmanage -r
  if pgrep -x Finder >/dev/null 2>&1; then
    try killall Finder
  fi
next

step "Purge inactive memory"
  try sudo /usr/sbin/purge
next

# Best-effort cache wipe. `find -delete` returns 1 on the first undeletable
# entry (SQLite files held open by Chrome/Spotlight/iCloud, etc.), which is
# normal, so we swallow its exit status. `try` still renders the command
# label and any stdout it produces.
clean_dir() {
  local dir=$1
  [ -d "$dir" ] || return 0
  # Pass a single string to try (which eval's it). The embedded \" keeps $dir
  # quoted when eval re-parses, so paths with spaces are safe. This form is
  # portable to bash 3.2 (the /bin/bash that ships with macOS).
  try "find \"$dir\" -mindepth 1 -delete 2>/dev/null || true"
}

step "Clear history leftovers"
  [ -f "$USER_HOME/.lesshst" ]       && try rm -f "$USER_HOME/.lesshst"
  [ -f "$USER_HOME/.mysql_history" ] && try rm -f "$USER_HOME/.mysql_history"
next

step "Clear user caches"
  clean_dir "$USER_HOME/Library/Caches"
  if [ -d "$USER_HOME/Library/Developer/Xcode" ]; then
    clean_dir "$USER_HOME/Library/Developer/Xcode/Archives"
    clean_dir "$USER_HOME/Library/Developer/Xcode/DerivedData"
  fi
  if command -v composer >/dev/null 2>&1; then
    try composer clearcache --quiet
  fi
next

step "Update Homebrew taps"
  output_start
  if BREW_REPO=$(brew --repo 2>/dev/null); then
    for dir in "$BREW_REPO" "$BREW_REPO"/Library/Taps/*/*; do
      [ -d "$dir/.git" ] || continue
      echo "Housekeeping $dir"
      git -C "$dir" gc --auto --prune=now 2>/dev/null || true
    done
    HOMEBREW_NO_ENV_HINTS=1 brew update --force
  else
    echo "Homebrew not installed; skipping."
  fi
  output_end
next

step "Upgrade Homebrew formulae"
  output_start
  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade || true
  else
    echo "Homebrew not installed; skipping."
  fi
  output_end
next

step "Clean Homebrew caches"
  output_start
  if command -v brew >/dev/null 2>&1; then
    brew cleanup --prune=3 -s || true
    if cache=$(brew --cache 2>/dev/null); then
      rm -rf "$cache"
    fi
    brew tap --repair || true
  else
    echo "Homebrew not installed; skipping."
  fi
  output_end
next

step "Terraform update"
  output_start
  version_update "Terraform" tf_have tf_current tf_latest tf_install tf_use tf_remove
  output_end
next

step "Helm update"
  output_start
  version_update "Helm" helm_have helm_current helm_latest helm_install helm_use helm_remove
  output_end
next

step "Python update"
  output_start
  version_update "Python" py_have py_current py_latest py_install py_use py_remove
  output_end
next

step "Go update"
  output_start
  version_update "Go" go_have go_current go_latest go_install go_use go_remove
  output_end
next

step "gcloud components update"
  output_start
  if command -v gcloud >/dev/null 2>&1; then
    gcloud version || true
    gcloud components update -q || true
    gcloud version || true
  else
    echo "gcloud not installed; skipping."
  fi
  output_end
next

step "AWS CLI version"
  output_start
  if command -v aws >/dev/null 2>&1; then
    aws --version || true
  else
    echo "aws not installed; skipping."
  fi
  output_end
next

step "Disk free on /"
  output_start
  diskutil info / | grep --color=never "Free Space" || true
  output_end
next

exit 0
}

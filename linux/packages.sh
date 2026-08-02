#!/usr/bin/env bash
# packages.sh
# Capture and restore the package set of a Linux machine.
#
# The counterpart of macos-initial-setup/brewfile.sh, with the same four verbs.
# install_devtools.sh installs a curated list decided in advance; this is the
# other direction — record what a machine actually has, keep it under version
# control, and reproduce it elsewhere. The curated script is the intent, this
# file is the fact.
#
# Only *explicitly installed* packages are recorded. Every distro tracks the
# difference between "you asked for this" and "it came along as a dependency",
# and capturing the second kind produces a file that is enormous, unstable
# across releases, and useless for rebuilding a machine.
#
# Usage:
#   ./packages.sh dump      [--file PATH] [--force]
#   ./packages.sh check     [--file PATH]
#   ./packages.sh install   [--file PATH] [--dry-run] [--yes]
#   ./packages.sh diff      [--file PATH]
#
# Commands:
#   dump     Write explicitly-installed package names to a file
#   check    Report whether everything in the file is installed (read-only)
#   install  Install everything the file lists that is missing
#   diff     Show what dump would change, without writing
#
# Exit codes:
#   0   success (for `check`: everything present)
#   1   command failed (for `check`: something is missing)
#   2   preflight checks failed
#   3   bad CLI arguments
set -u
set -o pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info() { printf "%s[info]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf "%s[ ok ]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }

usage() {
  awk 'NR == 1 { next }
       /^#/    { sub(/^# ?/, ""); print; next }
       { exit }' "$0"
}

# Reads OS_RELEASE rather than /etc/os-release directly so the negative case is
# testable: pointing it at a fake file is the only way to prove the "unsupported
# distro" path works, and `uname` cannot be faked the way the macOS scripts
# would need. Duplicated in each linux/ script on purpose — see CONTRIBUTING.md.
detect_pkg_mgr() {
  local os_release="${OS_RELEASE:-/etc/os-release}"
  local id="" id_like=""
  if [[ -r "$os_release" ]]; then
    id="$(sed -n 's/^ID=//p' "$os_release" | tr -d '"' | head -n 1)"
    id_like="$(sed -n 's/^ID_LIKE=//p' "$os_release" | tr -d '"' | head -n 1)"
  fi
  case " $id $id_like " in
    *" debian "*|*" ubuntu "*)             printf 'apt\n' ;;
    *" fedora "*|*" rhel "*|*" centos "*)  printf 'dnf\n' ;;
    *" arch "*|*" archlinux "*)            printf 'pacman\n' ;;
    *)
      printf 'unsupported:%s\n' "${id:-unknown}"
      ;;
  esac
}

CMD=""
FILE=""
FORCE=0
DRY_RUN=0
ASSUME_YES=0

while (( $# > 0 )); do
  case "$1" in
    dump|check|install|diff)
      if [[ -n "$CMD" ]]; then err "only one command at a time"; exit 3; fi
      CMD="$1"
      ;;
    --file) shift; [[ $# -gt 0 ]] || { err "--file needs a path"; exit 3; }; FILE="$1" ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 3 ;;
  esac
  shift
done

if [[ -z "$CMD" ]]; then usage >&2; exit 3; fi

PKG_MGR="$(detect_pkg_mgr)"
case "$PKG_MGR" in
  unsupported:*)
    err "unsupported distribution: ${PKG_MGR#unsupported:} (need apt, dnf or pacman)"
    exit 2
    ;;
esac

if ! command -v "$PKG_MGR" >/dev/null 2>&1; then
  err "$PKG_MGR was detected from os-release but is not on PATH"
  exit 2
fi

[[ -n "$FILE" ]] || FILE="$SCRIPT_DIR/packages.$PKG_MGR.txt"

# Explicitly-installed package names, one per line, sorted for a stable diff.
list_manual() {
  case "$PKG_MGR" in
    apt)    apt-mark showmanual 2>/dev/null ;;
    dnf)    dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null ;;
    pacman) pacman -Qqe 2>/dev/null ;;
  esac | LC_ALL=C sort -u
}

is_installed() {
  case "$PKG_MGR" in
    apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$' ;;
    dnf)    rpm -q "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Qi "$1" >/dev/null 2>&1 ;;
  esac
}

install_cmd() {
  case "$PKG_MGR" in
    apt)    printf 'apt-get install --yes %s\n' "$*" ;;
    dnf)    printf 'dnf install -y %s\n' "$*" ;;
    pacman) printf 'pacman -S --needed --noconfirm %s\n' "$*" ;;
  esac
}

read_file_packages() {
  grep -vE '^\s*(#|$)' "$FILE" 2>/dev/null | LC_ALL=C sort -u
}

case "$CMD" in
  dump)
    if [[ -e "$FILE" ]] && (( FORCE == 0 )); then
      err "$FILE exists — review changes with '$(basename "$0") diff', then pass --force"
      exit 1
    fi
    tmp="$(mktemp)"
    {
      printf '# %s packages explicitly installed on %s\n' "$PKG_MGR" "$(hostname 2>/dev/null || echo host)"
      printf '# Written by packages.sh; one package per line.\n'
      list_manual
    } > "$tmp"
    mv "$tmp" "$FILE"
    ok "wrote $FILE"
    printf "  %s%s package(s)%s\n" "$C_DIM" "$(read_file_packages | wc -l | tr -d ' ')" "$C_RESET"
    ;;

  diff)
    if [[ ! -f "$FILE" ]]; then
      err "$FILE does not exist — run '$(basename "$0") dump' first"
      exit 1
    fi
    tmp="$(mktemp)"
    list_manual > "$tmp"
    if diff -u <(read_file_packages) "$tmp" >/dev/null 2>&1; then
      ok "$FILE matches this machine"
      rm -f "$tmp"
      exit 0
    fi
    printf "%s--- %s (committed)\n+++ this machine%s\n" "$C_BOLD" "$FILE" "$C_RESET"
    diff -u <(read_file_packages) "$tmp" | tail -n +3
    rm -f "$tmp"
    info "run '$(basename "$0") dump --force' to accept these"
    ;;

  check)
    if [[ ! -f "$FILE" ]]; then err "$FILE does not exist"; exit 1; fi
    missing=0
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      if ! is_installed "$pkg"; then
        printf "MISSING  %s\n" "$pkg"
        missing=$((missing + 1))
      fi
    done < <(read_file_packages)
    if (( missing == 0 )); then
      ok "everything in $FILE is installed"
    else
      warn "$missing missing — '$(basename "$0") install' will add them"
      exit 1
    fi
    ;;

  install)
    if [[ ! -f "$FILE" ]]; then err "$FILE does not exist"; exit 1; fi
    missing_list=""
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      is_installed "$pkg" || missing_list="$missing_list $pkg"
    done < <(read_file_packages)

    # shellcheck disable=SC2086
    set -- $missing_list
    if (( $# == 0 )); then
      ok "nothing to install; everything in $FILE is present"
      exit 0
    fi

    if (( DRY_RUN == 1 )); then
      info "(dry-run) would install $# package(s) from $FILE:"
      for pkg in "$@"; do printf "  would install %s\n" "$pkg"; done
      printf "dry-run: would run: %s" "$(install_cmd "$@")"
      printf "dry-run complete; no changes written\n"
      exit 0
    fi

    if (( ASSUME_YES == 0 )); then
      err "$# package(s) would be installed; rerun with --yes (or --dry-run to preview)"
      exit 3
    fi

    sudo_prefix=""
    [[ "$(id -u)" == "0" ]] || sudo_prefix="sudo"
    if ! $sudo_prefix sh -c "$(install_cmd "$@")"; then
      err "install failed"
      exit 1
    fi
    ok "installed $# package(s)"
    ;;
esac

#!/usr/bin/env bash
# packages.sh
# Capture and restore the package set of a Linux machine.
#
# The counterpart of macos-initial-setup/brewfile.sh, with the same command and
# exit-code conventions.
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
# holds and orphans answer the two questions before maintenance: why did the
# upgrade skip nginx, and what will autoremove delete? Both are read-only,
# need no sudo, and print bare names on stdout, like list, so they work in
# pipes; any note goes to stderr.
#
# Usage:
#   ./packages.sh list
#   ./packages.sh dump      [--file PATH] [--force]
#   ./packages.sh check     [--file PATH]
#   ./packages.sh install   [--file PATH] [--dry-run] [--yes]
#   ./packages.sh diff      [--file PATH]
#   ./packages.sh holds
#   ./packages.sh orphans
#
# Commands:
#   list     Print explicitly-installed package names to stdout (read-only)
#   dump     Write explicitly-installed package names to a file
#   check    Report whether everything in the file is installed (read-only)
#   install  Install everything the file lists that is missing
#   diff     Show what dump would change, without writing
#   holds    Print held, version-locked or ignored package names (read-only):
#            apt-mark showhold, dnf versionlock plus exclude= in
#            /etc/dnf/dnf.conf, or IgnorePkg in /etc/pacman.conf
#   orphans  Print the packages autoremove would remove (read-only):
#            apt-get -s autoremove, dnf repoquery --unneeded, pacman -Qdtq
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

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
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
    list|dump|check|install|diff|holds|orphans)
      if [[ -n "$CMD" ]]; then err "only one command at a time"; exit 3; fi
      CMD="$1"
      ;;
    --file)    require_value "$1" "${2:-}"; FILE="$2"; shift ;;
    --file=*)  FILE="${1#*=}"; require_value "--file" "$FILE" ;;
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
    # dnf5 does not append a record separator to --qf output. Include it in
    # the format so Fedora package names do not collapse into one long token.
    dnf)    dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null ;;
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

# --- holds and orphans ------------------------------------------------------
# dnf versionlock prints NAME-EPOCH:VERSION-RELEASE.* (dnf 4) or
# "Package name: NAME" (dnf 5); a leading ! is an excluded version, not a hold.
versionlock_names() {
  awk '
    /^[ \t]*(#|$)/ { next }
    /^!/ { next }
    /^Package name:/ { sub(/^Package name:[ \t]*/, ""); print $1; next }
    /^[A-Za-z0-9_.+-]+-[0-9]+:/ { sub(/-[0-9]+:.*$/, ""); print; next }
  '
}

# exclude= (and dnf 5's excludepkgs=) in /etc/dnf/dnf.conf, comma or space
# separated. Globs such as kernel* are printed as written.
dnf_conf_excludes() {
  [[ -r /etc/dnf/dnf.conf ]] || return 0
  awk '
    /^[ \t]*(exclude|excludepkgs)[ \t]*=/ {
      v = substr($0, index($0, "=") + 1)
      gsub(/,/, " ", v)
      n = split(v, parts, /[ \t]+/)
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
    }' /etc/dnf/dnf.conf
}

# IgnorePkg entries in /etc/pacman.conf, comments stripped. IgnoreGroup is out
# of scope: a group is not a package name.
pacman_ignored() {
  [[ -r /etc/pacman.conf ]] || return 0
  awk '
    { sub(/#.*/, "") }
    /^[ \t]*IgnorePkg[ \t]*=/ {
      v = substr($0, index($0, "=") + 1)
      n = split(v, parts, /[ \t]+/)
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
    }' /etc/pacman.conf
}

list_holds() {
  local out rc locks
  case "$PKG_MGR" in
    apt)
      out="$(apt-mark showhold 2>/dev/null)"; rc=$?
      if (( rc != 0 )); then
        err "apt-mark showhold failed (exit $rc)"
        return 1
      fi
      ;;
    dnf)
      # The versionlock plugin is optional. Without it there are no locks to
      # read, which is a note for stderr rather than a failure.
      if locks="$(dnf versionlock list -q 2>/dev/null)"; then
        locks="$(versionlock_names <<<"$locks")"
      else
        info "dnf versionlock is not available; reading exclude= in /etc/dnf/dnf.conf only" >&2
        locks=""
      fi
      out="$locks"$'\n'"$(dnf_conf_excludes)"
      ;;
    pacman)
      out="$(pacman_ignored)"
      ;;
  esac
  printf '%s\n' "$out" | awk 'NF { print $1 }' | LC_ALL=C sort -u
}

list_orphans() {
  local out rc
  case "$PKG_MGR" in
    apt)
      # -s simulates: nothing is removed, and no root is needed.
      out="$(apt-get -s autoremove 2>/dev/null)"; rc=$?
      if (( rc != 0 )); then
        err "apt-get -s autoremove failed (exit $rc)"
        return 1
      fi
      out="$(awk '/^Remv / { print $2 }' <<<"$out")"
      ;;
    dnf)
      out="$(dnf repoquery --unneeded --qf '%{name}\n' 2>/dev/null)"; rc=$?
      if (( rc != 0 )); then
        err "dnf repoquery --unneeded failed (exit $rc)"
        return 1
      fi
      ;;
    pacman)
      # pacman -Qdtq exits 1 with no output when nothing is orphaned; that is
      # the empty answer, not an error.
      out="$(pacman -Qdtq 2>/dev/null)"; rc=$?
      if (( rc != 0 )) && [[ "$rc" != 1 || -n "$out" ]]; then
        err "pacman -Qdtq failed (exit $rc)"
        return 1
      fi
      ;;
  esac
  printf '%s\n' "$out" | awk 'NF { print $1 }' | LC_ALL=C sort -u
}

read_file_packages() {
  grep -vE '^\s*(#|$)' "$FILE" 2>/dev/null | LC_ALL=C sort -u
}

case "$CMD" in
  list)
    # The same stable, dependency-free view that `dump` records, without a
    # hostname header or a file write. This is useful in pipes and inventory
    # collectors, and unlike parsing a distro-specific command it works across
    # all three supported package managers.
    list_manual
    ;;

  holds)
    # Names only on stdout, sorted, so the output pipes; empty means none.
    list_holds || exit 1
    ;;

  orphans)
    # What autoremove would take, as names; empty means none.
    list_orphans || exit 1
    ;;

  dump)
    if [[ -e "$FILE" ]] && (( FORCE == 0 )); then
      err "$FILE exists — review changes with '$(basename "$0") diff', then pass --force"
      exit 1
    fi
    # dump accepted --dry-run and wrote the file anyway: the flag was parsed
    # and then never consulted on this path, so the one mode that promises to
    # touch nothing replaced whatever was at --file.
    if (( DRY_RUN == 1 )); then
      printf "  %s(dry-run)%s would write %s\n" "$C_DIM" "$C_RESET" "$FILE"
      printf "  %s(dry-run)%s %s package(s)%s\n" \
        "$C_DIM" "$C_RESET" "$(list_manual | wc -l | tr -d ' ')" "$C_RESET"
      printf "dry-run complete; no changes written\n"
      exit 0
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
      # Same linux/ grammar as dump above: indented dimmed (dry-run) previews,
      # every printf ends with a newline, then the standalone closing summary.
      # Do not mix git/'s "dry-run: would run:" form on this path.
      printf "  %s(dry-run)%s would install %s package(s) from %s:\n" \
        "$C_DIM" "$C_RESET" "$#" "$FILE"
      for pkg in "$@"; do
        printf "  %s(dry-run)%s would install %s\n" "$C_DIM" "$C_RESET" "$pkg"
      done
      # install_cmd's format string already ends with \n; strip it so the
      # preview line does not leave a blank line before the summary.
      printf "  %s(dry-run)%s %s\n" "$C_DIM" "$C_RESET" "$(install_cmd "$@" | tr -d '\n')"
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

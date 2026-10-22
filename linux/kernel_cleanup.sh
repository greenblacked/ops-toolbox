#!/usr/bin/env bash
# kernel_cleanup.sh
# Remove old kernel packages, keeping the running kernel plus the newest N.
#
# A /boot that fills up with old kernels, initramfs images and module trees is
# the classic reason an apt or dnf upgrade fails half-way through, and
# `apt-get autoremove` is not a reliable pruner: a kernel installed by hand, or
# marked manual by an installer, is never auto-removable. disk_cleanup.sh never
# touches packages and stay_fresh.sh only autoremoves, so this is the one place
# that names old kernels and takes them out deliberately.
#
# The running kernel and the newest installed one are never candidates, at
# least two kernels always stay installed, and the script refuses rather than
# guesses when it cannot tell which kernel is running. It never reboots, never
# runs autoremove and never edits bootloader configuration: the package
# manager's own removal hooks update GRUB and the initramfs. pacman keeps one
# copy of each kernel package already, so there is nothing to prune there.
#
# A dry run writes nothing. A real run requires --yes. --release names the
# running kernel instead of `uname -r`; it is the seam the tests use and what a
# chroot needs. OS_RELEASE is honoured for the same reason as in the other
# linux/ scripts.
#
# Exit codes:
#   0   done, or nothing to remove
#   1   the removal failed
#   2   preflight failed (not Linux, unsupported distribution, package tool
#       missing, or the running kernel release could not be determined)
#   3   bad CLI arguments, or a real run without --yes
set -u
set -o pipefail

DRY_RUN=0
ASSUME_YES=0
NO_SUDO=0
LIST=0
KEEP=2
RELEASE=""
RELEASE_OVERRIDE=0

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

FAIL_COUNT=0

usage() {
  cat <<EOF
kernel_cleanup.sh - remove old kernel packages, keeping the running one plus N

Keeps the running kernel, the newest --keep kernels and the newest installed
one, and never leaves fewer than two kernels installed. apt purges the image,
modules and headers of each old release; dnf removes the versioned kernel
packages. pacman keeps one copy of each kernel already. Never runs autoremove,
never reboots, never edits the bootloader. A dry run writes nothing. A real run
requires --yes.

Usage:
  $(basename "$0") --list
  $(basename "$0") --dry-run
  $(basename "$0") --yes
  $(basename "$0") --dry-run --keep 1

Options:
  --list           Show each installed kernel as running, keep or remove; read-only
  --keep N         Newest kernels to keep besides the running one, 1-20 (default: $KEEP)
  --dry-run        Print the removal without running it
  --yes, -y        Required for a run that actually removes packages
  --no-sudo        Skip the removal instead of escalating with sudo
  --release VER    Treat VER as the running kernel (default: uname -r)
  --help, -h       Show this help

Exit codes: 0 done or nothing to remove, 1 removal failed, 2 not Linux /
unsupported distro / package tool missing / running kernel unknown, 3 usage
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

# Duplicated in each linux/ script on purpose (see CONTRIBUTING.md). OS_RELEASE
# is honoured so the unsupported-distro path can actually be tested.
detect_pkg_mgr() {
  local os_release="${OS_RELEASE:-/etc/os-release}"
  local id="" id_like=""
  if [[ -r "$os_release" ]]; then
    id="$(sed -n 's/^ID=//p' "$os_release" | tr -d '"')"
    id="${id%%$'\n'*}"
    id_like="$(sed -n 's/^ID_LIKE=//p' "$os_release" | tr -d '"')"
    id_like="${id_like%%$'\n'*}"
  fi
  case " $id $id_like " in
    *" debian "*|*" ubuntu "*)             printf 'apt\n' ;;
    *" fedora "*|*" rhel "*|*" centos "*)  printf 'dnf\n' ;;
    *" arch "*|*" archlinux "*)            printf 'pacman\n' ;;
    *) printf 'unsupported:%s\n' "${id:-unknown}" ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --list)        LIST=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --no-sudo)     NO_SUDO=1 ;;
    --keep)        require_value "$1" "${2:-}"; KEEP="$2"; shift ;;
    --keep=*)      KEEP="${1#*=}"; require_value "--keep" "$KEEP" ;;
    --release)     require_value "$1" "${2:-}"; RELEASE="$2"; RELEASE_OVERRIDE=1; shift ;;
    --release=*)   RELEASE="${1#*=}"; require_value "--release" "$RELEASE"; RELEASE_OVERRIDE=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

# A floor of one: --keep 0 would leave only the running kernel, which is the
# one configuration that cannot boot anything else when it turns out broken.
if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || (( KEEP < 1 || KEEP > 20 )); then
  err "--keep must be an integer between 1 and 20, got: $KEEP"
  exit 3
fi

# Release strings go into package names and onto a command line, so they are
# held to the alphabet kernel versions actually use.
valid_release() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]
}

if (( RELEASE_OVERRIDE == 1 )) && ! valid_release "$RELEASE"; then
  err "--release is not a kernel release string: $RELEASE"
  exit 3
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  err "this script targets Linux"
  exit 2
fi

if (( LIST == 0 && DRY_RUN == 0 && ASSUME_YES == 0 )); then
  err "refusing to remove kernels without --yes; preview with --dry-run"
  exit 3
fi

PKG_MGR="$(detect_pkg_mgr)"
case "$PKG_MGR" in
  unsupported:*)
    err "unsupported distribution: ${PKG_MGR#unsupported:} (need apt, dnf or pacman)"
    exit 2
    ;;
  pacman)
    info "pacman keeps one copy of each kernel package; nothing to prune"
    exit 0
    ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

case "$PKG_MGR" in
  apt) tools="dpkg-query"; (( LIST )) || tools="$tools apt-get" ;;
  dnf) tools="rpm";        (( LIST )) || tools="$tools dnf" ;;
esac
for tool in $tools; do
  if ! have "$tool"; then
    err "$tool is not on PATH; cannot manage kernels with $PKG_MGR"
    exit 2
  fi
done

# Refuse rather than guess. Every safety property below is relative to the
# running kernel, and an empty or garbled release would protect nothing.
if (( RELEASE_OVERRIDE == 0 )); then
  RELEASE="$(uname -r 2>/dev/null || true)"
fi
if [[ -z "$RELEASE" ]] || ! valid_release "$RELEASE"; then
  err "cannot determine the running kernel release; pass --release VER"
  exit 2
fi

human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1099511627776) printf "%.1fT", b / 1099511627776;
    else if (b >= 1073741824) printf "%.1fG", b / 1073741824;
    else if (b >= 1048576) printf "%.0fM", b / 1048576;
    else if (b >= 1024) printf "%dK", b / 1024;
    else printf "%dB", b
  }'
}

step() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# Same rule as disk_cleanup.sh: --no-sudo asks to skip root-owned work whoever
# is running the script, and root needs no sudo at all.
SUDO=""
if (( NO_SUDO == 1 )); then
  SUDO="skip"
elif [[ "$(id -u)" != "0" ]]; then
  if have sudo; then
    SUDO="sudo"
  else
    SUDO="skip"
    warn "sudo is not available; the removal will be skipped"
  fi
fi

run_root() {
  local label="$1"; shift
  if [[ "$SUDO" == "skip" ]]; then
    warn "skipped (needs root): $label"
    return 0
  fi
  if (( DRY_RUN == 1 )); then
    if [[ -n "$SUDO" ]]; then
      printf "  %s(dry-run)%s %s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$SUDO" "$*" "$C_DIM" "$label" "$C_RESET"
    else
      printf "  %s(dry-run)%s %s %s[%s]%s\n" "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$label" "$C_RESET"
    fi
    return 0
  fi
  local rc
  if [[ -n "$SUDO" ]]; then
    "$SUDO" "$@"
    rc=$?
  else
    "$@"
    rc=$?
  fi
  if (( rc != 0 )); then
    err "$label failed (exit $rc)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    ok "$label"
  fi
  return 0
}

# Every installed package of the kernel family, one per line:
#   release <TAB> package <TAB> bytes <TAB> anchor
# anchor 1 marks the package that defines a release (the image on apt,
# kernel-core on dnf), 2 the dnf fallback when kernel-core does not exist, and
# 0 a package that only travels with a release. The patterns are anchored on a
# digit after the prefix, which is what keeps metapackages such as
# linux-image-amd64, linux-image-generic and an unversioned kernel out.
kernel_rows() {
  case "$PKG_MGR" in
    apt)
      dpkg-query -W -f='${Package}\t${Status}\t${Installed-Size}\n' 2>/dev/null | awk -F'\t' '
        $2 != "install ok installed" { next }
        $1 ~ /-(dbg|dbgsym)$/ { next }
        {
          name = $1; rel = ""; anchor = 0
          size = ($3 ~ /^[0-9]+$/) ? $3 * 1024 : 0
          if (name ~ /^linux-image-unsigned-[0-9]/)     { rel = substr(name, 22); anchor = 1 }
          else if (name ~ /^linux-image-[0-9]/)         { rel = substr(name, 13); anchor = 1 }
          else if (name ~ /^linux-modules-extra-[0-9]/) { rel = substr(name, 21) }
          else if (name ~ /^linux-modules-[0-9]/)       { rel = substr(name, 15) }
          else if (name ~ /^linux-headers-[0-9]/)       { rel = substr(name, 15) }
          if (rel != "") printf "%s\t%s\t%.0f\t%d\n", rel, name, size, anchor
        }'
      ;;
    dnf)
      rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\t%{SIZE}\n' 2>/dev/null | awk -F'\t' '
        {
          anchor = -1
          if ($1 == "kernel-core") anchor = 1
          else if ($1 == "kernel") anchor = 2
          else if ($1 == "kernel-modules" || $1 == "kernel-modules-core" || \
                   $1 == "kernel-modules-extra" || $1 == "kernel-devel") anchor = 0
          if (anchor < 0 || $2 !~ /^[0-9]/) next
          size = ($3 ~ /^[0-9]+$/) ? $3 : 0
          printf "%s\t%s-%s\t%.0f\t%d\n", $2, $1, $2, size, anchor
        }'
      ;;
  esac
}

ROWS="$(kernel_rows)"

releases_with_anchor() {
  local want="$1" rel _pkg _size anchor
  while IFS=$'\t' read -r rel _pkg _size anchor; do
    [[ "$anchor" == "$want" ]] || continue
    valid_release "$rel" || continue
    printf '%s\n' "$rel"
  done <<<"$ROWS"
}

# Oldest first, by version rather than by byte: 6.1.0-9 sorts before 6.1.0-10.
RELEASES="$(releases_with_anchor 1 | sort -Vu)"
if [[ -z "$RELEASES" && "$PKG_MGR" == "dnf" ]]; then
  RELEASES="$(releases_with_anchor 2 | sort -Vu)"
fi

# Debian and Ubuntu also ship a flavour-less common headers package that every
# flavour of that base version shares: linux-headers-6.8.0-79 on Ubuntu beside
# linux-image-6.8.0-79-generic, linux-headers-6.1.0-9-common on Debian beside
# linux-image-6.1.0-9-amd64. It goes with the first release of its
# base, and only when no kept release still uses the same base.
# The base is the ABI prefix (6.8.0-79, 6.1.0-9), so one- and two-part flavours
# (-generic, -amd64, -cloud-amd64, -rt-amd64) of an ABI share one base. Debian
# backports and point kernels name it by the Debian release instead, with no
# ABI number: linux-image-6.12.107+deb12-amd64 pairs with
# linux-headers-6.12.107+deb12-common, so +debNN ends the base (6.12.107+deb12).
base_of() {
  local re='^[0-9]+(\.[0-9]+)*(\+deb[0-9]+|-[0-9]+)'
  [[ "$1" =~ $re ]] && printf '%s\n' "${BASH_REMATCH[0]}"
}

common_headers_for() {
  local want="$1" base rel other pkg _size _anchor first=""
  [[ "$PKG_MGR" == "apt" ]] || return 0
  base="$(base_of "$want")" || return 0
  [[ -n "$base" ]] || return 0
  while IFS= read -r other; do
    [[ -n "$other" && "$(base_of "$other")" == "$base" ]] || continue
    in_keep "$other" && return 0
    [[ -n "$first" ]] || first="$other"
  done <<<"$RELEASES"
  [[ "$first" == "$want" ]] || return 0
  while IFS=$'\t' read -r rel pkg _size _anchor; do
    [[ "$pkg" == "linux-headers-$base" || "$pkg" == "linux-headers-$base-common" ]] \
      && printf '%s\n' "$pkg"
  done <<<"$ROWS"
  return 0
}

packages_for() {
  local want="$1" rel pkg _size _anchor
  while IFS=$'\t' read -r rel pkg _size _anchor; do
    [[ "$rel" == "$want" && -n "$pkg" ]] && printf '%s\n' "$pkg"
  done <<<"$ROWS"
  common_headers_for "$want"
}

bytes_for() {
  local want="$1" rel _pkg size _anchor total=0 common
  while IFS=$'\t' read -r rel _pkg size _anchor; do
    [[ "$rel" == "$want" && "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
  done <<<"$ROWS"
  common="$(common_headers_for "$want")"
  if [[ -n "$common" ]]; then
    while IFS=$'\t' read -r rel _pkg size _anchor; do
      grep -qxF -- "$_pkg" <<<"$common" && [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
    done <<<"$ROWS"
  fi
  printf '%s\n' "$total"
}

# /boot is reported where it is its own filesystem, which is where it fills up.
boot_is_mount() {
  [[ -d /boot ]] || return 1
  [[ "$(df -P /boot 2>/dev/null | awk 'NR == 2 { print $6 }')" == "/boot" ]]
}

boot_df() {
  local where="/"
  [[ -d /boot ]] && where="/boot"
  df -h "$where" 2>/dev/null | sed 's/^/  /'
}

total=0
NEWEST=""
if [[ -n "$RELEASES" ]]; then
  total="$(grep -c . <<<"$RELEASES")"
  NEWEST="$(tail -n 1 <<<"$RELEASES")"
fi

# Space-delimited set of releases to keep: the running kernel, then the newest
# --keep of the others, so --keep counts kernels besides the running one.
# Release strings carry no spaces; valid_release() above guarantees it.
KEEP_SET=" $RELEASE "
in_keep() { [[ "$KEEP_SET" == *" $1 "* ]]; }
if [[ -n "$RELEASES" ]]; then
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && ! in_keep "$rel" && KEEP_SET="$KEEP_SET$rel "
  done < <(grep -vxF -- "$RELEASE" <<<"$RELEASES" | tail -n "$KEEP")
  in_keep "$NEWEST" || KEEP_SET="$KEEP_SET$NEWEST "
fi

running_installed=0
grep -qxF -- "$RELEASE" <<<"$RELEASES" && running_installed=1

kept_installed() {
  local rel count=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && in_keep "$rel" && count=$((count + 1))
  done <<<"$RELEASES"
  printf '%s\n' "$count"
}

# Never leave fewer than two kernels installed. When the running kernel is not
# an installed package (a container or a chroot) and --keep is 1, the set above
# holds one; a fallback is what lets a bad kernel be survived, so the newest of
# the rest stays too.
floor_note=""
if (( total >= 2 )) && (( $(kept_installed) < 2 )); then
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if ! in_keep "$rel"; then
      KEEP_SET="$KEEP_SET$rel "
      floor_note="$rel"
      break
    fi
  done < <(sort -Vr <<<"$RELEASES")
fi

CANDIDATES=""
if [[ -n "$RELEASES" ]]; then
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    in_keep "$rel" || CANDIDATES="$CANDIDATES$rel"$'\n'
  done <<<"$RELEASES"
fi

state_of() {
  if [[ "$1" == "$RELEASE" ]]; then
    printf 'running\n'
  elif in_keep "$1"; then
    printf 'keep\n'
  else
    printf 'remove\n'
  fi
}

step "kernels ($PKG_MGR)"
info "running $RELEASE · keeping the newest $KEEP besides it"
if [[ -n "$RELEASES" ]] && (( running_installed == 0 )); then
  warn "the running kernel $RELEASE is not one of the installed kernel packages"
  warn "  (a container or a chroot?); the newest $KEEP installed are kept instead"
fi
[[ -n "$floor_note" ]] && warn "also keeping $floor_note: at least two kernels always stay installed"

if (( LIST == 1 )); then
  if [[ -z "$RELEASES" ]]; then
    info "no versioned kernel packages are installed"
  else
    printf "  %-34s %-8s %s\n" "RELEASE" "STATE" "PACKAGES"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      printf "  %-34s %-8s %s\n" "$rel" "$(state_of "$rel")" "$(packages_for "$rel" | tr '\n' ' ' | sed 's/ $//')"
    done <<<"$RELEASES"
  fi
  if boot_is_mount; then
    printf "\n"
    boot_df
  fi
  exit 0
fi

if [[ -z "$CANDIDATES" ]]; then
  info "nothing to remove (running $RELEASE, $(kept_installed) kept)"
  if (( DRY_RUN == 1 )); then
    printf "dry-run complete; no changes written\n"
  fi
  exit 0
fi

pkgs=()
removing=""
would_bytes=0
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  rel_pkgs="$(packages_for "$rel" | LC_ALL=C sort -u)"
  info "remove $rel: $(tr '\n' ' ' <<<"$rel_pkgs" | sed 's/ $//')"
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && pkgs+=("$pkg")
  done <<<"$rel_pkgs"
  removing="$removing $rel"
  would_bytes=$((would_bytes + $(bytes_for "$rel")))
done <<<"$CANDIDATES"
removing="${removing# }"
count="$(wc -w <<<"$removing" | tr -d ' ')"
label="remove $count old kernel(s): $removing"

if (( DRY_RUN == 0 )); then
  boot_df
fi

case "$PKG_MGR" in
  apt) run_root "$label" apt-get purge --yes "${pkgs[@]}" ;;
  dnf) run_root "$label" dnf remove -y "${pkgs[@]}" ;;
esac

printf "\n"
if (( DRY_RUN == 1 )); then
  info "would free about $(human_bytes "$would_bytes")"
  printf "dry-run complete; no changes written\n"
  exit 0
fi

if [[ "$SUDO" == "skip" ]]; then
  exit 0
fi
if (( FAIL_COUNT > 0 )); then
  boot_df
  exit 1
fi
for rel in $removing; do
  ok "removed kernel $rel"
done
boot_df
exit 0

#!/usr/bin/env bash
# Drive kernel_cleanup.sh through every package-manager path with stubbed
# package tools, so no container ever lists or removes a real kernel.
set -uo pipefail

# OS_RELEASE picks the package manager; each case below passes its own.
unset OS_RELEASE

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
KCLEAN="$REPO_ROOT/linux/kernel_cleanup.sh"
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/bin" || exit 1
STUB_DIR="$fixture"
export STUB_DIR
checks=0
failures=0
assert_eq() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (expected %s, got %s)\n' "$1" "$2" "$3" >&2
    failures=$((failures + 1))
  fi
}
assert_contains() {
  checks=$((checks + 1))
  if [[ "$2" == *"$3"* ]]; then
    printf '[ ok ] %s\n' "$1"
  else
    printf '[fail] %s (missing %s)\n' "$1" "$3" >&2
    printf '%s\n' "$2" | head -20 >&2
    failures=$((failures + 1))
  fi
}
assert_not_contains() {
  checks=$((checks + 1))
  if [[ "$2" == *"$3"* ]]; then
    printf '[fail] %s (unexpected %s)\n' "$1" "$3" >&2
    printf '%s\n' "$2" | head -20 >&2
    failures=$((failures + 1))
  else
    printf '[ ok ] %s\n' "$1"
  fi
}

# Four versioned Debian kernels, their headers, the metapackage that pulls the
# newest one in, and a purged kernel whose config files are all that is left.
printf '%s\t%s\t%s\n' \
  linux-image-6.1.0-15-amd64 'install ok installed' 400000 \
  linux-image-6.1.0-17-amd64 'install ok installed' 400000 \
  linux-image-6.1.0-18-amd64 'install ok installed' 400000 \
  linux-image-6.1.0-20-amd64 'install ok installed' 400000 \
  linux-headers-6.1.0-15-amd64 'install ok installed' 20000 \
  linux-headers-6.1.0-17-amd64 'install ok installed' 20000 \
  linux-headers-6.1.0-20-amd64 'install ok installed' 20000 \
  linux-image-amd64 'install ok installed' 1 \
  linux-image-6.1.0-9-amd64 'deinstall ok config-files' 1 \
  > "$fixture/dpkg.rows"
printf '%s\t%s\t%s\n' \
  kernel 6.10.1-200.fc41.x86_64 0 \
  kernel-core 6.10.1-200.fc41.x86_64 70000000 \
  kernel-modules 6.10.1-200.fc41.x86_64 60000000 \
  kernel 6.11.2-300.fc41.x86_64 0 \
  kernel-core 6.11.2-300.fc41.x86_64 70000000 \
  kernel-modules 6.11.2-300.fc41.x86_64 60000000 \
  kernel 6.11.4-301.fc41.x86_64 0 \
  kernel-core 6.11.4-301.fc41.x86_64 70000000 \
  kernel-modules 6.11.4-301.fc41.x86_64 60000000 \
  kernel-headers 6.11.0-100.fc41.x86_64 1000 \
  > "$fixture/rpm.rows"

cat > "$fixture/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_DIR/dpkg.rows"
STUB
cat > "$fixture/bin/rpm" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_DIR/rpm.rows"
STUB
# The removal tools only record what they were asked to do.
for tool in apt-get apt dnf pacman; do
  cat > "$fixture/bin/$tool" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$STUB_DIR/calls"
exit "${STUB_RC:-0}"
STUB
done
# Whoever runs this suite, sudo must never reach the real package manager:
# the stub keeps PATH, so it runs the recording stubs above.
cat > "$fixture/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
chmod +x "$fixture/bin/"*

printf 'ID=debian\n' > "$fixture/os-debian"
printf 'ID=fedora\n' > "$fixture/os-fedora"
printf 'ID=arch\n' > "$fixture/os-arch"
printf 'ID=gentoo\nID_LIKE=gentoo\n' > "$fixture/os-gentoo"

# run_kc OS ARGS... — output in $out, exit status in $rc, call log reset first.
run_kc() {
  local os="$1"; shift
  : > "$fixture/calls"
  out="$(OS_RELEASE="$fixture/os-$os" PATH="$fixture/bin:$PATH" "$KCLEAN" "$@" 2>&1)"
  rc=$?
  calls="$(cat "$fixture/calls")"
}

out="$("$KCLEAN" --help 2>&1)"; rc=$?
assert_eq '--help exits 0' 0 "$rc"
assert_contains '--help documents exit codes' "$out" 'Exit codes:'

run_kc debian --release 6.1.0-20-amd64
assert_eq 'no --yes and no --dry-run -> 3' 3 "$rc"
assert_eq 'refusal ran nothing' '' "$calls"

for bad in '--keep 0' '--keep=abc' '--keep 99' '--keep' '--keep=21'; do
  # shellcheck disable=SC2086  # each entry is one or two words on purpose
  run_kc debian --dry-run --release 6.1.0-20-amd64 $bad
  assert_eq "$bad -> 3" 3 "$rc"
done

run_kc debian --dry-run --release 'bad release'
assert_eq '--release with a space -> 3' 3 "$rc"

run_kc debian --dry-run --release 6.1.0-20-amd64 --keep 1
assert_eq 'debian dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_contains 'dry run previews the purge' "$purge_line" '(dry-run)'
assert_contains 'dry run previews apt-get purge' "$purge_line" 'apt-get purge --yes'
assert_contains 'dry run removes 6.1.0-15' "$purge_line" 'linux-image-6.1.0-15-amd64'
assert_contains 'dry run takes the headers along' "$purge_line" 'linux-headers-6.1.0-15-amd64'
assert_contains 'dry run removes 6.1.0-17' "$purge_line" 'linux-image-6.1.0-17-amd64'
assert_not_contains 'dry run keeps one besides the running kernel' "$purge_line" '6.1.0-18'
assert_not_contains 'dry run keeps the running kernel' "$purge_line" '6.1.0-20'
assert_not_contains 'the metapackage is never a candidate' "$out" 'linux-image-amd64'
assert_not_contains 'a config-files-only kernel is not installed' "$out" '6.1.0-9-amd64'
assert_not_contains '--keep 1 beside the running kernel needs no floor' "$out" 'at least two kernels'
assert_contains 'dry run estimates the space' "$out" 'would free about'
assert_contains 'dry run closes with the linux/ summary' "$out" 'dry-run complete; no changes written'
assert_eq 'dry run executed nothing' '' "$calls"

run_kc debian --yes --release 6.1.0-20-amd64 --keep 1
assert_eq 'debian --yes exits 0' 0 "$rc"
assert_eq 'exactly one package-manager call' 1 "$(grep -c . <<<"$calls")"
assert_contains 'the call is apt-get purge' "$calls" 'apt-get purge --yes'
assert_contains 'purge names 6.1.0-15' "$calls" 'linux-image-6.1.0-15-amd64'
assert_contains 'purge names 6.1.0-17' "$calls" 'linux-image-6.1.0-17-amd64'
assert_not_contains 'purge spares 6.1.0-18' "$calls" '6.1.0-18'
assert_not_contains 'purge spares the running kernel' "$calls" '6.1.0-20'
assert_not_contains 'purge spares the metapackage' "$calls" 'linux-image-amd64'
assert_not_contains 'purge never autoremoves' "$calls" 'autoremove'
assert_contains 'each removed kernel is reported' "$out" 'removed kernel 6.1.0-15-amd64'

run_kc debian --yes --no-sudo --release 6.1.0-20-amd64 --keep 1
assert_eq '--no-sudo exits 0' 0 "$rc"
assert_contains '--no-sudo says what it skipped' "$out" 'skipped (needs root)'
assert_eq '--no-sudo runs nothing' '' "$calls"

STUB_RC=1 run_kc debian --yes --release 6.1.0-20-amd64 --keep 1
assert_eq 'a failed purge -> 1' 1 "$rc"
assert_not_contains 'a failed purge reports nothing as removed' "$out" 'removed kernel'

run_kc debian --list --release 6.1.0-20-amd64
assert_eq '--list exits 0' 0 "$rc"
assert_contains '--list marks the running kernel' "$(grep '6.1.0-20-amd64' <<<"$out")" 'running'
assert_contains '--list marks the oldest for removal' "$(grep '6.1.0-15-amd64' <<<"$out")" 'remove'
assert_contains '--list keeps the newest two besides the running kernel' "$(grep '6.1.0-18-amd64' <<<"$out")" 'keep'
assert_contains '--list keeps the second of the two by default' "$(grep '6.1.0-17-amd64' <<<"$out")" 'keep'
assert_eq '--list runs nothing' '' "$calls"

run_kc debian --dry-run --release 6.1.0-15-amd64 --keep 1
assert_eq 'oldest-running dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_not_contains 'the running kernel stays when it is the oldest' "$purge_line" '6.1.0-15'
assert_not_contains 'the newest installed kernel stays' "$purge_line" '6.1.0-20'
assert_contains 'the kernels between them go' "$purge_line" 'linux-image-6.1.0-17-amd64'

# A running kernel that is not installed (a container or a chroot) leaves the
# newest alone in the set under --keep 1, so the floor keeps the next-newest.
run_kc debian --dry-run --release 6.1.0-99-amd64 --keep 1
assert_eq 'not-installed running kernel dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_contains 'the uninstalled running kernel is reported' "$out" 'is not one of the installed kernel packages'
assert_not_contains 'the newest installed kernel stays without a running one' "$purge_line" '6.1.0-20'
assert_not_contains 'the floor keeps the next-newest' "$purge_line" '6.1.0-18'
assert_contains 'the floor is announced' "$out" 'at least two kernels'
assert_contains 'the older kernels go' "$purge_line" 'linux-image-6.1.0-17-amd64'

run_kc debian --dry-run --release 6.1.0-20-amd64 --keep 5
assert_eq 'nothing to remove exits 0' 0 "$rc"
assert_contains 'nothing to remove says so' "$out" 'nothing to remove'

run_kc fedora --yes --release 6.11.4-301.fc41.x86_64 --keep 1
assert_eq 'fedora --yes exits 0' 0 "$rc"
assert_contains 'fedora removes through dnf' "$calls" 'dnf remove -y'
assert_contains 'fedora names the versioned kernel-core' "$calls" 'kernel-core-6.10.1-200.fc41.x86_64'
assert_contains 'fedora names the versioned modules' "$calls" 'kernel-modules-6.10.1-200.fc41.x86_64'
assert_contains 'fedora names the versioned kernel' "$calls" 'kernel-6.10.1-200.fc41.x86_64'
assert_not_contains 'fedora spares the newer kernels' "$calls" '6.11.'
assert_not_contains 'fedora never names kernel-headers' "$calls" 'kernel-headers'

run_kc arch --dry-run
assert_eq 'arch exits 0' 0 "$rc"
assert_contains 'arch explains there is nothing to prune' "$out" 'one copy'
assert_eq 'arch runs nothing' '' "$calls"

run_kc gentoo --dry-run --release 6.1.0-20-amd64
assert_eq 'an unsupported distribution -> 2' 2 "$rc"

# Every distro fixture reaches a read-only answer. Counted, because a loop that
# matched nothing would pass this file with the checks above unchanged.
distros_run=0
for os in debian fedora arch; do
  distros_run=$((distros_run + 1))
  run_kc "$os" --list --release 6.1.0-20-amd64
  assert_eq "$os --list exits 0" 0 "$rc"
  assert_eq "$os --list runs no removal" '' "$calls"
done
assert_eq 'three distro fixtures exercised' 3 "$distros_run"

# Ubuntu also installs a flavour-less common headers package per base version.
# It goes with the first release of its base, and stays while a kept release
# (here the lowlatency flavour of 6.8.0-71) still uses it.
printf '%s\t%s\t%s\n' \
  linux-image-6.8.0-70-generic 'install ok installed' 400000 \
  linux-headers-6.8.0-70-generic 'install ok installed' 20000 \
  linux-headers-6.8.0-70 'install ok installed' 90000 \
  linux-image-6.8.0-71-generic 'install ok installed' 400000 \
  linux-image-6.8.0-71-lowlatency 'install ok installed' 400000 \
  linux-headers-6.8.0-71 'install ok installed' 90000 \
  linux-image-6.8.0-79-generic 'install ok installed' 400000 \
  linux-headers-6.8.0-79 'install ok installed' 90000 \
  linux-headers-generic 'install ok installed' 10 \
  > "$fixture/dpkg.rows"
run_kc debian --dry-run --release 6.8.0-79-generic --keep 1
assert_eq 'ubuntu dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_contains 'the old release image goes' "$purge_line" 'linux-image-6.8.0-70-generic'
assert_contains 'the old flavour headers go' "$purge_line" 'linux-headers-6.8.0-70-generic'
assert_contains 'the common headers of a removed base go' "$purge_line" 'linux-headers-6.8.0-70 '
assert_contains 'a sibling of a kept flavour goes' "$purge_line" 'linux-image-6.8.0-71-generic'
assert_not_contains 'common headers stay while a kept release shares the base' "$purge_line" 'linux-headers-6.8.0-71 '
assert_not_contains 'common headers of the running base stay' "$purge_line" 'linux-headers-6.8.0-79'
assert_not_contains 'the headers metapackage stays' "$purge_line" 'linux-headers-generic'

# Debian names it linux-headers-<base>-common and has no flavour in the image.
printf '%s\t%s\t%s\n' \
  linux-image-6.1.0-9-amd64 'install ok installed' 300000 \
  linux-headers-6.1.0-9-amd64 'install ok installed' 20000 \
  linux-headers-6.1.0-9-common 'install ok installed' 80000 \
  linux-image-6.1.0-10-amd64 'install ok installed' 300000 \
  linux-headers-6.1.0-10-common 'install ok installed' 80000 \
  linux-image-6.1.0-11-amd64 'install ok installed' 300000 \
  linux-headers-6.1.0-11-common 'install ok installed' 80000 \
  linux-headers-amd64 'install ok installed' 10 \
  > "$fixture/dpkg.rows"
run_kc debian --dry-run --release 6.1.0-11-amd64 --keep 1
assert_eq 'debian common headers dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_contains 'debian old image goes' "$purge_line" 'linux-image-6.1.0-9-amd64'
assert_contains 'debian common headers of a removed base go' "$purge_line" 'linux-headers-6.1.0-9-common'
assert_not_contains 'debian common headers of a kept base stay' "$purge_line" 'linux-headers-6.1.0-10-common'
assert_not_contains 'debian common headers of the running base stay' "$purge_line" 'linux-headers-6.1.0-11-common'
assert_not_contains 'debian headers metapackage stays' "$purge_line" 'linux-headers-amd64'

# Debian point and backport kernels carry no ABI number: the base is the
# +debNN release (6.12.107+deb12), and its common headers must be found next
# to old-style names. 6.12.107+deb12-amd64 and -cloud-amd64 share one base.
printf '%s\t%s\t%s\n' \
  linux-image-6.1.0-9-amd64 'install ok installed' 300000 \
  linux-headers-6.1.0-9-common 'install ok installed' 80000 \
  linux-image-6.12.90+deb12-amd64 'install ok installed' 300000 \
  linux-headers-6.12.90+deb12-amd64 'install ok installed' 20000 \
  linux-headers-6.12.90+deb12-common 'install ok installed' 80000 \
  linux-image-6.12.100+deb12-amd64 'install ok installed' 300000 \
  linux-headers-6.12.100+deb12-common 'install ok installed' 80000 \
  linux-image-6.12.107+deb12-amd64 'install ok installed' 300000 \
  linux-headers-6.12.107+deb12-common 'install ok installed' 80000 \
  linux-headers-amd64 'install ok installed' 10 \
  > "$fixture/dpkg.rows"
run_kc debian --dry-run --release 6.12.107+deb12-amd64 --keep 1
assert_eq 'debian +deb names dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_contains 'a +deb old image goes' "$purge_line" 'linux-image-6.12.90+deb12-amd64'
assert_contains 'the +deb common headers of a removed base go' "$purge_line" 'linux-headers-6.12.90+deb12-common'
assert_not_contains 'the +deb common headers of a kept base stay' "$purge_line" 'linux-headers-6.12.100+deb12-common'
assert_contains 'old-style common headers go beside +deb names' "$purge_line" 'linux-headers-6.1.0-9-common'
assert_not_contains 'the +deb common headers of the running base stay' "$purge_line" 'linux-headers-6.12.107+deb12-common'
assert_not_contains 'the headers metapackage stays beside +deb names' "$purge_line" 'linux-headers-amd64'

# Debian backports carry a bare +bpo: 6.12.12+bpo-amd64 pairs with
# linux-headers-6.12.12+bpo-common.
printf '%s\t%s\t%s\n' \
  linux-image-6.12.12+bpo-amd64 'install ok installed' 300000 \
  linux-headers-6.12.12+bpo-common 'install ok installed' 80000 \
  linux-image-6.12.20+bpo-amd64 'install ok installed' 300000 \
  linux-headers-6.12.20+bpo-common 'install ok installed' 80000 \
  > "$fixture/dpkg.rows"
run_kc debian --dry-run --release 6.12.20+bpo-amd64 --keep 1
assert_eq 'debian +bpo names dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_contains 'a +bpo old image goes' "$purge_line" 'linux-image-6.12.12+bpo-amd64'
assert_contains 'the +bpo common headers of a removed base go' "$purge_line" 'linux-headers-6.12.12+bpo-common'
assert_not_contains 'the +bpo common headers of the running base stay' "$purge_line" 'linux-headers-6.12.20+bpo-common'

# Two-part Debian flavours share the base of the plain flavour: with
# 6.1.0-9-cloud-amd64 kept (running), removing 6.1.0-9-amd64 must leave the
# common headers the kept flavour's headers depend on.
printf '%s\t%s\t%s\n' \
  linux-image-6.1.0-9-amd64 'install ok installed' 300000 \
  linux-headers-6.1.0-9-amd64 'install ok installed' 20000 \
  linux-headers-6.1.0-9-common 'install ok installed' 80000 \
  linux-image-6.1.0-9-cloud-amd64 'install ok installed' 300000 \
  linux-headers-6.1.0-9-cloud-amd64 'install ok installed' 20000 \
  linux-image-6.1.0-10-amd64 'install ok installed' 300000 \
  linux-headers-6.1.0-10-common 'install ok installed' 80000 \
  > "$fixture/dpkg.rows"
run_kc debian --dry-run --release 6.1.0-9-cloud-amd64 --keep 1
assert_eq 'mixed flavour dry run exits 0' 0 "$rc"
purge_line="$(grep 'apt-get purge' <<<"$out")"
assert_contains 'the removed flavour image goes' "$purge_line" 'linux-image-6.1.0-9-amd64'
assert_not_contains 'common headers stay for a kept sibling flavour' "$purge_line" 'linux-headers-6.1.0-9-common'
assert_not_contains 'the kept flavour headers stay' "$purge_line" 'linux-headers-6.1.0-9-cloud-amd64'

if (( checks == 0 || failures > 0 )); then
  printf '%s of %s kernel cleanup checks failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf '=== all %s kernel cleanup checks passed ===\n' "$checks"

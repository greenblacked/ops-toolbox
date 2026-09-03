#!/usr/bin/env bash
# Run from a Linux tester container; repo root is mounted read-only at /repo.
#
# Unlike the macOS suite, which can only parse the scripts it tests, these run
# for real: the container *is* the target OS. That is the whole reason this
# suite is worth having.
#
# The mount is read-only, so anything that writes must be pointed at /tmp. A
# test that quietly wrote into /repo would pass here and fail in CI.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
L="$REPO_ROOT/linux"
EXPECT_PKG_MGR="${EXPECT_PKG_MGR:-apt}"

if [[ ! -d "$L" ]]; then
  echo "expected linux/ at $L" >&2
  exit 1
fi

failures=0
ok()  { echo "[ ok ] $*"; }
err() { echo "[fail] $*" >&2; failures=$((failures + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$label"
  else
    err "$label (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    err "$label (missing '$needle')"
    printf '%s\n' "$haystack" | head -20 >&2
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    err "$label (unexpected '$needle')"
    printf '%s\n' "$haystack" | head -20 >&2
  else
    ok "$label"
  fi
}

# Discovered rather than listed. A hardcoded array only covers a new script if
# someone remembers to add it, which is how the macOS suite silently stopped
# covering two of its own scripts. bash_aliases.sh is excluded deliberately: it
# is sourced, not run, so the --help and unknown-flag contracts do not apply to
# it. Built without mapfile to stay Bash 3.2-clean (see CONTRIBUTING.md).
#
# Depth 2 so subdirectories such as systemd/ are covered too; tests/ is the one
# subdirectory left out, because this file lives in it. A script that needs a
# running systemd fails its own preflight in these containers, which is exactly
# why --help and the unknown-flag contract have to hold *before* preflight.
scripts=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "${f##*/}" in bash_aliases.sh) continue ;; esac
  scripts+=("$f")
done < <(find "$L" -maxdepth 2 -name '*.sh' -type f ! -path "$L/tests/*" | sort)

if (( ${#scripts[@]} == 0 )); then
  echo "discovered no scripts under $L — discovery is broken" >&2
  exit 1
fi
ok "discovered ${#scripts[@]} scripts under linux/"

echo "=== distro: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '\"') (expecting $EXPECT_PKG_MGR) ==="

# --- syntax ---
for f in "${scripts[@]}" "$L/bash_aliases.sh"; do
  if bash -n "$f"; then ok "bash -n ${f#"$REPO_ROOT/"}"; else err "bash -n ${f#"$REPO_ROOT/"}"; fi
done

# --- help contract, before any preflight ---
for f in "${scripts[@]}"; do
  if "$f" --help >/dev/null 2>&1; then ok "${f##*/} --help"; else err "${f##*/} --help"; fi
done

# --- unknown flag -> 3 ---
for f in "${scripts[@]}"; do
  set +e
  "$f" --definitely-not-a-valid-flag-12345 >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "${f##*/} unknown flag -> 3" "3" "$rc"
done

# --- distro detection picks the right package manager ---
out="$("$L/stay_fresh.sh" --dry-run 2>&1)"
assert_contains "stay_fresh detects $EXPECT_PKG_MGR" "$out" "package manager: $EXPECT_PKG_MGR"
if command -v needs-restarting >/dev/null 2>&1 || command -v needrestart >/dev/null 2>&1; then
  if grep -qE 'old libraries|stale services|no processes listed as needing a restart|needrestart reports no stale' <<<"$out"; then
    ok "stay_fresh report mentions stale processes when the tool exists"
  else
    err "stay_fresh has needrestart/needs-restarting but did not mention stale processes"
  fi
else
  ok "stay_fresh stale-process note skipped (no needrestart)"
fi

# --- an unsupported distro exits 2 ---
# The whole reason detect_pkg_mgr reads $OS_RELEASE instead of /etc/os-release
# directly: without the seam this path is untestable, since a container cannot
# pretend to be Gentoo.
fake="/tmp/fake-os-release"
printf 'ID=gentoo\nID_LIKE=gentoo\n' > "$fake"
set +e
OS_RELEASE="$fake" "$L/stay_fresh.sh" --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_eq "unsupported distro -> 2" "2" "$rc"

# --- dry run changes nothing ---
# Counting installed packages before and after is the assertion that actually
# matters: the dry-run promise is the core of this repository.
count_packages() {
  case "$EXPECT_PKG_MGR" in
    apt)    dpkg-query -f '.\n' -W 2>/dev/null | wc -l ;;
    dnf)    rpm -qa 2>/dev/null | wc -l ;;
    pacman) pacman -Qq 2>/dev/null | wc -l ;;
  esac
}

# --- Kali cloud-init contracts -------------------------------------------
KALI_CLOUD_INIT="$L/cloud-init/kali-vm-init.yaml"
if python3 - "$KALI_CLOUD_INIT" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    data = yaml.safe_load(stream)

assert data["timezone"] == "Europe/Kyiv"
assert data["growpart"]["mode"] == "off"
assert data["resize_rootfs"] is False
assert data["ssh_pwauth"] is False
assert data["disable_root"] is True
assert data["runcmd"][-1] == [
    "systemctl", "start", "--no-block", "ops-toolbox-kali-init.service"
]

files = {entry["path"]: entry for entry in data["write_files"]}
assert "/etc/ssh/sshd_config.d/99-local-lab.conf" in files
assert "PasswordAuthentication no" in files[
    "/etc/ssh/sshd_config.d/99-local-lab.conf"
]["content"]
assert "/usr/local/sbin/ops-toolbox-kali-finalize" in files
finalizer = files["/usr/local/sbin/ops-toolbox-kali-finalize"]["content"]
assert all(package in finalizer for package in (
    "openssh-server", "ufw", "seclists", "iputils-ping", "traceroute",
    "mtr-tiny", "nmap", "tcpdump", "tshark", "socat", "ethtool",
    "iproute2", "nftables", "conntrack",
    "kali-tools-information-gathering", "kali-tools-vulnerability",
    "kali-tools-sniffing-spoofing", "kali-tools-exploitation",
    "kali-tools-post-exploitation", "kali-tools-detect",
    "kali-tools-protect", "kali-tools-respond", "kali-tools-forensics",
))
assert "Acquire::https::Timeout=30" in finalizer
assert "ufw --force enable" not in finalizer
assert "/etc/systemd/system/ops-toolbox-kali-init.service" in files
assert "/usr/local/bin/kali-lab-status" in files
status = files["/usr/local/bin/kali-lab-status"]["content"]
assert "kali-vm-init.complete" in status
assert "Usage: kali-lab-status [--help]" in status
assert "unknown argument:" in status
assert "exit 4" in status
PY
then
  ok "Kali cloud-init YAML parses and keeps its security contracts"
else
  err "Kali cloud-init YAML is invalid or violates its security contracts"
fi

KALI_STATUS=/tmp/kali-lab-status
python3 - "$KALI_CLOUD_INIT" > "$KALI_STATUS" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    data = yaml.safe_load(stream)
for entry in data["write_files"]:
    if entry["path"] == "/usr/local/bin/kali-lab-status":
        print(entry["content"], end="")
        break
else:
    raise SystemExit("embedded kali-lab-status not found")
PY
chmod +x "$KALI_STATUS"
if "$KALI_STATUS" --help 2>&1 | grep -q 'Exit codes:'; then
  ok "embedded kali-lab-status --help"
else
  err "embedded kali-lab-status --help contract"
fi
set +e
"$KALI_STATUS" --definitely-not-valid >/dev/null 2>&1
rc=$?
set -e
assert_eq "embedded kali-lab-status unknown flag -> 3" "3" "$rc"

before="$(count_packages)"
"$L/stay_fresh.sh" --dry-run >/dev/null 2>&1
"$L/install_devtools.sh" --dry-run >/dev/null 2>&1
after="$(count_packages)"
assert_eq "dry runs installed nothing" "$before" "$after"

# --- dry run says so, and says nothing was written ---
out="$("$L/install_devtools.sh" --dry-run 2>&1)"
assert_contains "install_devtools dry-run reports no changes" "$out" "dry-run complete; no changes written"

out="$("$L/install_devtools.sh" --dry-run --only clis 2>&1)"
assert_contains "install_devtools --only scopes toolchains" "$out" "skipped: toolchains"
assert_contains "install_devtools --only still runs selected group" "$out" "== DevOps CLIs =="

out="$("$L/install_devtools.sh" --dry-run --only clis --setup-shell 2>&1)"
assert_contains "install_devtools --setup-shell still installs its mise prerequisite" "$out" "install mise"
assert_contains "install_devtools --setup-shell remains effective with only clis" "$out" "would append"

out="$("$L/stay_fresh.sh" --dry-run --only caches 2>&1)"
assert_contains "stay_fresh --only skips unselected steps" "$out" "skipped: packages"
assert_contains "stay_fresh --only runs selected step" "$out" "== user caches =="

set +e
"$L/stay_fresh.sh" --dry-run --only caches --skip-snap >/dev/null 2>&1
rc=$?
set -e
assert_eq "stay_fresh rejects mixed scoping styles -> 3" "3" "$rc"

# --- installing without --yes refuses rather than proceeding ---
set +e
"$L/install_devtools.sh" >/dev/null 2>&1
rc=$?
set -e
assert_eq "install_devtools without --yes -> 3" "3" "$rc"

# --- packages.sh round-trips through a real package database ---
dump="/tmp/packages.$EXPECT_PKG_MGR.txt"
rm -f "$dump"
if "$L/packages.sh" dump --file "$dump" >/dev/null 2>&1; then
  ok "packages.sh dump"
else
  err "packages.sh dump"
fi

listed="$("$L/packages.sh" list)"
if [[ -n "$listed" ]] && [[ "$listed" == "$(printf '%s\n' "$listed" | LC_ALL=C sort -u)" ]]; then
  ok "packages.sh list prints a stable read-only inventory"
else
  err "packages.sh list was empty or unsorted"
fi

if [[ -s "$dump" ]] && grep -qvE '^\s*(#|$)' "$dump"; then
  ok "dump wrote at least one package"
else
  err "dump produced no packages"
fi

# dump twice; the file must be identical or diffs are noise
cp "$dump" /tmp/first.txt
"$L/packages.sh" dump --file "$dump" --force >/dev/null 2>&1
if diff -q <(grep -vE '^\s*#' /tmp/first.txt) <(grep -vE '^\s*#' "$dump") >/dev/null; then
  ok "dump is stable across runs"
else
  err "dump is not stable across runs"
fi

# everything just dumped is by definition installed
set +e
"$L/packages.sh" check --file "$dump" >/dev/null 2>&1
rc=$?
set -e
assert_eq "check passes against a fresh dump" "0" "$rc"

# a package that cannot exist must make check fail with 1, not crash
printf 'definitely-not-a-real-package-12345\n' >> "$dump"
set +e
"$L/packages.sh" check --file "$dump" >/dev/null 2>&1
rc=$?
set -e
assert_eq "check reports a missing package as 1" "1" "$rc"

set +e
out="$("$L/packages.sh" install --file "$dump" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "install --dry-run exits 0" "0" "$rc"
assert_contains "install --dry-run names the missing package" "$out" "definitely-not-a-real-package-12345"
assert_contains "install --dry-run reports no changes" "$out" "dry-run complete; no changes written"
assert_contains "install --dry-run uses the linux indented form" "$out" "(dry-run)"
assert_not_contains "install --dry-run does not mix git grammar" "$out" "dry-run: would run:"

# dump --dry-run must preview and leave the file byte-identical.
before_dump="$(cksum "$dump")"
set +e
out="$("$L/packages.sh" dump --file "$dump" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "dump --dry-run exits 0" "0" "$rc"
assert_contains "dump --dry-run reports no changes" "$out" "dry-run complete; no changes written"
assert_eq "dump --dry-run wrote nothing" "$before_dump" "$(cksum "$dump")"

set +e
"$L/packages.sh" dump --file --force >/dev/null 2>&1
rc=$?
set -e
assert_eq "packages.sh --file rejects the next flag as a path -> 3" "3" "$rc"

# --- aliases are sourceable, and guarded ---
if bash -c ". $L/bash_aliases.sh" >/dev/null 2>&1; then
  ok "bash_aliases.sh sources cleanly"
else
  err "bash_aliases.sh failed to source"
fi

# A shadow is only allowed when the replacement accepts the same flags. fd and
# rg do not - `find . -name` errors under fd, `grep -rn pattern dir` changes
# meaning under rg - so a command copied from a runbook breaks exactly on the
# machine that has the alias. Asserted as text because the aliases were
# guarded: in a container without fd installed they would never register, and a
# behavioural check would pass whether or not the shadow exists.
if grep -qE "alias (find|grep)='(fd|rg)'" "$L/bash_aliases.sh"; then
  err "bash_aliases.sh must not shadow find/grep with fd/rg"
else
  ok "bash_aliases: find and grep are not shadowed by fd/rg"
fi

# An alias to a binary that is not installed is worse than no alias, so the
# guards must actually guard.
out="$(bash -c ". $L/bash_aliases.sh; alias" 2>/dev/null)"
if command -v eza >/dev/null 2>&1; then
  ok "eza present; skipping the guard assertion"
else
  if grep -q "alias ls='eza" <<<"$out"; then
    err "eza is absent but the eza alias was still defined"
  else
    ok "eza absent, so no eza alias was defined"
  fi
fi

kubectl_stub="$(mktemp -d)"
ln -s "$(command -v git)" "$kubectl_stub/kubectl"
out="$(PATH="$kubectl_stub:$PATH" bash -c ". '$L/bash_aliases.sh'; alias kctx; alias kns; alias kpods" 2>&1)"
assert_contains "bash_aliases adds Kubernetes context helpers" "$out" "kubectl config current-context"
rm -rf "$kubectl_stub"

# Running it instead of sourcing it should say so rather than doing nothing.
set +e
bash "$L/bash_aliases.sh" >/dev/null 2>&1
rc=$?
set -e
assert_eq "bash_aliases.sh executed directly -> 3" "3" "$rc"

out="$(bash -c ". '$L/bash_aliases.sh'; alias stay-fresh; alias net-doctor; alias disk-cleanup; toolbox-help" 2>&1)"
assert_contains "bash_aliases aliases stay-fresh to this checkout" "$out" "stay_fresh.sh"
assert_contains "bash_aliases aliases net-doctor to this checkout" "$out" "net_doctor.sh"
assert_contains "bash_aliases aliases disk-cleanup to this checkout" "$out" "disk_cleanup.sh"
assert_contains "toolbox-help lists stay-fresh" "$out" "stay-fresh"
assert_contains "toolbox-help lists schedule-report" "$out" "schedule-report"
assert_contains "toolbox-help lists tls-expiry" "$out" "tls-expiry"
assert_contains "toolbox-help lists config-backup" "$out" "config-backup"
assert_contains "toolbox-help lists ssh-client-doctor" "$out" "ssh-client-doctor"

# --- stay_fresh degrades rather than failing when a tool is absent ---
# journald is not present in these containers. That must be a note, not a
# failure: the warn vs failure split is the documented contract.
set +e
out="$("$L/stay_fresh.sh" --yes --no-sudo --skip-packages --skip-containers 2>&1)"
rc=$?
set -e
assert_eq "stay_fresh survives missing optional tools" "0" "$rc"
assert_contains "stay_fresh reports the run finished" "$out" "done"

# --- the systemd timer builds its units without a running systemd ---
# --print-only is the seam that makes this testable at all: a container has no
# user manager, so install can never get past preflight here. Where
# systemd-analyze exists (fedora, arch) the script verifies the units before
# printing them, so a zero exit below is a real validation, not just a render.
TIMER="$L/systemd/stay_fresh_timer.sh"
set +e
out="$("$TIMER" install --print-only 2>&1)"; rc=$?
set -e
assert_eq "timer --print-only exits 0" "0" "$rc"
assert_contains "timer defaults to Monday 10:30" "$out" "OnCalendar=Mon *-*-* 10:30:00"
assert_contains "timer runs stay_fresh.sh" "$out" "$L/stay_fresh.sh\" --yes --no-sudo"
assert_contains "timer installs a [Timer] section" "$out" "[Timer]"

out="$("$TIMER" install --print-only --weekday daily --hour 3 --minute 5 --dry-run 2>&1)"
assert_contains "timer honours daily and the clock" "$out" "OnCalendar=*-*-* 03:05:00"
assert_contains "timer passes --dry-run through" "$out" "--yes --no-sudo --dry-run"

out="$("$TIMER" --help 2>&1)"
assert_contains "timer exposes read-only log inspection" "$out" "logs [--lines N]"

# --print-only must write nothing, the same promise --dry-run makes elsewhere.
scratch_home="$(mktemp -d)"
HOME="$scratch_home" XDG_CONFIG_HOME="$scratch_home/.config" \
  "$TIMER" install --print-only >/dev/null 2>&1
if [[ -e "$scratch_home/.config/systemd" ]]; then
  err "timer --print-only wrote into HOME"
else
  ok "timer --print-only wrote nothing"
fi
rm -rf "$scratch_home"

# --print-only was the only no-write path this suite exercised. `install
# --dry-run` on its own went straight past it: it wrote both unit files and ran
# `enable --now`. The run above pairs --print-only with --dry-run, so the
# print-only branch short-circuited and the dry-run path was never reached.
scratch_home="$(mktemp -d)"
set +e
HOME="$scratch_home" XDG_CONFIG_HOME="$scratch_home/.config" \
  "$TIMER" install --dry-run >/dev/null 2>&1; rc=$?
set -e
assert_eq "timer install --dry-run exits 0" "0" "$rc"
if [[ -n "$(find "$scratch_home" -type f 2>/dev/null)" ]]; then
  err "timer install --dry-run wrote into HOME"
else
  ok "timer install --dry-run wrote nothing"
fi
rm -rf "$scratch_home"

for bad in "--weekday 9" "--hour 24" "--minute 60"; do
  set +e
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$TIMER" install $bad >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "timer rejects $bad -> 3" "3" "$rc"
done

# No user manager in a container, so a real install must report the wrong
# environment rather than half-writing units.
set +e
"$TIMER" install >/dev/null 2>&1
rc=$?
set -e
assert_eq "timer install without systemd -> 2" "2" "$rc"

# --- hardening_audit is read-only and grades correctly ---
# The whole value of this script is that it never changes the machine, so that
# is asserted directly rather than assumed: snapshot the files it inspects and
# require them to be untouched.
before="$( { stat -c '%a %Y' /etc/shadow /etc/passwd 2>/dev/null; ls /etc/ssh 2>/dev/null; } || true )"
set +e
out="$("$L/hardening_audit.sh" 2>&1)"
rc=$?
set -e
after="$( { stat -c '%a %Y' /etc/shadow /etc/passwd 2>/dev/null; ls /etc/ssh 2>/dev/null; } || true )"
assert_eq "hardening_audit changed nothing it inspected" "$before" "$after"
assert_contains "hardening_audit prints a summary" "$out" "== summary =="

# The host-key grader was the one part of this audit nothing could reach: the
# tester images have no openssh-server, so /etc/ssh holds no keys and the check
# skipped. It shipped a rule that failed every stock Fedora host, and then one
# that passed a host whose ssh_keys group had members — opposite bugs, both in
# code no test ran. ETC_SSH exists so these branches are exercised.
audit_ssh="$(mktemp -d)"
grade_host_key() {  # mode -> the grader's line for that fixture
  printf 'not-a-real-key\n' > "$audit_ssh/ssh_host_ed25519_key"
  chmod "$1" "$audit_ssh/ssh_host_ed25519_key"
  # -A1: fail() prints its hint on the line after the verdict, and the hint is
  # half of what is being asserted here.
  ETC_SSH="$audit_ssh" "$L/hardening_audit.sh" --only files 2>&1 |
    grep -A1 -E 'ssh_host_ed25519_key mode' || true
}
assert_contains "hardening_audit passes a 600 host key" "$(grade_host_key 600)" "[pass]"
assert_contains "hardening_audit passes a 400 host key" "$(grade_host_key 400)" "[pass]"
assert_contains "hardening_audit fails a world-readable host key" "$(grade_host_key 644)" "[FAIL]"
assert_contains "hardening_audit fails a group-readable host key" "$(grade_host_key 640)" "[FAIL]"
# 640 is only acceptable as the Fedora/RHEL convention, which is safe because
# the ssh_keys group is empty. The fixture's group is the tester's own, so the
# exemption must not apply — and with no ssh_keys group present at all the
# lookup fails closed rather than granting it.
assert_contains "hardening_audit names group read, not a write bit" \
  "$(grade_host_key 640)" "can read this host private key"

# The Fedora exemption itself — 0640 owned by an *empty* ssh_keys group — needs
# that group to exist, and creating a system group is more than a test should
# do to the machine it runs on. So it is covered only where the image already
# has one, and the gap is stated rather than left to look like coverage.
if getent group ssh_keys >/dev/null 2>&1; then
  if [[ -z "$(getent group ssh_keys | awk -F: '{print $4}')" ]]; then
    chgrp ssh_keys "$audit_ssh/ssh_host_ed25519_key" 2>/dev/null &&
      assert_contains "hardening_audit passes 0640 owned by an empty ssh_keys" \
        "$(grade_host_key 640)" "[pass]"
  fi
else
  printf '  %s[info]%s no ssh_keys group here: the Fedora 0640 exemption is unverified\n' \
    "${C_DIM:-}" "${C_RESET:-}"
fi
rm -rf "$audit_ssh"

# A container has no firewall and no sshd, so a clean exit here proves absent
# tooling is reported rather than treated as a crash.
if [[ "$rc" == "0" || "$rc" == "1" ]]; then
  ok "hardening_audit exits 0 or 1, not an error ($rc)"
else
  err "hardening_audit exited $rc; expected 0 or 1"
fi

# --fail-on warn must be stricter than the default, never looser.
set +e
"$L/hardening_audit.sh" >/dev/null 2>&1; rc_default=$?
"$L/hardening_audit.sh" --fail-on warn >/dev/null 2>&1; rc_strict=$?
set -e
if (( rc_strict >= rc_default )); then
  ok "--fail-on warn is at least as strict as the default ($rc_default -> $rc_strict)"
else
  err "--fail-on warn ($rc_strict) was looser than the default ($rc_default)"
fi

set +e
"$L/hardening_audit.sh" --only nosuchgroup >/dev/null 2>&1; rc=$?
set -e
assert_eq "hardening_audit rejects an unknown group -> 3" "3" "$rc"

set +e
out="$("$L/hardening_audit.sh" --only kernel 2>&1)"; rc=$?
set -e
assert_contains "hardening_audit has kernel controls" "$out" "== kernel =="
if [[ "$rc" == "0" || "$rc" == "1" ]]; then
  ok "hardening_audit kernel group reports rather than errors ($rc)"
else
  err "hardening_audit kernel group exited $rc; expected 0 or 1"
fi
if grep -qE 'AppArmor|SELinux|LSM|Linux security modules' <<<"$out"; then
  ok "hardening_audit kernel group grades LSM enforcing, not only presence"
else
  err "hardening_audit kernel group did not mention AppArmor, SELinux, or LSM"
  printf '%s\n' "$out" | head -30 >&2
fi

set +e
out="$("$L/hardening_audit.sh" --only files 2>&1)"; rc=$?
set -e
assert_contains "hardening_audit has files group" "$out" "== files =="
if [[ "$rc" == "0" || "$rc" == "1" ]]; then
  ok "hardening_audit files group reports rather than errors ($rc)"
else
  err "hardening_audit files group exited $rc; expected 0 or 1"
fi
if grep -qE 'ssh_host_.*_key|no SSH host private keys' <<<"$out"; then
  ok "hardening_audit files group mentions SSH host private keys"
else
  err "hardening_audit files group did not mention SSH host keys"
  printf '%s\n' "$out" | head -30 >&2
fi

set +e
out="$("$L/hardening_audit.sh" --only updates 2>&1)"; rc=$?
set -e
assert_contains "hardening_audit has updates group" "$out" "== updates =="
if [[ "$rc" == "0" || "$rc" == "1" ]]; then
  ok "hardening_audit updates group reports rather than errors ($rc)"
else
  err "hardening_audit updates group exited $rc; expected 0 or 1"
fi
if grep -qE 'unattended-upgrades|dnf-automatic|automatic updates' <<<"$out"; then
  ok "hardening_audit updates group mentions automatic upgrades"
else
  err "hardening_audit updates group did not mention automatic upgrades"
  printf '%s\n' "$out" | head -30 >&2
fi

# --- system_doctor reports rather than grades ------------------------------
# A container has no systemd, no sshd, no firewall and no container engine, so
# this is the environment where a health report is most likely to trip over
# something absent. Exiting 0 here is the assertion: every probe has to degrade
# to a note.
scratch_home="$(mktemp -d)"
set +e
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$L/system_doctor.sh" 2>&1)"; rc=$?
set -e
assert_eq "system_doctor exits 0 with almost nothing installed" "0" "$rc"
assert_contains "system_doctor prints a summary" "$out" "== summary =="
assert_contains "system_doctor names the package manager" "$out" "package manager: $EXPECT_PKG_MGR"
assert_contains "system_doctor reports memory pressure" "$out" "== memory =="
assert_contains "system_doctor reports clock sync" "$out" "== time =="
assert_contains "system_doctor reports journal" "$out" "== journal =="
assert_contains "system_doctor reports sessions" "$out" "== sessions =="
if grep -qE 'OOM kill' <<<"$out"; then
  ok "system_doctor reports OOM kills this boot"
else
  err "system_doctor did not mention OOM kills"
fi
if grep -qE 'pending upgrade|no pending upgrades|could not count pending' <<<"$out"; then
  ok "system_doctor reports pending upgrades from the local index"
else
  err "system_doctor did not mention pending upgrades"
  printf '%s\n' "$out" | sed -n '/== packages ==/,/== disk ==/p' | head -20 >&2
fi
if grep -qE 'kernel is not tainted|kernel is tainted' <<<"$out"; then
  ok "system_doctor reports kernel taint"
else
  err "system_doctor did not mention kernel taint"
fi
if grep -qE 'coredump' <<<"$out"; then
  ok "system_doctor reports coredump files"
else
  err "system_doctor did not mention coredumps"
fi

# Read-only means it writes nothing at all, not even a log — the sibling
# maintenance scripts do write one, so this is worth asserting rather than
# assuming.
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "system_doctor wrote nothing"
else
  err "system_doctor wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home"

# --quiet must drop the healthy lines and keep the rest; a --quiet that still
# printed everything would be discovered by nobody.
out="$("$L/system_doctor.sh" --quiet 2>&1)"
if grep -q '\[ ok \]' <<<"$out"; then
  err "system_doctor --quiet still printed [ ok ] lines"
else
  ok "system_doctor --quiet drops the healthy lines"
fi
assert_contains "system_doctor --quiet still summarises" "$out" "== summary =="

for bad in "--min-free 101" "--min-free notanumber" "--min-memory 101" "--min-memory notanumber"; do
  set +e
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$L/system_doctor.sh" $bad >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "system_doctor rejects $bad -> 3" "3" "$rc"
done

# --- install_aliases.sh ---------------------------------------------------
# The whole point of this script is that a second run does not append a
# second copy, and that --dry-run writes nothing. Both are asserted against
# a scratch HOME rather than $HOME, because the mount is read-only at /repo
# and the tester's real bashrc is not ours to edit.
ALIASES="$L/install_aliases.sh"

# A managed dotfiles repository links ~/.bashrc at a file it owns. Writing with
# mktemp+mv replaced the link with a regular file, so the block was installed
# and the repository silently stopped being what bash read — every later edit
# there had no effect, and nothing said so.
alias_link_home="$(mktemp -d)"
alias_link_repo="$(mktemp -d)"
printf '# managed by a dotfiles repo\nexport OPS_TOOLBOX_TEST=1\n' > "$alias_link_repo/.bashrc"
ln -s "$alias_link_repo/.bashrc" "$alias_link_home/.bashrc"
set +e
HOME="$alias_link_home" "$ALIASES" --home "$alias_link_home" >/dev/null 2>&1; rc=$?
set -e
assert_eq "install_aliases through a symlink exits 0" "0" "$rc"
if [[ -L "$alias_link_home/.bashrc" ]]; then
  ok "install_aliases kept the ~/.bashrc symlink"
else
  err "install_aliases replaced the ~/.bashrc symlink with a regular file"
fi
if grep -q 'ops-toolbox bash_aliases' "$alias_link_repo/.bashrc"; then
  ok "install_aliases wrote through to the linked file"
else
  err "install_aliases did not write through to the linked file"
fi
if grep -q 'OPS_TOOLBOX_TEST=1' "$alias_link_repo/.bashrc"; then
  ok "install_aliases kept the linked file's own content"
else
  err "install_aliases discarded the linked file's content"
fi
rm -rf "$alias_link_home" "$alias_link_repo"

alias_home="$(mktemp -d)"
set +e
out="$(HOME="$alias_home" "$ALIASES" --dry-run --home "$alias_home" 2>&1)"; rc=$?
set -e
assert_eq "install_aliases --dry-run exits 0" "0" "$rc"
assert_contains "install_aliases dry-run names bashrc" "$out" "would create"
if [[ -e "$alias_home/.bashrc" ]]; then
  err "install_aliases --dry-run wrote .bashrc"
else
  ok "install_aliases --dry-run wrote nothing"
fi

set +e
out="$("$ALIASES" --home "$alias_home" 2>&1)"; rc=$?
set -e
assert_eq "install_aliases install exits 0" "0" "$rc"
if grep -q 'ops-toolbox bash_aliases' "$alias_home/.bashrc"; then
  ok "install_aliases wrote a marked block"
else
  err "install_aliases did not write the marked block"
fi
first_bashrc="$(cat "$alias_home/.bashrc")"
set +e
"$ALIASES" --home "$alias_home" >/dev/null 2>&1
set -e
if [[ "$first_bashrc" == "$(cat "$alias_home/.bashrc")" ]]; then
  ok "install_aliases second run is a no-op"
else
  err "install_aliases second run rewrote .bashrc"
fi

set +e
out="$("$ALIASES" --status --home "$alias_home" 2>&1)"; rc=$?
set -e
assert_eq "install_aliases --status MATCH -> 0" "0" "$rc"
assert_contains "install_aliases --status says MATCH" "$out" "MATCH"

set +e
out="$("$ALIASES" --uninstall --dry-run --home "$alias_home" 2>&1)"; rc=$?
set -e
assert_eq "install_aliases uninstall --dry-run exits 0" "0" "$rc"
if grep -q 'ops-toolbox bash_aliases' "$alias_home/.bashrc"; then
  ok "uninstall --dry-run left the block in place"
else
  err "uninstall --dry-run removed the block"
fi

set +e
"$ALIASES" --uninstall --home "$alias_home" >/dev/null 2>&1; rc=$?
set -e
assert_eq "install_aliases uninstall exits 0" "0" "$rc"
if grep -q 'ops-toolbox bash_aliases' "$alias_home/.bashrc" 2>/dev/null; then
  err "uninstall left the marked block behind"
else
  ok "uninstall removed the marked block"
fi
rm -rf "$alias_home"

# --- disk_cleanup.sh ------------------------------------------------------
CLEAN="$L/disk_cleanup.sh"
set +e
"$CLEAN" >/dev/null 2>&1; rc=$?
set -e
assert_eq "disk_cleanup without --yes -> 3" "3" "$rc"

clean_home="$(mktemp -d)"
clean_tmp="$(mktemp -d)"
# Old enough to be selected at --days 1, and new enough to be kept.
old_file="$clean_tmp/old.txt"
new_file="$clean_tmp/new.txt"
printf 'old-bytes\n' > "$old_file"
printf 'new-bytes\n' > "$new_file"
touch -d '10 days ago' "$old_file"

set +e
out="$("$CLEAN" --dry-run --days 1 --home "$clean_home" --tmp "$clean_tmp" 2>&1)"; rc=$?
set -e
assert_eq "disk_cleanup --dry-run exits 0" "0" "$rc"
assert_contains "disk_cleanup dry-run names the old file" "$out" "old.txt"
assert_contains "disk_cleanup dry-run reports no changes" "$out" "dry-run complete; no changes written"
if [[ -f "$old_file" && -f "$new_file" ]]; then
  ok "disk_cleanup --dry-run deleted nothing"
else
  err "disk_cleanup --dry-run deleted a temp file"
fi

set +e
out="$("$CLEAN" --yes --days 1 --home "$clean_home" --tmp "$clean_tmp" 2>&1)"; rc=$?
set -e
assert_eq "disk_cleanup --yes exits 0" "0" "$rc"
if [[ ! -f "$old_file" && -f "$new_file" ]]; then
  ok "disk_cleanup deleted the old file and kept the new one"
else
  err "disk_cleanup age filter misbehaved (old=$([[ -f $old_file ]] && echo present || echo gone), new=$([[ -f $new_file ]] && echo present || echo gone))"
fi
rm -rf "$clean_home" "$clean_tmp"

# Coredumps are opt-in and age-filtered, with --coredump-dir as the seam so
# the suite never touches /var/crash. Without the include flag the directory
# is left alone even when named.
core_home="$(mktemp -d)"
core_tmp="$(mktemp -d)"
core_dir="$(mktemp -d)"
old_core="$core_dir/old.core"
new_core="$core_dir/new.core"
printf 'old-core\n' > "$old_core"
printf 'new-core\n' > "$new_core"
touch -d '10 days ago' "$old_core"

set +e
"$CLEAN" --coredump-dir / --dry-run --home "$core_home" --tmp "$core_tmp" >/dev/null 2>&1; rc=$?
set -e
assert_eq "disk_cleanup --coredump-dir / -> 3" "3" "$rc"

# The literal '/' above was the only spelling this suite checked, and an exact
# string guard passed everything else through to a recursive, sudo-escalating
# delete of the whole filesystem. Each of these names root just as surely.
for core_root in '//' '/.' '/../' '/var/..' '/tmp/../'; do
  set +e
  "$CLEAN" --coredump-dir "$core_root" --include-coredumps --days 0 --dry-run \
    --home "$core_home" --tmp "$core_tmp" >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "disk_cleanup --coredump-dir $core_root -> 3" "3" "$rc"
done

# ...and the guard must not become so eager that a real directory is refused.
set +e
"$CLEAN" --coredump-dir "$core_dir" --include-coredumps --days 0 --dry-run \
  --home "$core_home" --tmp "$core_tmp" >/dev/null 2>&1; rc=$?
set -e
assert_eq "disk_cleanup --coredump-dir <real dir> -> 0" "0" "$rc"

set +e
out="$("$CLEAN" --yes --days 1 --home "$core_home" --tmp "$core_tmp" --coredump-dir "$core_dir" 2>&1)"; rc=$?
set -e
assert_eq "disk_cleanup without --include-coredumps exits 0" "0" "$rc"
if [[ -f "$old_core" && -f "$new_core" ]]; then
  ok "disk_cleanup left coredumps alone without --include-coredumps"
else
  err "disk_cleanup deleted coredumps without --include-coredumps"
fi
assert_contains "disk_cleanup names the coredump skip" "$out" "skipped: coredumps"

set +e
out="$("$CLEAN" --dry-run --days 1 --home "$core_home" --tmp "$core_tmp" --include-coredumps --coredump-dir "$core_dir" 2>&1)"; rc=$?
set -e
assert_eq "disk_cleanup --include-coredumps --dry-run exits 0" "0" "$rc"
assert_contains "disk_cleanup coredump dry-run names the old file" "$out" "old.core"
assert_contains "disk_cleanup coredump dry-run reports no changes" "$out" "dry-run complete; no changes written"
if [[ -f "$old_core" && -f "$new_core" ]]; then
  ok "disk_cleanup coredump --dry-run deleted nothing"
else
  err "disk_cleanup coredump --dry-run deleted a file"
fi

set +e
out="$("$CLEAN" --yes --days 1 --home "$core_home" --tmp "$core_tmp" --include-coredumps --coredump-dir "$core_dir" 2>&1)"; rc=$?
set -e
assert_eq "disk_cleanup --include-coredumps --yes exits 0" "0" "$rc"
if [[ ! -f "$old_core" && -f "$new_core" ]]; then
  ok "disk_cleanup deleted the old coredump and kept the new one"
else
  err "disk_cleanup coredump age filter misbehaved (old=$([[ -f $old_core ]] && echo present || echo gone), new=$([[ -f $new_core ]] && echo present || echo gone))"
fi
rm -rf "$core_home" "$core_tmp" "$core_dir"

# --- net_doctor.sh --------------------------------------------------------
NET="$L/net_doctor.sh"
scratch_home="$(mktemp -d)"
set +e
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$NET" 2>&1)"; rc=$?
set -e
assert_eq "net_doctor exits 0 with almost nothing installed" "0" "$rc"
assert_contains "net_doctor prints a summary" "$out" "== summary =="
assert_contains "net_doctor has a routes section" "$out" "== routes =="
assert_contains "net_doctor has a dns section" "$out" "== dns =="
if grep -qE 'hostname .* resolves|hostname .* does not resolve' <<<"$out"; then
  ok "net_doctor reports whether the local hostname resolves"
else
  err "net_doctor did not mention hostname resolution"
fi
if command -v ip >/dev/null 2>&1; then
  if grep -qE 'default6:|no default IPv6 route' <<<"$out"; then
    ok "net_doctor reports IPv6 routing"
  else
    err "net_doctor did not mention IPv6 routing"
  fi
else
  ok "net_doctor IPv6 check skipped (no ip)"
fi
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "net_doctor wrote nothing"
else
  err "net_doctor wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home"

out="$("$NET" --quiet 2>&1)"
if grep -q '\[ ok \]' <<<"$out"; then
  err "net_doctor --quiet still printed [ ok ] lines"
else
  ok "net_doctor --quiet drops the healthy lines"
fi
assert_contains "net_doctor --quiet still summarises" "$out" "== summary =="

# --- schedule_report.sh ---------------------------------------------------
SCHED="$L/schedule_report.sh"
scratch_home="$(mktemp -d)"
set +e
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$SCHED" 2>&1)"; rc=$?
set -e
assert_eq "schedule_report exits 0 with almost nothing installed" "0" "$rc"
assert_contains "schedule_report prints a summary" "$out" "== summary =="
assert_contains "schedule_report has a crontab section" "$out" "== crontab =="
if grep -qE 'linger|lingering' <<<"$out"; then
  ok "schedule_report reports lingering for user timers"
else
  ok "schedule_report lingering skipped (no logind)"
fi
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "schedule_report wrote nothing"
else
  err "schedule_report wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home"

out="$("$SCHED" --quiet 2>&1)"
if grep -q '\[ ok \]' <<<"$out"; then
  err "schedule_report --quiet still printed [ ok ] lines"
else
  ok "schedule_report --quiet drops the healthy lines"
fi
assert_contains "schedule_report --quiet still summarises" "$out" "== summary =="

# --- sysctl_defaults.sh ---------------------------------------------------
SYSCTL="$L/sysctl_defaults.sh"
set +e
out="$("$SYSCTL" --list-groups 2>&1)"; rc=$?
set -e
assert_eq "sysctl_defaults --list-groups exits 0" "0" "$rc"
assert_contains "sysctl_defaults lists inotify" "$out" "inotify"
assert_contains "sysctl_defaults lists vm" "$out" "vm"

set +e
out="$("$SYSCTL" --only nosuchgroup 2>&1)"; rc=$?
set -e
assert_eq "sysctl_defaults rejects an unknown group -> 3" "3" "$rc"

# Apply is tested against a fake procfs and sysctl.d, so a container that
# cannot change the real kernel still proves the drop-in is written, the
# backup captures the previous value, and --dry-run writes neither.
sysctl_root="$(mktemp -d)"
mkdir -p "$sysctl_root/proc/fs/inotify" "$sysctl_root/proc/vm" "$sysctl_root/sysctl.d" "$sysctl_root/tmp"
printf '8192\n' > "$sysctl_root/proc/fs/inotify/max_user_watches"
printf '128\n' > "$sysctl_root/proc/fs/inotify/max_user_instances"
printf '16384\n' > "$sysctl_root/proc/fs/inotify/max_queued_events"
printf '60\n' > "$sysctl_root/proc/vm/swappiness"

set +e
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --only inotify 2>&1
)"; rc=$?
set -e
assert_eq "sysctl_defaults report exits 0" "0" "$rc"
assert_contains "sysctl_defaults reports the current watch count" "$out" "8192"
assert_contains "sysctl_defaults names the desired watch count" "$out" "524288"

set +e
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --apply --dry-run --only inotify --backup-file "$sysctl_root/tmp/backup.txt" 2>&1
)"; rc=$?
set -e
assert_eq "sysctl_defaults --apply --dry-run exits 0" "0" "$rc"
assert_contains "sysctl_defaults dry-run names the drop-in" "$out" "99-ops-toolbox.conf"
if [[ -e "$sysctl_root/sysctl.d/99-ops-toolbox.conf" || -e "$sysctl_root/tmp/backup.txt" ]]; then
  err "sysctl_defaults --dry-run wrote a drop-in or backup"
else
  ok "sysctl_defaults --apply --dry-run wrote nothing"
fi

set +e
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --apply --only inotify --backup-file "$sysctl_root/tmp/backup.txt" 2>&1
)"; rc=$?
set -e
assert_eq "sysctl_defaults --apply exits 0 against a fake procfs" "0" "$rc"
if [[ -f "$sysctl_root/sysctl.d/99-ops-toolbox.conf" ]]; then
  ok "sysctl_defaults wrote the drop-in"
else
  err "sysctl_defaults did not write the drop-in"
fi
assert_contains "sysctl_defaults drop-in sets max_user_watches" \
  "$(cat "$sysctl_root/sysctl.d/99-ops-toolbox.conf")" \
  "fs.inotify.max_user_watches = 524288"
if grep -q 'fs.inotify.max_user_watches=8192' "$sysctl_root/tmp/backup.txt"; then
  ok "sysctl_defaults backup captured the previous value"
else
  err "sysctl_defaults backup missed the previous value"
fi
if [[ "$(cat "$sysctl_root/proc/fs/inotify/max_user_watches")" == "524288" ]]; then
  ok "sysctl_defaults applied the live inotify value"
else
  err "sysctl_defaults did not apply the live inotify value"
fi

set +e
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert --revert-from "$sysctl_root/tmp/backup.txt" 2>&1
)"; rc=$?
set -e
assert_eq "sysctl_defaults --revert exits 0" "0" "$rc"
if [[ ! -e "$sysctl_root/sysctl.d/99-ops-toolbox.conf" ]]; then
  ok "sysctl_defaults --revert removed the drop-in"
else
  err "sysctl_defaults --revert left the drop-in"
fi
if [[ "$(cat "$sysctl_root/proc/fs/inotify/max_user_watches")" == "8192" ]]; then
  ok "sysctl_defaults --revert restored the previous value"
else
  err "sysctl_defaults --revert did not restore max_user_watches"
fi

# --revert used to feed every key in the backup straight to write_live, and
# picked its backup by globbing a world-writable TMPDIR. Between them, any
# local user could leave a file for root to find and set a sysctl of their
# choosing — kernel.core_pattern to a command, for instance.
planted="$sysctl_root/tmp/sysctl_defaults-backup-99999999-999999.txt"
printf 'kernel.core_pattern=|/tmp/owned.sh\n' > "$planted"
chmod 666 "$planted"
set +e
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert 2>&1
)"; rc=$?
set -e
assert_eq "sysctl_defaults --revert ignores a world-writable backup" "3" "$rc"

# Even from a file the caller owns, a key outside the managed table is data,
# not an instruction.
chmod 600 "$planted"
set +e
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert --revert-from "$planted" 2>&1
)"; rc=$?
set -e
assert_contains "sysctl_defaults --revert skips an unmanaged key" \
  "$out" "not a key this script manages"

# PROC_SYS exists so the suite can drive apply/revert without retuning the host.
# write_live used to fall back to sysctl(8) whenever the fixture file was not
# writable, which addresses the real kernel and walks straight out of the sandbox.
rm -f "$sysctl_root/proc/fs/inotify/max_user_watches"
printf 'fs.inotify.max_user_watches=8192\n' > "$sysctl_root/tmp/sandbox.txt"
chmod 600 "$sysctl_root/tmp/sandbox.txt"
set +e
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert --revert-from "$sysctl_root/tmp/sandbox.txt" 2>&1
)"; rc=$?
set -e
assert_contains "sysctl_defaults refuses sysctl(8) under a PROC_SYS override" \
  "$out" "refusing 'sysctl -w"

rm -rf "$sysctl_root"

# --- tls_expiry.sh --------------------------------------------------------
TLS="$L/tls_expiry.sh"
set +e
"$TLS" >/dev/null 2>&1; rc=$?
set -e
assert_eq "tls_expiry without --file or --host -> 3" "3" "$rc"

set +e
"$TLS" --days notanumber --file /dev/null >/dev/null 2>&1; rc=$?
set -e
assert_eq "tls_expiry rejects --days notanumber -> 3" "3" "$rc"

set +e
"$TLS" --fail-on nope --file /dev/null >/dev/null 2>&1; rc=$?
set -e
assert_eq "tls_expiry rejects --fail-on nope -> 3" "3" "$rc"

set +e
"$TLS" --file --days 7 >/dev/null 2>&1; rc=$?
set -e
assert_eq "tls_expiry --file rejects the next flag as a path -> 3" "3" "$rc"

# openssl is not in the tester image on purpose (see tester/Dockerfile): a
# missing binary must be exit 2, not a crash, and --help already ran above.
if ! command -v openssl >/dev/null 2>&1; then
  set +e
  PATH="/usr/bin:/bin" "$TLS" --file /dev/null >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "tls_expiry without openssl -> 2" "2" "$rc"
  ok "tls_expiry PEM checks skipped (openssl not installed)"
else
  expired="$L/tests/fixtures/expired.pem"
  set +e
  out="$("$TLS" --file "$expired" 2>&1)"; rc=$?
  set -e
  assert_eq "tls_expiry expired fixture -> 1" "1" "$rc"
  assert_contains "tls_expiry names the expired leaf" "$out" "expired"
  assert_contains "tls_expiry prints a summary" "$out" "== summary =="

  set +e
  out="$("$TLS" --file "$expired" --fail-on never 2>&1)"; rc=$?
  set -e
  assert_eq "tls_expiry --fail-on never stays 0" "0" "$rc"

  soon="$(mktemp --suffix=.pem)"
  soon_key="$(mktemp)"
  openssl req -x509 -newkey rsa:2048 -keyout "$soon_key" -out "$soon" -days 7 -nodes -subj "/CN=soon.test" >/dev/null 2>&1
  rm -f "$soon_key"
  set +e
  out="$("$TLS" --file "$soon" --days 30 --fail-on expired 2>&1)"; rc=$?
  set -e
  assert_eq "tls_expiry soon-to-expire is warn not fail" "0" "$rc"
  assert_contains "tls_expiry warns inside the window" "$out" "[warn]"
  set +e
  "$TLS" --file "$soon" --days 30 --fail-on warn >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "tls_expiry --fail-on warn exits 1 inside the window" "1" "$rc"

  valid="$(mktemp --suffix=.pem)"
  valid_key="$(mktemp)"
  openssl req -x509 -newkey rsa:2048 -keyout "$valid_key" -out "$valid" -days 3650 -nodes -subj "/CN=valid.test" >/dev/null 2>&1
  rm -f "$valid_key"
  set +e
  out="$("$TLS" --file "$valid" --days 30 2>&1)"; rc=$?
  set -e
  assert_eq "tls_expiry long-lived cert exits 0" "0" "$rc"
  assert_contains "tls_expiry passes a long-lived cert" "$out" "[pass]"

  globdir="$(mktemp -d)"
  cp "$expired" "$globdir/a.pem"
  cp "$expired" "$globdir/b.pem"
  set +e
  out="$("$TLS" --file "$globdir/*.pem" --fail-on never 2>&1)"; rc=$?
  set -e
  assert_eq "tls_expiry quoted glob exits 0 with --fail-on never" "0" "$rc"
  assert_contains "tls_expiry glob expands a.pem" "$out" "a.pem"
  assert_contains "tls_expiry glob expands b.pem" "$out" "b.pem"
  rm -rf "$globdir"

  scratch_home="$(mktemp -d)"
  set +e
  HOME="$scratch_home" TMPDIR="$scratch_home" "$TLS" --file "$valid" >/dev/null 2>&1
  set -e
  if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
    ok "tls_expiry wrote nothing"
  else
    err "tls_expiry wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
  fi
  rm -rf "$scratch_home" "$soon" "$valid"
fi

# --- config_backup.sh -----------------------------------------------------
BACKUP="$L/config_backup.sh"
set +e
"$BACKUP" >/dev/null 2>&1; rc=$?
set -e
assert_eq "config_backup without --yes -> 3" "3" "$rc"

set +e
"$BACKUP" --yes --paths / >/dev/null 2>&1; rc=$?
set -e
assert_eq "config_backup refuses to archive / -> 3" "3" "$rc"

# As with disk_cleanup, the literal '/' was the only spelling checked here, and
# every one of these reaches the same directory — with tar pointed at --dest.
for backup_root in '//' '/.' '/../' '/etc/..'; do
  set +e
  "$BACKUP" --yes --paths "$backup_root" --dest /tmp >/dev/null 2>&1; rc=$?
  set -e
  assert_eq "config_backup refuses --paths $backup_root -> 3" "3" "$rc"
done

set +e
"$BACKUP" --yes --paths relative/path --dest /tmp >/dev/null 2>&1; rc=$?
set -e
assert_eq "config_backup rejects a relative path -> 3" "3" "$rc"

src="$(mktemp -d)"
dest="$(mktemp -d)"
printf 'keep-me\n' > "$src/payload.txt"
mkdir -p "$src/nested"
printf 'also\n' > "$src/nested/file.txt"

set +e
out="$("$BACKUP" --dry-run --paths "$src" --dest "$dest" 2>&1)"; rc=$?
set -e
assert_eq "config_backup --dry-run exits 0" "0" "$rc"
assert_contains "config_backup dry-run names the archive" "$out" "would write"
assert_contains "config_backup dry-run reports no changes" "$out" "dry-run complete; no changes written"
if [[ -z "$(ls -A "$dest" 2>/dev/null)" ]]; then
  ok "config_backup --dry-run wrote nothing"
else
  err "config_backup --dry-run wrote into dest: $(ls -A "$dest" | tr '\n' ' ')"
fi

set +e
out="$("$BACKUP" --yes --paths "$src" --dest "$dest" --keep 2 2>&1)"; rc=$?
set -e
assert_eq "config_backup --yes exits 0" "0" "$rc"
archive="$(ls -1 "$dest"/config-*.tar.gz 2>/dev/null | head -n 1)"
if [[ -n "$archive" && -s "$archive" ]]; then
  ok "config_backup wrote an archive"
else
  err "config_backup did not write an archive"
  archive=""
fi
if [[ -n "$archive" ]] && tar -tzf "$archive" | grep -q 'payload.txt'; then
  ok "config_backup archive contains the payload"
else
  err "config_backup archive missed the payload"
fi

set +e
out="$("$BACKUP" --list --dest "$dest" 2>&1)"; rc=$?
set -e
assert_eq "config_backup --list exits 0" "0" "$rc"
assert_contains "config_backup --list shows the payload" "$out" "payload.txt"

empty_dest="$(mktemp -d)"
set +e
"$BACKUP" --list --dest "$empty_dest" >/dev/null 2>&1; rc=$?
set -e
assert_eq "config_backup --list with no archives -> 3" "3" "$rc"
rmdir "$empty_dest"

# Second write, then a third with --keep 1, must leave a single archive.
sleep 1
"$BACKUP" --yes --paths "$src" --dest "$dest" --keep 2 >/dev/null 2>&1
sleep 1
"$BACKUP" --yes --paths "$src" --dest "$dest" --keep 1 >/dev/null 2>&1
left="$(ls -1 "$dest"/config-*.tar.gz 2>/dev/null | grep -c . || true)"
assert_eq "config_backup --keep 1 retains one archive" "1" "$left"
rm -rf "$src" "$dest"

# --- ssh_client_doctor.sh -------------------------------------------------
SSHDOC="$L/ssh_client_doctor.sh"
missing_dir="$(mktemp -d)"
rmdir "$missing_dir"
set +e
out="$("$SSHDOC" --ssh-dir "$missing_dir" 2>&1)"; rc=$?
set -e
assert_eq "ssh_client_doctor missing dir exits 0" "0" "$rc"
assert_contains "ssh_client_doctor skips a missing dir" "$out" "does not exist"

good="$(mktemp -d)"
mkdir -p "$good"
chmod 700 "$good"
# A throwaway key used only as a mode fixture; never a real identity.
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'not-a-real-key' '-----END OPENSSH PRIVATE KEY-----' > "$good/id_ed25519"
chmod 600 "$good/id_ed25519"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest fixture\n' > "$good/id_ed25519.pub"
chmod 644 "$good/id_ed25519.pub"
printf 'IdentityFile id_ed25519\nIdentityFile missing-key\n' > "$good/config"
chmod 600 "$good/config"

set +e
out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
set -e
assert_eq "ssh_client_doctor clean dir with missing IdentityFile -> 0 (warn only)" "0" "$rc"
assert_contains "ssh_client_doctor passes 700 on the directory" "$out" "mode 700"

# The only config fixture above is 600, which passed under both the old
# enumeration (group/other in 0|4) and the write-bit rule that replaced it — so
# neither spelling of the check was actually covered. OpenSSH objects to these
# files being writable by group or other, not readable: 755 grants no write and
# must pass, 660 does and must not.
chmod 755 "$good/config"
set +e
out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
set -e
assert_eq "ssh_client_doctor accepts config mode 755 (no group/other write)" "0" "$rc"
assert_contains "ssh_client_doctor names the accepted mode" "$out" "config mode 755"

chmod 660 "$good/config"
set +e
out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
set -e
assert_eq "ssh_client_doctor rejects config mode 660 (group write) -> 1" "1" "$rc"
chmod 600 "$good/config"
assert_contains "ssh_client_doctor warns on a missing IdentityFile" "$out" "missing-key"

set +e
"$SSHDOC" --ssh-dir "$good" --fail-on warn >/dev/null 2>&1; rc=$?
set -e
assert_eq "ssh_client_doctor --fail-on warn exits 1 for missing IdentityFile" "1" "$rc"

chmod 644 "$good/id_ed25519"
set +e
out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
set -e
assert_eq "ssh_client_doctor world-readable private key -> 1" "1" "$rc"
assert_contains "ssh_client_doctor fails a 644 private key" "$out" "id_ed25519 mode 644"

scratch_home="$(mktemp -d)"
set +e
HOME="$scratch_home" TMPDIR="$scratch_home" "$SSHDOC" --ssh-dir "$good" >/dev/null 2>&1
set -e
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "ssh_client_doctor wrote nothing"
else
  err "ssh_client_doctor wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home" "$good"

echo
if (( failures > 0 )); then
  echo "$failures linux script check(s) failed" >&2
  exit 1
fi
echo "=== all linux script checks passed ($EXPECT_PKG_MGR) ==="
exit 0

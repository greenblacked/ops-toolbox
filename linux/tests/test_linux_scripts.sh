#!/usr/bin/env bash
# Run from a Linux tester container; repo root is mounted read-only at /repo.
#
# Unlike the macOS suite, which can only parse the scripts it tests, these run
# for real: the container *is* the target OS. That is the whole reason this
# suite is worth having.
#
# The mount is read-only, so anything that writes must be pointed at /tmp. A
# test that quietly wrote into /repo would pass here and fail in CI.
#
# No `-e`. A suite that aborts on the first non-zero exit reports the shell's
# status and discards the output it had just captured, so the real error is
# invisible: a Bash 3.2 parse error in stay_fresh_agent.sh surfaced only as
# "exit code 2" with no message. Every failure below is a named assertion,
# which is the same dialect test_stay_fresh_steps.sh already uses.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-/repo}"
L="$REPO_ROOT/linux"
EXPECT_PKG_MGR="${EXPECT_PKG_MGR:-apt}"

if [[ ! -d "$L" ]]; then
  echo "expected linux/ at $L" >&2
  exit 1
fi

# Every fixture below starts from `mktemp -d`. Without `-e` a failed mktemp
# leaves the variable empty and the paths built from it absolute, so prove
# once that scratch space works instead of guarding forty call sites.
tmp_probe="$(mktemp -d 2>/dev/null)"
if [[ -z "$tmp_probe" || ! -d "$tmp_probe" ]]; then
  echo "cannot create scratch directories under ${TMPDIR:-/tmp}" >&2
  exit 1
fi
rmdir "$tmp_probe"

# These name a file or directory outside the fixtures, and the scripts under
# test read them straight from the environment. XDG_CACHE_HOME is the one that
# bites: disk_cleanup.sh deleted its thumbnails even when --home pointed the run
# at a scratch profile, so running this suite on a desktop Linux box emptied the
# developer's real cache. Every test that needs one of these supplies it itself.
unset OS_RELEASE RESOLV_CONF XDG_CACHE_HOME XDG_CONFIG_HOME AUTH_LOG DOCKER_DAEMON_JSON
unset PROC_DIR FSTAB SYS_CLASS_NET PROC_NET_BONDING
# ssh_client_doctor.sh asks the agent SSH_AUTH_SOCK names; a developer's live
# agent must not answer for the fixtures.
unset SSH_AUTH_SOCK
# SYSTEMD_ANALYZE_CMD names a binary stay_fresh_timer.sh executes to verify the
# units it writes. Exported, it aims that execution at whatever the host says,
# which is the worst of this class: not a path the run reads, a command the run
# runs. It stayed invisible because the scanner counted its own
# SYSTEMD_ANALYZE_CMD="${SYSTEMD_ANALYZE_CMD:-systemd-analyze}" as a local
# assignment - see host_env_vars.awk.
unset SYSTEMD_ANALYZE_CMD

failures=0
# Counted so the run can prove it asserted something. Without `-e` a suite that
# dies early exits 0 with a short log, and nothing says so; the floor does.
checks=0
section_checks=0
sections=0
section_name=""
ok()  { checks=$((checks + 1)); section_checks=$((section_checks + 1)); echo "[ ok ] $*"; }
err() { checks=$((checks + 1)); section_checks=$((section_checks + 1)); echo "[fail] $*" >&2; failures=$((failures + 1)); }

# The floor, per section rather than per file. Without `-e` the shape of a
# silent failure changes: a section whose loop ran over nothing, or whose
# fixture never got as far as an assertion, exits 0 with a shorter log and
# nothing says so. Each `section` call closes the previous one and fails it if
# it asserted nothing, and the end of the file closes the last. A count floor
# for the whole file would need a number that goes stale every time a test is
# added or retired; a section either asserted or it did not.
section() {
  end_section
  section_name="$1"
  section_checks=0
  sections=$((sections + 1))
}
end_section() {
  [[ -n "$section_name" ]] || return 0
  if (( section_checks == 0 )); then
    err "section '$section_name' made no assertion — its loop ran over nothing or its fixture never reached one"
  fi
  section_name=""
  section_checks=0
}

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

section "syntax"
for f in "${scripts[@]}" "$L/bash_aliases.sh"; do
  # "${BASH:-bash}", not "bash": a bare `bash` resolves through PATH rather
  # than naming the shell running this file. See the same note in
  # git/tests/test_git_scripts.sh — linux/ is a Bash 3.2 package too.
  if "${BASH:-bash}" -n "$f"; then ok "bash -n ${f#"$REPO_ROOT/"}"; else err "bash -n ${f#"$REPO_ROOT/"}"; fi
done

section "help contract, before any preflight"
for f in "${scripts[@]}"; do
  if "$f" --help >/dev/null 2>&1; then ok "${f##*/} --help"; else err "${f##*/} --help"; fi
done

section "unknown flag -> 3"
for f in "${scripts[@]}"; do
  "$f" --definitely-not-a-valid-flag-12345 >/dev/null 2>&1
  rc=$?
  assert_eq "${f##*/} unknown flag -> 3" "3" "$rc"
done

section "distro detection picks the right package manager"
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

section "an unsupported distro exits 2"
# The whole reason detect_pkg_mgr reads $OS_RELEASE instead of /etc/os-release
# directly: without the seam this path is untestable, since a container cannot
# pretend to be Gentoo.
fake="/tmp/fake-os-release"
printf 'ID=gentoo\nID_LIKE=gentoo\n' > "$fake"
OS_RELEASE="$fake" "$L/stay_fresh.sh" --dry-run >/dev/null 2>&1
rc=$?
assert_eq "unsupported distro -> 2" "2" "$rc"

# Counting installed packages before and after is the assertion that actually
# matters: the dry-run promise is the core of this repository. The helper is
# defined here; the section that uses it opens below the Kali contracts, which
# were inserted between the two — under the old comment heading that looked
# like one section and was two.
count_packages() {
  case "$EXPECT_PKG_MGR" in
    apt)    dpkg-query -f '.\n' -W 2>/dev/null | wc -l ;;
    dnf)    rpm -qa 2>/dev/null | wc -l ;;
    pacman) pacman -Qq 2>/dev/null | wc -l ;;
  esac
}

section "Kali cloud-init contracts"
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
"$KALI_STATUS" --definitely-not-valid >/dev/null 2>&1
rc=$?
assert_eq "embedded kali-lab-status unknown flag -> 3" "3" "$rc"

section "dry run changes nothing"
before="$(count_packages)"
# Guarded because the assertion below cannot see the difference: a dry run that
# died on line one also installed nothing, so an unguarded failure here reads as
# a pass. The same applies at every `>/dev/null` invocation whose result is
# judged by what the filesystem looks like afterwards.
"$L/stay_fresh.sh" --dry-run >/dev/null 2>&1 || err "stay_fresh --dry-run exited $? before the package count was taken"
"$L/install_devtools.sh" --dry-run >/dev/null 2>&1 || err "install_devtools --dry-run exited $? before the package count was taken"
after="$(count_packages)"
assert_eq "dry runs installed nothing" "$before" "$after"

section "dry run says so, and says nothing was written"
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

assert_contains "stay_fresh --only names every skipped step" "$out" "skipped: flatpak"
assert_contains "stay_fresh --only names snap among them too" "$out" "skipped: snap"

"$L/stay_fresh.sh" --dry-run --only caches --skip-snap >/dev/null 2>&1
rc=$?
assert_eq "stay_fresh rejects mixed scoping styles -> 3" "3" "$rc"

section "HOME builds every path stay_fresh removes"
# Empty rather than unset is the dangerous one: set -u does not fire, and
# "$HOME/.cache/pip" becomes "/.cache/pip", so the rm -rf addresses the root
# filesystem. The flags that need no home directory still answer.
env -u HOME "$L/stay_fresh.sh" --help >/dev/null 2>&1; rc=$?
assert_eq "stay_fresh --help works with HOME unset" "0" "$rc"
env -u HOME "$L/stay_fresh.sh" --list-steps >/dev/null 2>&1; rc=$?
assert_eq "stay_fresh --list-steps works with HOME unset" "0" "$rc"
for home_case in unset empty; do
  if [[ "$home_case" == unset ]]; then
    out="$(env -u HOME "$L/stay_fresh.sh" --dry-run --only caches 2>&1)"; rc=$?
  else
    out="$(HOME="" "$L/stay_fresh.sh" --dry-run --only caches 2>&1)"; rc=$?
  fi
  assert_eq "stay_fresh with HOME $home_case is refused -> 2" "2" "$rc"
  assert_contains "stay_fresh with HOME $home_case says why" "$out" "HOME is not set"
  assert_not_contains "stay_fresh with HOME $home_case names no root path" "$out" "/.cache/pip"
done
out="$(HOME="$L/stay_fresh.sh" "$L/stay_fresh.sh" --dry-run --only caches 2>&1)"; rc=$?
assert_eq "stay_fresh with a HOME that is a file is refused -> 2" "2" "$rc"
assert_contains "a non-directory HOME is named" "$out" "HOME is not a directory"

section "the Trash is emptied whole, or the desktop shows phantom entries"
sf_home="$(mktemp -d)"
mkdir -p "$sf_home/.local/share/Trash/files" "$sf_home/.local/share/Trash/info"
: > "$sf_home/.local/share/Trash/files/doc.txt"
: > "$sf_home/.local/share/Trash/info/doc.txt.trashinfo"
out="$(HOME="$sf_home" TMPDIR="$sf_home" "$L/stay_fresh.sh" --dry-run --only caches 2>&1)"
assert_contains "stay_fresh empties the trashed files" "$out" "Trash/files"
assert_contains "stay_fresh empties their .trashinfo records too" "$out" "Trash/info"

# A real run must empty the two directories and leave them behind: the
# FreeDesktop spec expects both to exist, and `rm -rf` on the directory
# itself removed them.
sf_home="$(mktemp -d)"
mkdir -p "$sf_home/.local/share/Trash/files/sub" "$sf_home/.local/share/Trash/info"
: > "$sf_home/.local/share/Trash/files/doc.txt"
: > "$sf_home/.local/share/Trash/files/sub/deep.txt"
: > "$sf_home/.local/share/Trash/info/doc.txt.trashinfo"
HOME="$sf_home" TMPDIR="$sf_home" "$L/stay_fresh.sh" --yes --only caches >/dev/null 2>&1
assert_eq "the Trash files/ directory itself survives" "yes" \
  "$([[ -d "$sf_home/.local/share/Trash/files" ]] && echo yes || echo no)"
assert_eq "the Trash info/ directory itself survives" "yes" \
  "$([[ -d "$sf_home/.local/share/Trash/info" ]] && echo yes || echo no)"
assert_eq "the trashed files are gone" "" \
  "$(ls -A "$sf_home/.local/share/Trash/files" 2>/dev/null)"
assert_eq "the .trashinfo records are gone" "" \
  "$(ls -A "$sf_home/.local/share/Trash/info" 2>/dev/null)"
rm -rf "$sf_home"

# A Trash relocated to another disk - files/ a symlink, the usual way to keep
# it off a small SSD. `[[ -d ]]` follows the link, so `rm -rf "$trash"` deleted
# the link: the trashed files stayed where they were, nothing was freed, the
# relocation was destroyed, and the run still printed "empty".
sf_home="$(mktemp -d)"
other_disk="$(mktemp -d)"
mkdir -p "$sf_home/.local/share/Trash" "$other_disk/files"
: > "$other_disk/files/big.iso"
ln -s "$other_disk/files" "$sf_home/.local/share/Trash/files"
mkdir -p "$sf_home/.local/share/Trash/info"
: > "$sf_home/.local/share/Trash/info/big.iso.trashinfo"
HOME="$sf_home" TMPDIR="$sf_home" "$L/stay_fresh.sh" --yes --only caches >/dev/null 2>&1
assert_eq "a relocated Trash keeps its symlink" "yes" \
  "$([[ -L "$sf_home/.local/share/Trash/files" ]] && echo yes || echo no)"
assert_eq "a relocated Trash is actually emptied" "" \
  "$(ls -A "$other_disk/files" 2>/dev/null)"
rm -rf "$sf_home" "$other_disk"
sf_home="$(mktemp -d)"

section "a clean run leaves no log behind"
# One file per run accumulated in TMPDIR forever, never read and never removed.
# This invocation is why the file no longer runs under `-e`: when it did, an
# unbracketed nonzero exit killed the suite here, before rc was assigned -
# which made the assertion below unfailable and took the ~40 assertions after
# it with it, leaving CI a bare exit 1 and no failing-test line.
out="$(HOME="$sf_home" TMPDIR="$sf_home" "$L/stay_fresh.sh" --only caches 2>&1)"
rc=$?
assert_eq "stay_fresh clean run succeeds" "0" "$rc"
if [[ -z "$(find "$sf_home" -maxdepth 1 -name 'linux_stay_fresh-*.log' -print -quit)" ]]; then
  ok "stay_fresh discards a clean run's log"
else
  err "stay_fresh left a log behind after a clean run"
fi
rm -rf "$sf_home"

section "installing without --yes refuses rather than proceeding"
"$L/install_devtools.sh" >/dev/null 2>&1
rc=$?
assert_eq "install_devtools without --yes -> 3" "3" "$rc"

section "packages.sh round-trips through a real package database"
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
"$L/packages.sh" dump --file "$dump" --force >/dev/null 2>&1 || err "packages.sh dump --force exited $? — the stability check below would compare the first dump with itself"
if diff -q <(grep -vE '^\s*#' /tmp/first.txt) <(grep -vE '^\s*#' "$dump") >/dev/null; then
  ok "dump is stable across runs"
else
  err "dump is not stable across runs"
fi

# everything just dumped is by definition installed
"$L/packages.sh" check --file "$dump" >/dev/null 2>&1
rc=$?
assert_eq "check passes against a fresh dump" "0" "$rc"

# a package that cannot exist must make check fail with 1, not crash
printf 'definitely-not-a-real-package-12345\n' >> "$dump"
"$L/packages.sh" check --file "$dump" >/dev/null 2>&1
rc=$?
assert_eq "check reports a missing package as 1" "1" "$rc"

out="$("$L/packages.sh" install --file "$dump" --dry-run 2>&1)"
rc=$?
assert_eq "install --dry-run exits 0" "0" "$rc"
assert_contains "install --dry-run names the missing package" "$out" "definitely-not-a-real-package-12345"
assert_contains "install --dry-run reports no changes" "$out" "dry-run complete; no changes written"
assert_contains "install --dry-run uses the linux indented form" "$out" "(dry-run)"
assert_not_contains "install --dry-run does not mix git grammar" "$out" "dry-run: would run:"

# dump --dry-run must preview against a path that does not exist yet.
# dump refuses an existing --file when FORCE==0 before it consults DRY_RUN,
# so pointing at the already-written $dump would exit 1 without --force —
# leave that semantics alone and use a fresh absent path instead.
dump_preview="$(mktemp /tmp/packages-dump-dry-run.XXXXXX)"
rm -f "$dump_preview"
out="$("$L/packages.sh" dump --file "$dump_preview" --dry-run 2>&1)"
rc=$?
assert_eq "dump --dry-run exits 0" "0" "$rc"
assert_contains "dump --dry-run reports no changes" "$out" "dry-run complete; no changes written"
if [[ -e "$dump_preview" ]]; then
  err "dump --dry-run created $dump_preview"
else
  ok "dump --dry-run left the path absent"
fi

"$L/packages.sh" dump --file --force >/dev/null 2>&1
rc=$?
assert_eq "packages.sh --file rejects the next flag as a path -> 3" "3" "$rc"

section "aliases are sourceable, and guarded"
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
bash "$L/bash_aliases.sh" >/dev/null 2>&1
rc=$?
assert_eq "bash_aliases.sh executed directly -> 3" "3" "$rc"

out="$(bash -c ". '$L/bash_aliases.sh'; alias stay-fresh; alias net-doctor; alias disk-cleanup; alias linux-status; toolbox-help" 2>&1)"
assert_contains "bash_aliases aliases stay-fresh to this checkout" "$out" "stay_fresh.sh"
assert_contains "bash_aliases aliases net-doctor to this checkout" "$out" "net_doctor.sh"
assert_contains "bash_aliases aliases disk-cleanup to this checkout" "$out" "disk_cleanup.sh"
assert_contains "bash_aliases aliases linux-status to this checkout" "$out" "status.sh"
assert_contains "toolbox-help lists stay-fresh" "$out" "stay-fresh"
assert_contains "toolbox-help lists linux-status" "$out" "linux-status"
assert_contains "toolbox-help lists schedule-report" "$out" "schedule-report"
assert_contains "toolbox-help lists tls-expiry" "$out" "tls-expiry"
assert_contains "toolbox-help lists config-backup" "$out" "config-backup"
assert_contains "toolbox-help lists ssh-client-doctor" "$out" "ssh-client-doctor"

section "stay_fresh degrades rather than failing when a tool is absent"
# journald is not present in these containers. That must be a note, not a
# failure: the warn vs failure split is the documented contract.
out="$("$L/stay_fresh.sh" --yes --no-sudo --skip-packages --skip-containers 2>&1)"
rc=$?
assert_eq "stay_fresh survives missing optional tools" "0" "$rc"
assert_contains "stay_fresh reports the run finished" "$out" "done"

section "the systemd timer builds its units without a running systemd"
# --print-only is the seam that makes this testable at all: a container has no
# user manager, so install can never get past preflight here. Where
# systemd-analyze exists (fedora, arch) the script verifies the units before
# printing them, so a zero exit below is a real validation, not just a render.
TIMER="$L/systemd/stay_fresh_timer.sh"
out="$("$TIMER" install --print-only 2>&1)"; rc=$?
assert_eq "timer --print-only exits 0" "0" "$rc"
assert_contains "timer defaults to Monday 10:30" "$out" "OnCalendar=Mon *-*-* 10:30:00"
assert_contains "timer runs stay_fresh.sh" "$out" "$L/stay_fresh.sh\" --yes --no-sudo"
assert_contains "timer installs a [Timer] section" "$out" "[Timer]"

out="$("$TIMER" install --print-only --weekday daily --hour 3 --minute 5 --dry-run 2>&1)"
assert_contains "timer honours daily and the clock" "$out" "OnCalendar=*-*-* 03:05:00"
# --dry-run previews the install; it never reaches the unit. It used to be
# appended to ExecStart, describing a timer that would preview maintenance
# every week and never do any - and dead even then, because the preview below
# returns before a unit is written, so nothing ever carried it.
assert_contains "timer ExecStart runs a real maintenance pass" "$out" "--yes --no-sudo"
assert_not_contains "timer never installs a unit that only previews" "$out" "--yes --no-sudo --dry-run"

out="$("$TIMER" --help 2>&1)"
assert_contains "timer exposes read-only log inspection" "$out" "logs [--lines N]"

# --print-only must write nothing, the same promise --dry-run makes elsewhere.
scratch_home="$(mktemp -d)"
HOME="$scratch_home" XDG_CONFIG_HOME="$scratch_home/.config" \
  "$TIMER" install --print-only >/dev/null 2>&1 || err "timer install --print-only exited $? — a run that never started also writes nothing"
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
HOME="$scratch_home" XDG_CONFIG_HOME="$scratch_home/.config" \
  "$TIMER" install --dry-run >/dev/null 2>&1; rc=$?
assert_eq "timer install --dry-run exits 0" "0" "$rc"
if [[ -n "$(find "$scratch_home" -type f 2>/dev/null)" ]]; then
  err "timer install --dry-run wrote into HOME"
else
  ok "timer install --dry-run wrote nothing"
fi
rm -rf "$scratch_home"

for bad in "--weekday 9" "--hour 24" "--minute 60"; do
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$TIMER" install $bad >/dev/null 2>&1
  rc=$?
  assert_eq "timer rejects $bad -> 3" "3" "$rc"
done

# Options belong to the command they follow. Every flag was accepted after
# every command, so `uninstall --hour 3` looked like it had rescheduled
# something and had not - and `uninstall --dry-run` read as a preview while it
# disabled the timer and deleted both unit files for real. HOME is scratch
# because that is where a command which got past this check would write.
timer_scratch="$(mktemp -d)"
for bad in "uninstall --hour 3" "uninstall --dry-run" "uninstall --lines 5" \
           "status --lines 5" "run-now --hour 3" "logs --hour 3" \
           "install --lines 5"; do
  # shellcheck disable=SC2086  # the pair is meant to split into separate arguments
  HOME="$timer_scratch" XDG_CONFIG_HOME="$timer_scratch/.config" "$TIMER" $bad >/dev/null 2>&1
  rc=$?
  assert_eq "timer rejects '$bad' -> 3" "3" "$rc"
done

# ...and the check must not start refusing the pairings that are correct. logs
# needs journalctl, which these containers may not have, so what is asserted is
# that this is not a usage error - not that it succeeds.
HOME="$timer_scratch" XDG_CONFIG_HOME="$timer_scratch/.config" \
  "$TIMER" logs --lines 5 >/dev/null 2>&1
rc=$?
assert_eq "timer still accepts logs --lines" "no" "$([[ "$rc" == "3" ]] && echo yes || echo no)"
rm -rf "$timer_scratch"

# No user manager in a container, so a real install must report the wrong
# environment rather than half-writing units.
"$TIMER" install >/dev/null 2>&1
rc=$?
assert_eq "timer install without systemd -> 2" "2" "$rc"

section "hardening_audit is read-only and grades correctly"
# The whole value of this script is that it never changes the machine, so that
# is asserted directly rather than assumed: snapshot the files it inspects and
# require them to be untouched.
before="$( { stat -c '%a %Y' /etc/shadow /etc/passwd 2>/dev/null; ls /etc/ssh 2>/dev/null; } || true )"
out="$("$L/hardening_audit.sh" 2>&1)"
rc=$?
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

# The sshd settings past the first three, graded from a fixture sshd_config
# through the same ETC_SSH seam. No tester image installs openssh-server, so
# this is the file-fallback path; an sshd on PATH without host keys fails -T
# and falls back to the same file.
sshd_fx="$(mktemp -d)"
grade_sshd() {  # sshd_config lines -> the ssh group's output
  printf '%s\n' "$@" > "$sshd_fx/sshd_config"
  ETC_SSH="$sshd_fx" "$L/hardening_audit.sh" --only ssh 2>&1
}
# The verdict line for a setting and its hint, which is half of the assertion.
line_for() { grep -A1 -F -- "$1" <<<"$2" || true; }
out="$(grade_sshd 'MaxAuthTries 3')"
assert_contains "hardening_audit passes MaxAuthTries 3" "$(line_for MaxAuthTries "$out")" "[pass]"
out="$(grade_sshd 'MaxAuthTries 10')"
assert_contains "hardening_audit warns on MaxAuthTries 10" "$(line_for MaxAuthTries "$out")" "[warn]"
assert_contains "hardening_audit prints the MaxAuthTries line to add" "$(line_for MaxAuthTries "$out")" "MaxAuthTries 4"
out="$(grade_sshd '# nothing set')"
assert_contains "hardening_audit grades an unset MaxAuthTries by its default" "$(line_for MaxAuthTries "$out")" "default"
assert_contains "hardening_audit warns on the default MaxAuthTries" "$(line_for MaxAuthTries "$out")" "[warn]"
out="$(grade_sshd 'X11Forwarding yes')"
assert_contains "hardening_audit warns on X11Forwarding yes" "$(line_for X11Forwarding "$out")" "[warn]"
out="$(grade_sshd 'PermitUserEnvironment yes')"; rc=$?
assert_contains "hardening_audit fails PermitUserEnvironment yes" "$(line_for PermitUserEnvironment "$out")" "[FAIL]"
assert_eq "hardening_audit --only ssh exits 1 on PermitUserEnvironment yes" "1" "$rc"
out="$(grade_sshd 'PermitUserEnvironment no')"; rc=$?
assert_eq "hardening_audit --only ssh exits 0 with nothing at FAIL" "0" "$rc"
out="$(grade_sshd 'LoginGraceTime 0')"
assert_contains "hardening_audit fails an unlimited LoginGraceTime" "$(line_for LoginGraceTime "$out")" "[FAIL]"
out="$(grade_sshd 'LoginGraceTime 1m')"
assert_contains "hardening_audit reads LoginGraceTime 1m as 60s and passes it" "$(line_for LoginGraceTime "$out")" "[pass]"
out="$(grade_sshd 'LoginGraceTime 5m')"
assert_contains "hardening_audit warns on LoginGraceTime 5m" "$(line_for LoginGraceTime "$out")" "[warn]"
out="$(grade_sshd 'ClientAliveInterval 300' 'ClientAliveCountMax 2')"
assert_contains "hardening_audit passes a 300x2 idle window" "$(line_for ClientAliveInterval "$out")" "[pass]"
out="$(grade_sshd 'ClientAliveInterval 300' 'ClientAliveCountMax 3')"
assert_contains "hardening_audit passes a 300x3 (900s) idle window" "$(line_for ClientAliveInterval "$out")" "[pass]"
out="$(grade_sshd 'ClientAliveInterval 300')"
assert_contains "hardening_audit uses ClientAliveCountMax 3 when unset" "$(line_for ClientAliveInterval "$out")" "[pass]"
out="$(grade_sshd 'ClientAliveInterval 300' 'ClientAliveCountMax 100')"
assert_contains "hardening_audit warns on a 300x100 (30000s) idle window" "$(line_for ClientAliveInterval "$out")" "[warn]"
assert_contains "hardening_audit names interval, count and window" "$(line_for ClientAliveInterval "$out")" "30000s"
out="$(grade_sshd 'ClientAliveInterval 0' 'ClientAliveCountMax 2')"
assert_contains "hardening_audit warns ClientAliveInterval 0 is not enforced" "$(line_for ClientAliveInterval "$out")" "not enforced"
assert_contains "hardening_audit calls ClientAlive a liveness check" "$(line_for ClientAliveInterval "$(grade_sshd 'ClientAliveInterval 300' 'ClientAliveCountMax 2')")" "not an idle limit"
out="$(grade_sshd 'ClientAliveInterval 300')"
assert_contains "hardening_audit reports an unset ChannelTimeout" "$(line_for ChannelTimeout "$out")" "[info]"
assert_contains "hardening_audit says unset ChannelTimeout leaves idle sessions open" "$(line_for ChannelTimeout "$out")" "never closed"
out="$(grade_sshd 'ChannelTimeout session=30m')"
assert_contains "hardening_audit passes ChannelTimeout session=30m" "$(line_for ChannelTimeout "$out")" "[pass]"
out="$(grade_sshd 'ChannelTimeout global=5m session=30m')"
assert_contains "hardening_audit finds session among several ChannelTimeout entries" "$(line_for ChannelTimeout "$out")" "[pass]"
out="$(grade_sshd 'ChannelTimeout agent-connection=5m')"
assert_contains "hardening_audit notes a ChannelTimeout without a session entry" "$(line_for ChannelTimeout "$out")" "no session entry"
out="$(grade_sshd 'ChannelTimeout session=0')"
assert_contains "hardening_audit does not pass ChannelTimeout session=0" "$(line_for ChannelTimeout "$out")" "[info]"
assert_contains "hardening_audit says session=0 leaves idle sessions open" "$(line_for ChannelTimeout "$out")" "not bounded"
out="$(grade_sshd 'ChannelTimeout session:*=0')"
assert_contains "hardening_audit does not pass ChannelTimeout session:*=0" "$(line_for ChannelTimeout "$out")" "[info]"
out="$(grade_sshd 'ChannelTimeout session:*=1800')"
assert_contains "hardening_audit passes ChannelTimeout session:*=1800" "$(line_for ChannelTimeout "$out")" "[pass]"
out="$(grade_sshd 'HostbasedAuthentication yes')"
assert_contains "hardening_audit fails HostbasedAuthentication yes" "$(line_for HostbasedAuthentication "$out")" "[FAIL]"
out="$(grade_sshd 'IgnoreRhosts no')"
assert_contains "hardening_audit fails IgnoreRhosts no" "$(line_for IgnoreRhosts "$out")" "[FAIL]"

# Algorithm lists are graded only from sshd -T. A stub sshd answers -T with a
# list holding one weak and one strong name of each kind; a failing -T must be
# exactly one skip, not one per list.
sshd_stub="$(mktemp -d)"
cat > "$sshd_stub/sshd" <<'STUB'
#!/usr/bin/env bash
[[ -e "${0%/*}/t-fails" ]] && exit 1
if [[ "${1:-}" == "-T" ]]; then
  printf '%s\n' 'ciphers aes128-cbc,aes256-gcm@openssh.com' 'macs hmac-sha1,hmac-sha2-256-etm@openssh.com' \
    'kexalgorithms curve25519-sha256' 'hostkeyalgorithms ssh-ed25519'
fi
exit 0
STUB
chmod +x "$sshd_stub/sshd"
printf '# nothing set\n' > "$sshd_fx/sshd_config"
out="$(PATH="$sshd_stub:$PATH" ETC_SSH="$sshd_fx" "$L/hardening_audit.sh" --only ssh 2>&1)"
cipher_line="$(line_for 'weak ciphers' "$out")"
assert_contains "hardening_audit names a weak cipher" "$cipher_line" "aes128-cbc"
assert_not_contains "hardening_audit leaves a strong cipher out of the weak list" "$cipher_line" "aes256-gcm"
assert_contains "hardening_audit prints the removal syntax" "$cipher_line" "Ciphers -aes128-cbc"
assert_contains "hardening_audit names a weak MAC" "$(line_for 'weak MACs' "$out")" "hmac-sha1"
assert_contains "hardening_audit passes a strong key exchange list" "$out" "no weak key exchange offered"
: > "$sshd_stub/t-fails"
out="$(PATH="$sshd_stub:$PATH" ETC_SSH="$sshd_fx" "$L/hardening_audit.sh" --only ssh 2>&1)"
assert_eq "hardening_audit skips the algorithms once when sshd -T fails" "1" \
  "$(grep -c 'effective sshd algorithms need root' <<<"$out")"
assert_contains "hardening_audit still grades the file when sshd -T fails" "$out" "MaxAuthTries not set"
assert_eq "hardening_audit --list-groups is unchanged" "ssh accounts network files updates kernel" \
  "$("$L/hardening_audit.sh" --list-groups | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$sshd_fx" "$sshd_stub"

# A container has no firewall and no sshd, so a clean exit here proves absent
# tooling is reported rather than treated as a crash.
if [[ "$rc" == "0" || "$rc" == "1" ]]; then
  ok "hardening_audit exits 0 or 1, not an error ($rc)"
else
  err "hardening_audit exited $rc; expected 0 or 1"
fi

# --fail-on warn must be stricter than the default, never looser.
"$L/hardening_audit.sh" >/dev/null 2>&1; rc_default=$?
"$L/hardening_audit.sh" --fail-on warn >/dev/null 2>&1; rc_strict=$?
if (( rc_strict >= rc_default )); then
  ok "--fail-on warn is at least as strict as the default ($rc_default -> $rc_strict)"
else
  err "--fail-on warn ($rc_strict) was looser than the default ($rc_default)"
fi

"$L/hardening_audit.sh" --only nosuchgroup >/dev/null 2>&1; rc=$?
assert_eq "hardening_audit rejects an unknown group -> 3" "3" "$rc"

out="$("$L/hardening_audit.sh" --only kernel 2>&1)"; rc=$?
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

out="$("$L/hardening_audit.sh" --only files 2>&1)"; rc=$?
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

out="$("$L/hardening_audit.sh" --only updates 2>&1)"; rc=$?
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

section "system_doctor reports rather than grades"
# A container has no systemd, no sshd, no firewall and no container engine, so
# this is the environment where a health report is most likely to trip over
# something absent. Exiting 0 here is the assertion: every probe has to degrade
# to a note.
scratch_home="$(mktemp -d)"
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$L/system_doctor.sh" 2>&1)"; rc=$?
assert_eq "system_doctor exits 0 with almost nothing installed" "0" "$rc"
assert_contains "system_doctor prints a summary" "$out" "== summary =="
assert_contains "system_doctor names the package manager" "$out" "package manager: $EXPECT_PKG_MGR"
assert_contains "system_doctor reports memory pressure" "$out" "== memory =="
assert_contains "system_doctor reports clock sync" "$out" "== time =="
assert_contains "system_doctor reports journal" "$out" "== journal =="
assert_contains "system_doctor reports sessions" "$out" "== sessions =="
# The pressure probes against the container's real /proc: whatever this kernel
# exposes, a missing or unreadable file has to degrade to a skip.
assert_contains "system_doctor reports pressure against the real /proc" "$out" "== pressure =="
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

for bad in "--min-free 101" "--min-free notanumber" "--min-memory 101" "--min-memory notanumber" \
           "--max-psi abc" "--max-psi 150" "--max-psi 100.5"; do
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$L/system_doctor.sh" $bad >/dev/null 2>&1
  rc=$?
  assert_eq "system_doctor rejects $bad -> 3" "3" "$rc"
done

# A hint with nowhere to go is not a hint. info() rendered only its first
# argument, so the one observation that hands you a next command without being
# a finding - the pending-upgrade count, which is a fact about the machine
# rather than something wrong with it - passed its preview to a parameter that
# was never printed. The count is forced with a stub rather than waited for: a
# container reports nothing pending, so the line carrying the hint never
# appears on its own. OS_RELEASE pins the package manager so this reads the
# same on the fedora and arch images.
doctor_stub="$(mktemp -d)"
printf 'ID=debian\n' > "$doctor_stub/os-release"
cat > "$doctor_stub/apt-get" <<'STUB'
#!/usr/bin/env bash
printf 'Inst libc6 [2.36-9] (2.36-9+deb12u1 Debian:12/stable [amd64])\n'
printf 'Inst openssl [3.0.11-1] (3.0.14-1 Debian:12/stable [amd64])\n'
printf 'Conf libc6 (2.36-9+deb12u1 Debian:12/stable [amd64])\n'
STUB
chmod +x "$doctor_stub/apt-get"
out="$(OS_RELEASE="$doctor_stub/os-release" PATH="$doctor_stub:$PATH" \
  "$L/system_doctor.sh" 2>&1)"; rc=$?
assert_eq "system_doctor with pending upgrades exits 0" "0" "$rc"
assert_contains "system_doctor counts the pending upgrades" "$out" "2 pending upgrade(s)"
assert_contains "system_doctor prints the hint beside the count" "$out" "preview: stay_fresh.sh --dry-run"
rm -rf "$doctor_stub"

# The storage section's faults cannot be produced in a container: nothing here
# can remount a filesystem read-only, lose an fstab mount or degrade an md
# array. PROC_DIR and FSTAB hand the parsers fixture files instead. The NFS
# line is there to prove --skip-remote-mounts keeps the probe from running.
storage_fx="$(mktemp -d)"
printf '%s\n' '/dev/sda1 /data ext4 ro,relatime 0 0' '/dev/sda2 /ok ext4 rw,relatime,errors=remount-ro 0 0' \
  '/dev/loop0 /snap/core squashfs ro,nodev,relatime 0 0' '/dev/sde1 /sysroot xfs ro,relatime 0 0' \
  '/dev/sdf1 /vol ext4 ro,relatime 0 0' '/dev/sdg1 /fstab-ro ext4 ro,relatime,errors=remount-ro 0 0' 'srv:/x /mnt/nfs nfs4 rw,relatime 0 0' > "$storage_fx/mounts"
printf '%s\n' '# /etc/fstab fixture' '/dev/sda1 /data ext4 defaults 0 2' '/dev/sda2 /ok ext4 defaults 0 2' '/dev/sdg1 /fstab-ro ext4 ro 0 2' '/dev/sdb1 /srv ext4 defaults 0 2' \
  '/dev/sdc1 /opt ext4 defaults,nofail 0 2' '/dev/sdd1 /mnt/x ext4 noauto 0 0' '/swapfile none swap sw 0 0' > "$storage_fx/fstab"
printf '%s\n' 'Personalities : [raid1]' 'md0 : active raid1 sdb1[1] sda1[0]' '      1000 blocks [2/1] [U_]' '' \
  'unused devices: <none>' > "$storage_fx/mdstat"
# smartctl is a stub so the SMART branch is reachable at all; it records argv
# so the run is proved to have only asked for health.
storage_stub="$(mktemp -d)"
cat > "$storage_stub/smartctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${0%/*}/argv.log"
case " $* " in
  *" --scan "*) printf '/dev/sda -d scsi # /dev/sda, SCSI device\n' ;;
  *" -H "*)     printf 'SMART overall-health self-assessment test result: FAILED!\n' ;;
esac
exit 0
STUB
chmod +x "$storage_stub/smartctl"
run_storage() {
  PROC_DIR="$storage_fx" FSTAB="$storage_fx/fstab" PATH="$storage_stub:$PATH" \
    "$L/system_doctor.sh" --skip-containers --skip-units --skip-remote-mounts "$@" 2>&1
}
out="$(run_storage)"; rc=$?
assert_eq "system_doctor with storage faults still exits 0" "0" "$rc"
assert_contains "system_doctor has a storage section" "$out" "== storage =="
assert_contains "system_doctor reports a read-only remount" "$out" "/data is mounted read-only (ext4)"
assert_not_contains "system_doctor ignores read-only-by-design squashfs" "$out" "/snap/core is mounted read-only"
assert_not_contains "system_doctor ignores the ostree /sysroot" "$out" "/sysroot is mounted read-only"
assert_not_contains "system_doctor ignores a ro mount with no fstab entry" "$out" "/vol is mounted read-only"
assert_not_contains "system_doctor ignores a mount fstab declares ro" "$out" "/fstab-ro is mounted read-only"
assert_not_contains "system_doctor reads errors=remount-ro as an option, not a state" "$out" "/ok is mounted read-only"
assert_contains "system_doctor warns on an fstab mount that is missing" \
  "$(grep -F 'fstab entry /srv ' <<<"$out" || true)" "[warn]"
assert_contains "system_doctor only notes a missing nofail mount" \
  "$(grep -F 'fstab entry /opt ' <<<"$out" || true)" "[info]"
assert_not_contains "system_doctor skips noauto fstab entries" "$out" "fstab entry /mnt/x"
assert_not_contains "system_doctor skips swap fstab entries" "$out" "fstab entry none"
assert_contains "system_doctor reports a degraded md array" "$out" "md array md0 is degraded ([2/1] [U_])"
assert_contains "system_doctor leaves remote mounts alone with --skip-remote-mounts" "$out" "/mnt/nfs (nfs4) not probed (--skip-remote-mounts)"
if [[ "$(id -u)" == "0" ]]; then
  assert_contains "system_doctor reports a disk failing its own SMART check" "$out" "SMART overall health FAILED on /dev/sda"
  if grep -qE -- '(^| )(-t|--test|-s|--smart|-X|--abort)( |$)' "$storage_stub/argv.log" 2>/dev/null; then
    err "system_doctor asked smartctl for more than a health check"
  else
    ok "system_doctor only asks smartctl for health"
  fi
else
  assert_contains "system_doctor says SMART needs root" "$out" "SMART needs root"
fi
out="$(run_storage --skip-smart)"; rc=$?
assert_eq "system_doctor accepts --skip-smart" "0" "$rc"
assert_contains "system_doctor --skip-smart says so" "$out" "SMART health (--skip-smart)"
out="$(run_storage --quiet)"
assert_contains "system_doctor --quiet keeps storage warnings" "$out" "/data is mounted read-only"

printf '%s\n' '/dev/sda1 /data ext4 rw,relatime 0 0' '/dev/sda2 /ok ext4 rw,relatime 0 0' '/dev/sdg1 /fstab-ro ext4 ro,relatime 0 0' \
  '/dev/sdb1 /srv ext4 rw 0 0' '/dev/sdc1 /opt ext4 rw 0 0' > "$storage_fx/mounts"
printf '%s\n' 'md0 : active raid1 sdb1[1] sda1[0]' '      1000 blocks [2/2] [UU]' > "$storage_fx/mdstat"
out="$(run_storage --skip-smart)"
assert_contains "system_doctor says when nothing is read-only" "$out" "no real filesystem is mounted read-only"
assert_contains "system_doctor says when every fstab entry is mounted" "$out" "every fstab entry is mounted (5 checked)"
assert_contains "system_doctor reports a healthy md array" "$out" "md array md0 is healthy ([2/2] [UU])"
# A kernel remount (errors=remount-ro) must still be reported when fstab is
# absent or empty; the first mount lines must not be read as fstab entries.
printf '%s\n' '/dev/sda1 /data ext4 ro,relatime,errors=remount-ro 0 0' '/dev/sdf1 /vol ext4 ro,relatime 0 0' > "$storage_fx/mounts"
: > "$storage_fx/fstab-empty"
for fstab_case in "$storage_fx/fstab-absent" "$storage_fx/fstab-empty"; do
  out="$(PROC_DIR="$storage_fx" FSTAB="$fstab_case" PATH="$storage_stub:$PATH" \
    "$L/system_doctor.sh" --skip-containers --skip-units --skip-remote-mounts --skip-smart 2>&1)"
  assert_contains "system_doctor reports a ro remount with fstab ${fstab_case##*/}" "$out" "/data is mounted read-only (ext4)"
  assert_not_contains "system_doctor ignores a bare ro mount with fstab ${fstab_case##*/}" "$out" "/vol is mounted read-only"
done
rm -rf "$storage_fx" "$storage_stub"

# Pressure and limits. A fixture procfs holds quiet PSI files, file handles,
# conntrack counters, thread limits and a loadavg; each case below rewrites
# one file into the state that should warn.
press_fx="$(mktemp -d)"
mkdir -p "$press_fx/pressure" "$press_fx/sys/fs" "$press_fx/sys/net/netfilter" "$press_fx/sys/kernel"
write_quiet_pressure() {
  mkdir -p "$press_fx/pressure"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$press_fx/pressure/cpu"
  for r in memory io; do
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$press_fx/pressure/$r"
  done
  printf '1000\t0\t100000\n' > "$press_fx/sys/fs/file-nr"
  printf '10\n' > "$press_fx/sys/net/netfilter/nf_conntrack_count"
  printf '100000\n' > "$press_fx/sys/net/netfilter/nf_conntrack_max"
  printf '100000\n' > "$press_fx/sys/kernel/threads-max"
  printf '4194304\n' > "$press_fx/sys/kernel/pid_max"
  printf '0.10 0.10 0.10 1/200 123\n' > "$press_fx/loadavg"
}
run_pressure() {
  PROC_DIR="$press_fx" "$L/system_doctor.sh" --skip-containers --skip-units --skip-smart "$@" 2>&1
}
write_quiet_pressure
out="$(run_pressure)"; rc=$?
assert_eq "system_doctor with quiet pressure exits 0" "0" "$rc"
assert_contains "system_doctor has a pressure section" "$out" "== pressure =="
assert_not_contains "system_doctor raises no stall on quiet PSI" "$out" "pressure: tasks stalled"
assert_contains "system_doctor reports file handles" "$out" "file handles 1% used"

printf 'some avg10=0.00 avg60=35.50 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$press_fx/pressure/memory"
out="$(run_pressure)"; rc=$?
assert_eq "system_doctor with memory stalls still exits 0" "0" "$rc"
assert_contains "system_doctor warns on memory pressure" "$(grep -F 'memory pressure' <<<"$out" || true)" "[warn]"
assert_contains "system_doctor prints the stall percentage" "$out" "35.5"
out="$(run_pressure --max-psi 50)"
assert_not_contains "system_doctor honours --max-psi" "$out" "memory pressure: tasks stalled"

write_quiet_pressure
printf '90000\t0\t100000\n' > "$press_fx/sys/fs/file-nr"
printf '95000\n' > "$press_fx/sys/net/netfilter/nf_conntrack_count"
printf '0.10 0.10 0.10 1/90000 123\n' > "$press_fx/loadavg"
out="$(run_pressure)"
assert_contains "system_doctor warns on file handles" "$out" "file handles 90% used"
assert_contains "system_doctor warns on a filling conntrack table" "$out" "connection tracking table 95% full"
assert_contains "system_doctor warns on thread headroom" "$out" "kernel.threads-max"

rm -rf "$press_fx/pressure"
out="$(run_pressure)"; rc=$?
assert_eq "system_doctor without PSI exits 0" "0" "$rc"
assert_contains "system_doctor says the kernel has no PSI" "$out" "kernel has no PSI"

# Process states come from one ps call. A stub ps answers that call with a
# dozen zombies and six tasks in D state; any other ps call gets nothing.
ps_stub="$(mktemp -d)"
cat > "$ps_stub/ps" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" stat=,pid=,comm= "*)
    i=0
    while (( i < 12 )); do printf 'Z    %s defunct\n' "$((100 + i))"; i=$((i + 1)); done
    i=0
    while (( i < 6 )); do printf 'D    %s jbd2\n' "$((200 + i))"; i=$((i + 1)); done
    printf 'Ss   1 init\n'
    ;;
esac
exit 0
STUB
chmod +x "$ps_stub/ps"
write_quiet_pressure
out="$(PATH="$ps_stub:$PATH" run_pressure)"; rc=$?
assert_eq "system_doctor with stuck processes exits 0" "0" "$rc"
assert_contains "system_doctor warns on zombies" "$out" "12 zombie process(es)"
assert_contains "system_doctor warns on uninterruptible sleep" "$out" "6 process(es) in uninterruptible sleep"
assert_contains "system_doctor names a stuck process" "$out" "200 jbd2"
rm -rf "$press_fx" "$ps_stub"

section "container_doctor.sh"
CDOC="$L/container_doctor.sh"
scratch_home="$(mktemp -d)"
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$CDOC" 2>&1)"; rc=$?
assert_eq "container_doctor exits 0 with almost nothing installed" "0" "$rc"
assert_contains "container_doctor prints a summary" "$out" "== summary =="
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "container_doctor wrote nothing"
else
  err "container_doctor wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home"

for bad in "--engine nosuch" "--restart-threshold 0" "--log-warn-mb abc" "--fail-on sometimes" "--only nosuch" "--bogus"; do
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$CDOC" $bad >/dev/null 2>&1
  rc=$?
  assert_eq "container_doctor rejects $bad -> 3" "3" "$rc"
done
"$CDOC" --only , >/dev/null 2>&1; rc=$?
assert_eq "container_doctor --only empty selection -> 4" "4" "$rc"
cdoc_groups="$("$CDOC" --list-groups)"
for g in state security resources logs images; do
  assert_contains "container_doctor lists group $g" "$cdoc_groups" "$g"
done

# No tester image runs a container engine, so a stub docker ahead of PATH
# answers with fixture rows in the shape the inspect template asks for, and
# records every argv it is given. c1 is in a restart loop; c2 was OOM-killed,
# runs privileged with the engine socket mounted and an uncapped json-file log
# that is already 600 MiB (a sparse file); c3 is healthy, limited and capped.
cdoc_stub="$(mktemp -d)"
cat > "$cdoc_stub/docker" <<'STUB'
#!/usr/bin/env bash
here="${0%/*}"
printf '%s\n' "$*" >> "$here/argv.log"
case "$1" in
  info)    [[ -e "$here/info-fails" ]] && exit 1; exit 0 ;;
  version) exit 0 ;;
  ps)      printf 'c1\nc2\nc3\n' ;;
  inspect)
    for last in "$@"; do :; done
    [[ -f "$here/$last.row" ]] && cat "$here/$last.row"
    ;;
  images)  printf 'aaa111\nbbb222\n' ;;
  system)
    printf 'TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\n'
    printf 'Images          4         2         1.2GB     800MB (66%%)\n'
    ;;
esac
exit 0
STUB
chmod +x "$cdoc_stub/docker"
cdoc_log="$cdoc_stub/c2-json.log"
truncate -s 600M "$cdoc_log"
tab=$'\t'
printf '%s\n' "/web${tab}running${tab}0${tab}9${tab}false${tab}-${tab}false${tab}bridge${tab}268435456${tab}always${tab}-${tab}json-file${tab}{\"max-size\":\"10m\"}${tab}-${tab}nginx:1.27${tab}-" > "$cdoc_stub/c1.row"
printf '%s\n' "/worker${tab}exited${tab}137${tab}0${tab}true${tab}-${tab}true${tab}bridge${tab}0${tab}no${tab}-${tab}json-file${tab}{}${tab}$cdoc_log${tab}worker:latest${tab}-,/var/run/docker.sock" > "$cdoc_stub/c2.row"
printf '%s\n' "/db${tab}running${tab}0${tab}0${tab}false${tab}healthy${tab}false${tab}bridge${tab}536870912${tab}unless-stopped${tab}postgres${tab}json-file${tab}{\"max-file\":\"3\",\"max-size\":\"10m\"}${tab}-${tab}postgres:16${tab}-,/srv/db" > "$cdoc_stub/c3.row"
printf '{ "log-driver": "json-file" }\n' > "$cdoc_stub/daemon-uncapped.json"
printf '{ "log-driver": "json-file", "log-opts": { "max-size": "10m" } }\n' > "$cdoc_stub/daemon-capped.json"

out="$(PATH="$cdoc_stub:$PATH" DOCKER_DAEMON_JSON="$cdoc_stub/daemon-uncapped.json" "$CDOC" 2>&1)"; rc=$?
assert_eq "container_doctor reads rather than gates by default" "0" "$rc"
assert_contains "container_doctor flags the restart loop" "$out" "web is restarting"
assert_contains "container_doctor fails an OOM-killed container" "$out" "worker was OOM-killed"
assert_contains "container_doctor grades OOM as [FAIL]" "$out" "[FAIL]"
assert_contains "container_doctor fails an engine socket mount" "$out" "docker.sock"
assert_contains "container_doctor warns on a privileged container" "$out" "worker runs privileged"
assert_contains "container_doctor warns on an uncapped json-file log" "$out" "unbounded"
assert_contains "container_doctor sizes a log past --log-warn-mb" "$out" "worker log is 600M"
assert_contains "container_doctor counts dangling images" "$out" "2 dangling image(s)"
assert_contains "container_doctor counts latest-tagged images" "$out" "worker"
assert_not_contains "container_doctor leaves the healthy container alone" "$out" "db is restarting"

out="$(PATH="$cdoc_stub:$PATH" DOCKER_DAEMON_JSON="$cdoc_stub/daemon-capped.json" "$CDOC" --only logs 2>&1)"
assert_not_contains "container_doctor honours a daemon-wide max-size" "$out" "unbounded"
assert_not_contains "container_doctor --only logs leaves state out" "$out" "== state =="

PATH="$cdoc_stub:$PATH" DOCKER_DAEMON_JSON="$cdoc_stub/daemon-uncapped.json" "$CDOC" --fail-on fail >/dev/null 2>&1; rc=$?
assert_eq "container_doctor --fail-on fail exits 1 on a FAIL" "1" "$rc"
PATH="$cdoc_stub:$PATH" DOCKER_DAEMON_JSON="$cdoc_stub/daemon-uncapped.json" "$CDOC" --fail-on never >/dev/null 2>&1; rc=$?
assert_eq "container_doctor --fail-on never stays 0" "0" "$rc"

cdoc_argv="$(cat "$cdoc_stub/argv.log" 2>/dev/null || true)"
assert_contains "container_doctor inspected the containers" "$cdoc_argv" "inspect"
if grep -qE '^(rm|rmi|stop|kill|prune|exec|run|start|restart|update|create|commit|cp|pause|system prune|image prune|volume|network) ' <<<"$cdoc_argv"; then
  err "container_doctor ran an engine verb that changes something"
else
  ok "container_doctor ran only read-only engine verbs"
fi

: > "$cdoc_stub/info-fails"
out="$(PATH="$cdoc_stub:$PATH" DOCKER_DAEMON_JSON="$cdoc_stub/daemon-uncapped.json" "$CDOC" --engine docker 2>&1)"; rc=$?
assert_eq "container_doctor with an unreachable daemon exits 0" "0" "$rc"
assert_contains "container_doctor says the daemon is not reachable" "$out" "not reachable"

# No engine at all: PATH holds only the tools the script reads with.
cdoc_bin="$(mktemp -d)"
for tool in bash awk sort grep head tr sed stat wc cat uname id; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ "$tool_path" == /* ]] && ln -s "$tool_path" "$cdoc_bin/$tool"
done
out="$(PATH="$cdoc_bin" "$CDOC" 2>&1)"; rc=$?
assert_eq "container_doctor without an engine exits 0" "0" "$rc"
assert_contains "container_doctor skips when no engine is installed" "$out" "neither docker nor podman is installed"
rm -rf "$cdoc_stub" "$cdoc_bin"

section "install_aliases.sh"
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
HOME="$alias_link_home" "$ALIASES" --home "$alias_link_home" >/dev/null 2>&1; rc=$?
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
out="$(HOME="$alias_home" "$ALIASES" --dry-run --home "$alias_home" 2>&1)"; rc=$?
assert_eq "install_aliases --dry-run exits 0" "0" "$rc"
assert_contains "install_aliases dry-run names bashrc" "$out" "would create"
if [[ -e "$alias_home/.bashrc" ]]; then
  err "install_aliases --dry-run wrote .bashrc"
else
  ok "install_aliases --dry-run wrote nothing"
fi

out="$("$ALIASES" --home "$alias_home" 2>&1)"; rc=$?
assert_eq "install_aliases install exits 0" "0" "$rc"
if grep -q 'ops-toolbox bash_aliases' "$alias_home/.bashrc"; then
  ok "install_aliases wrote a marked block"
else
  err "install_aliases did not write the marked block"
fi
first_bashrc="$(cat "$alias_home/.bashrc")"
"$ALIASES" --home "$alias_home" >/dev/null 2>&1
if [[ "$first_bashrc" == "$(cat "$alias_home/.bashrc")" ]]; then
  ok "install_aliases second run is a no-op"
else
  err "install_aliases second run rewrote .bashrc"
fi

out="$("$ALIASES" --status --home "$alias_home" 2>&1)"; rc=$?
assert_eq "install_aliases --status MATCH -> 0" "0" "$rc"
assert_contains "install_aliases --status says MATCH" "$out" "MATCH"

out="$("$ALIASES" --uninstall --dry-run --home "$alias_home" 2>&1)"; rc=$?
assert_eq "install_aliases uninstall --dry-run exits 0" "0" "$rc"
if grep -q 'ops-toolbox bash_aliases' "$alias_home/.bashrc"; then
  ok "uninstall --dry-run left the block in place"
else
  err "uninstall --dry-run removed the block"
fi

"$ALIASES" --uninstall --home "$alias_home" >/dev/null 2>&1; rc=$?
assert_eq "install_aliases uninstall exits 0" "0" "$rc"
if grep -q 'ops-toolbox bash_aliases' "$alias_home/.bashrc" 2>/dev/null; then
  err "uninstall left the marked block behind"
else
  ok "uninstall removed the marked block"
fi
rm -rf "$alias_home"

section "disk_cleanup.sh"
CLEAN="$L/disk_cleanup.sh"
"$CLEAN" >/dev/null 2>&1; rc=$?
assert_eq "disk_cleanup without --yes -> 3" "3" "$rc"

clean_home="$(mktemp -d)"
clean_tmp="$(mktemp -d)"
# Old enough to be selected at --days 1, and new enough to be kept.
old_file="$clean_tmp/old.txt"
new_file="$clean_tmp/new.txt"
printf 'old-bytes\n' > "$old_file"
printf 'new-bytes\n' > "$new_file"
touch -d '10 days ago' "$old_file"

out="$("$CLEAN" --dry-run --days 1 --home "$clean_home" --tmp "$clean_tmp" 2>&1)"; rc=$?
assert_eq "disk_cleanup --dry-run exits 0" "0" "$rc"
assert_contains "disk_cleanup dry-run names the old file" "$out" "old.txt"
assert_contains "disk_cleanup dry-run reports no changes" "$out" "dry-run complete; no changes written"
if [[ -f "$old_file" && -f "$new_file" ]]; then
  ok "disk_cleanup --dry-run deleted nothing"
else
  err "disk_cleanup --dry-run deleted a temp file"
fi

out="$("$CLEAN" --yes --days 1 --home "$clean_home" --tmp "$clean_tmp" 2>&1)"; rc=$?
assert_eq "disk_cleanup --yes exits 0" "0" "$rc"
if [[ ! -f "$old_file" && -f "$new_file" ]]; then
  ok "disk_cleanup deleted the old file and kept the new one"
else
  err "disk_cleanup age filter misbehaved (old=$([[ -f $old_file ]] && echo present || echo gone), new=$([[ -f $new_file ]] && echo present || echo gone))"
fi

# XDG_CACHE_HOME names the cache of whoever is running the script; --home names
# a different profile to clean. Honouring both at once reached outside the
# directory --home pointed at, which is the one place --home promises to keep
# the run inside: this suite, run on a desktop with XDG_CACHE_HOME exported,
# emptied the developer's own thumbnail cache. Under --home the variable must be
# inert, and the run must say so rather than silently skipping a step.
xdg_outside="$(mktemp -d)"
mkdir -p "$xdg_outside/thumbnails"
printf 'not-ours\n' > "$xdg_outside/thumbnails/keep.png"
out="$(XDG_CACHE_HOME="$xdg_outside" "$CLEAN" --yes --days 1 \
  --home "$clean_home" --tmp "$clean_tmp" 2>&1)"; rc=$?
assert_eq "disk_cleanup --home with an ambient XDG_CACHE_HOME exits 0" "0" "$rc"
if [[ -f "$xdg_outside/thumbnails/keep.png" ]]; then
  ok "--home makes an ambient XDG_CACHE_HOME inert"
else
  err "--home honoured XDG_CACHE_HOME and deleted outside the profile it named"
fi
assert_contains "the ignored XDG_CACHE_HOME is announced" "$out" "XDG_CACHE_HOME ignored"

# The variable is not being distrusted, only re-aimed: without --home it is the
# caller's own cache and must still be cleaned.
printf 'ours\n' > "$xdg_outside/thumbnails/mine.png"
out="$(HOME="$clean_home" XDG_CACHE_HOME="$xdg_outside" "$CLEAN" --yes --days 1 \
  --tmp "$clean_tmp" 2>&1)"; rc=$?
assert_eq "disk_cleanup without --home exits 0" "0" "$rc"
if [[ ! -f "$xdg_outside/thumbnails/mine.png" ]]; then
  ok "without --home the XDG thumbnail cache is still cleaned"
else
  err "without --home the XDG thumbnail cache was skipped"
fi
rm -rf "$xdg_outside"

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

"$CLEAN" --coredump-dir / --dry-run --home "$core_home" --tmp "$core_tmp" >/dev/null 2>&1; rc=$?
assert_eq "disk_cleanup --coredump-dir / -> 3" "3" "$rc"

# The literal '/' above was the only spelling this suite checked, and an exact
# string guard passed everything else through to a recursive, sudo-escalating
# delete of the whole filesystem. Each of these names root just as surely.
for core_root in '//' '/.' '/../' '/var/..' '/tmp/../'; do
  "$CLEAN" --coredump-dir "$core_root" --include-coredumps --days 0 --dry-run \
    --home "$core_home" --tmp "$core_tmp" >/dev/null 2>&1; rc=$?
  assert_eq "disk_cleanup --coredump-dir $core_root -> 3" "3" "$rc"
done

# ...and the guard must not become so eager that a real directory is refused.
"$CLEAN" --coredump-dir "$core_dir" --include-coredumps --days 0 --dry-run \
  --home "$core_home" --tmp "$core_tmp" >/dev/null 2>&1; rc=$?
assert_eq "disk_cleanup --coredump-dir <real dir> -> 0" "0" "$rc"

out="$("$CLEAN" --yes --days 1 --home "$core_home" --tmp "$core_tmp" --coredump-dir "$core_dir" 2>&1)"; rc=$?
assert_eq "disk_cleanup without --include-coredumps exits 0" "0" "$rc"
if [[ -f "$old_core" && -f "$new_core" ]]; then
  ok "disk_cleanup left coredumps alone without --include-coredumps"
else
  err "disk_cleanup deleted coredumps without --include-coredumps"
fi
assert_contains "disk_cleanup names the coredump skip" "$out" "skipped: coredumps"

out="$("$CLEAN" --dry-run --days 1 --home "$core_home" --tmp "$core_tmp" --include-coredumps --coredump-dir "$core_dir" 2>&1)"; rc=$?
assert_eq "disk_cleanup --include-coredumps --dry-run exits 0" "0" "$rc"
assert_contains "disk_cleanup coredump dry-run names the old file" "$out" "old.core"
assert_contains "disk_cleanup coredump dry-run reports no changes" "$out" "dry-run complete; no changes written"
if [[ -f "$old_core" && -f "$new_core" ]]; then
  ok "disk_cleanup coredump --dry-run deleted nothing"
else
  err "disk_cleanup coredump --dry-run deleted a file"
fi

out="$("$CLEAN" --yes --days 1 --home "$core_home" --tmp "$core_tmp" --include-coredumps --coredump-dir "$core_dir" 2>&1)"; rc=$?
assert_eq "disk_cleanup --include-coredumps --yes exits 0" "0" "$rc"
if [[ ! -f "$old_core" && -f "$new_core" ]]; then
  ok "disk_cleanup deleted the old coredump and kept the new one"
else
  err "disk_cleanup coredump age filter misbehaved (old=$([[ -f $old_core ]] && echo present || echo gone), new=$([[ -f $new_core ]] && echo present || echo gone))"
fi
rm -rf "$core_home" "$core_tmp" "$core_dir"

# The Trash is emptied whole. linux/stay_fresh.sh was fixed for both failures
# below and its comment points at disk_cleanup.sh, but the fix never travelled,
# so these assert the behaviour here rather than trusting the sibling.
#
# A trashed *directory* is one item, not a container: walking `-type f` deleted
# files/project/nested/big.bin and left files/project/ behind as an empty
# skeleton — while info/project.trashinfo was deleted, so what remained could
# no longer be restored or even identified.
trash_home="$(mktemp -d)"
trash_tmp="$(mktemp -d)"
mkdir -p "$trash_home/.local/share/Trash/files/project/nested" \
         "$trash_home/.local/share/Trash/info"
printf 'payload\n' > "$trash_home/.local/share/Trash/files/project/nested/big.bin"
printf 'loose\n'   > "$trash_home/.local/share/Trash/files/loose.txt"
: > "$trash_home/.local/share/Trash/info/project.trashinfo"

out="$("$CLEAN" --yes --include-trash --home "$trash_home" --tmp "$trash_tmp" 2>&1)"; rc=$?
assert_eq "disk_cleanup --include-trash exits 0" "0" "$rc"
assert_eq "disk_cleanup removes a trashed directory, not just its files" "" \
  "$(ls -A "$trash_home/.local/share/Trash/files" 2>/dev/null)"
assert_eq "disk_cleanup removes the .trashinfo records" "" \
  "$(ls -A "$trash_home/.local/share/Trash/info" 2>/dev/null)"
assert_eq "disk_cleanup keeps the Trash files/ directory itself" "yes" \
  "$([[ -d "$trash_home/.local/share/Trash/files" ]] && echo yes || echo no)"
assert_eq "disk_cleanup keeps the Trash info/ directory itself" "yes" \
  "$([[ -d "$trash_home/.local/share/Trash/info" ]] && echo yes || echo no)"
rm -rf "$trash_home"

# And a Trash relocated to another disk - files/ a symlink, the usual way to
# keep it off a small SSD. `[[ -d ]]` follows the link but find does not, so
# `-type f` matched nothing: the run printed "nothing in trash files" and freed
# zero bytes on the machine most likely to need the space. The dry run has to
# see the relocated files too, and still write nothing.
trash_home="$(mktemp -d)"
other_disk="$(mktemp -d)"
mkdir -p "$trash_home/.local/share/Trash/info" "$other_disk/files"
printf 'many-bytes-of-iso\n' > "$other_disk/files/big.iso"
ln -s "$other_disk/files" "$trash_home/.local/share/Trash/files"

out="$("$CLEAN" --dry-run --include-trash --home "$trash_home" --tmp "$trash_tmp" 2>&1)"; rc=$?
assert_eq "disk_cleanup trash --dry-run exits 0" "0" "$rc"
assert_contains "disk_cleanup dry-run names the file in a relocated trash" "$out" "big.iso"
assert_not_contains "disk_cleanup does not call a relocated trash empty" "$out" "nothing in trash files"
# -delete reports no sizes, so the total is measured in a pass beforehand; a
# preview that reached nothing would still have to add up to nothing.
assert_not_contains "disk_cleanup counts what a relocated trash would free" "$out" "would free at least 0B"
if [[ -f "$other_disk/files/big.iso" ]]; then
  ok "disk_cleanup trash --dry-run deleted nothing"
else
  err "disk_cleanup trash --dry-run emptied a relocated trash"
fi

out="$("$CLEAN" --yes --include-trash --home "$trash_home" --tmp "$trash_tmp" 2>&1)"; rc=$?
assert_eq "disk_cleanup relocated trash exits 0" "0" "$rc"
assert_eq "disk_cleanup keeps a relocated Trash symlink" "yes" \
  "$([[ -L "$trash_home/.local/share/Trash/files" ]] && echo yes || echo no)"
assert_eq "disk_cleanup empties a relocated Trash" "" \
  "$(ls -A "$other_disk/files" 2>/dev/null)"
assert_not_contains "disk_cleanup counts what a relocated trash freed" "$out" "freed at least 0B"
rm -rf "$trash_home" "$trash_tmp" "$other_disk"

section "net_doctor.sh"
NET="$L/net_doctor.sh"
scratch_home="$(mktemp -d)"
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$NET" 2>&1)"; rc=$?
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

# The links section reads sysfs, and a container has no NIC worth grading. A
# fake /sys/class/net holds a physical eth0 (it has a device link) and a
# veth0 (it does not); each case rewrites one eth0 file into a fault.
links_fx="$(mktemp -d)"
links_bond="$(mktemp -d)"
mkdir -p "$links_fx/eth0/statistics" "$links_fx/eth0/device" "$links_fx/veth0/statistics"
write_clean_link() {
  printf 'up\n' > "$links_fx/eth0/operstate"
  printf '1000\n' > "$links_fx/eth0/speed"
  printf 'full\n' > "$links_fx/eth0/duplex"
  printf '2\n' > "$links_fx/eth0/carrier_changes"
  printf '1500\n' > "$links_fx/eth0/mtu"
  printf '02:00:00:00:00:01\n' > "$links_fx/eth0/address"
  for c in rx_errors tx_errors rx_dropped tx_dropped rx_crc_errors rx_fifo_errors collisions; do
    printf '0\n' > "$links_fx/eth0/statistics/$c"
  done
  printf '1000\n' > "$links_fx/eth0/statistics/rx_packets"
  printf '1000\n' > "$links_fx/eth0/statistics/tx_packets"
  printf 'up\n' > "$links_fx/veth0/operstate"
  printf '9000\n' > "$links_fx/veth0/statistics/rx_errors"
  rm -f "$links_bond/bond0"
}
run_links() {
  SYS_CLASS_NET="$links_fx" PROC_NET_BONDING="$links_bond" "$NET" "$@" 2>&1
}
write_clean_link
out="$(run_links)"; rc=$?
assert_eq "net_doctor with a clean link exits 0" "0" "$rc"
assert_contains "net_doctor has a links section" "$out" "== links =="
assert_contains "net_doctor reports the negotiated speed" "$out" "eth0 1000 Mb/s full duplex"
assert_contains "net_doctor reports a clean error count" "$out" "eth0: 0 errors or drops"
assert_not_contains "net_doctor does not grade a virtual interface" "$out" "veth0 has"
assert_contains "net_doctor counts the virtual interface instead" "$out" "1 virtual interface(s) not graded"

printf '5000\n' > "$links_fx/eth0/statistics/rx_errors"
printf '1000000\n' > "$links_fx/eth0/statistics/rx_packets"
out="$(run_links)"; rc=$?
assert_eq "net_doctor with link errors still exits 0" "0" "$rc"
assert_contains "net_doctor warns on errors past 0.1%" \
  "$(grep -F 'errors or drops' <<<"$out" || true)" "[warn]"
out="$(run_links --quiet)"
assert_contains "net_doctor --quiet keeps the link warning" "$out" "eth0 has 5000 RX/TX errors or drops"
if grep -q '\[ ok \]' <<<"$out"; then
  err "net_doctor --quiet still printed [ ok ] lines with links"
else
  ok "net_doctor --quiet drops the healthy link lines"
fi

write_clean_link
printf '50\n' > "$links_fx/eth0/statistics/rx_errors"
printf '100\n' > "$links_fx/eth0/statistics/rx_packets"
printf '0\n' > "$links_fx/eth0/statistics/tx_packets"
out="$(run_links)"
assert_not_contains "net_doctor ignores a handful of errors below the floor" "$out" "eth0 has 50 RX/TX errors"

write_clean_link
printf 'half\n' > "$links_fx/eth0/duplex"
out="$(run_links)"
assert_contains "net_doctor warns on half duplex" "$out" "half duplex on eth0"
write_clean_link
printf '100\n' > "$links_fx/eth0/speed"
out="$(run_links)"
assert_contains "net_doctor warns on a 100 Mb/s link" "$out" "eth0 negotiated 100 Mb/s"
write_clean_link
printf '25\n' > "$links_fx/eth0/carrier_changes"
out="$(run_links)"
assert_contains "net_doctor warns on carrier flaps" "$out" "eth0 carrier changed 25 times"

write_clean_link
printf '%s\n' 'Bonding Mode: fault-tolerance (active-backup)' 'Currently Active Slave: eth0' 'MII Status: up' '' \
  'Slave Interface: eth0' 'MII Status: up' '' 'Slave Interface: eth1' 'MII Status: down' > "$links_bond/bond0"
out="$(run_links)"
assert_contains "net_doctor warns on a bond slave that is down" "$out" "bond0 slave eth1 is down"

write_clean_link
out="$(run_links --skip-links)"
assert_not_contains "net_doctor --skip-links leaves the section out" "$out" "eth0 1000 Mb/s"
assert_contains "net_doctor --skip-links says so" "$out" "(--skip-links)"

# The gateway's neighbour state needs ip, which the tester images lack: a stub
# answers the default route and the neighbour lookup, and nothing else.
links_stub="$(mktemp -d)"
cat > "$links_stub/ip" <<'STUB'
#!/usr/bin/env bash
state="FAILED"
[[ -e "${0%/*}/reachable" ]] && state="REACHABLE"
case " $* " in
  *" -4 route show default "*) printf 'default via 10.0.0.1 dev eth0 proto dhcp metric 100\n' ;;
  *" neigh show to 10.0.0.1 dev eth0 "*) printf '10.0.0.1 lladdr aa:bb:cc:dd:ee:ff %s\n' "$state" ;;
esac
exit 0
STUB
chmod +x "$links_stub/ip"
out="$(PATH="$links_stub:$PATH" run_links)"; rc=$?
assert_eq "net_doctor with an unanswered gateway exits 0" "0" "$rc"
assert_contains "net_doctor warns when the gateway does not answer ARP" "$out" "default gateway 10.0.0.1 does not answer ARP"
: > "$links_stub/reachable"
out="$(PATH="$links_stub:$PATH" run_links)"
assert_contains "net_doctor passes a reachable gateway" "$out" "gateway 10.0.0.1 neighbour state REACHABLE"
rm -rf "$links_fx" "$links_bond" "$links_stub"

section "listen_audit.sh"
LISTEN="$L/listen_audit.sh"
# The tester images have no iproute2, so ss is a stub ahead of PATH printing a
# real `ss -tulnp` header and rows: sshd on both stacks (one row once folded),
# nginx on [::], postgres and a resolver stub on loopback, and a python3 that
# nobody expected.
listen_stub="$(mktemp -d)"
cat > "$listen_stub/ss" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process'
printf '%s\n' 'tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=1,fd=3))'
printf '%s\n' 'tcp   LISTEN 0      128             [::]:22            [::]:*     users:(("sshd",pid=1,fd=4))'
printf '%s\n' 'tcp   LISTEN 0      511             [::]:443           [::]:*     users:(("nginx",pid=2,fd=6))'
printf '%s\n' 'tcp   LISTEN 0      4096       127.0.0.1:5432       0.0.0.0:*     users:(("postgres",pid=3,fd=5))'
printf '%s\n' 'udp   UNCONN 0      0      127.0.0.53%lo:53         0.0.0.0:*'
printf '%s\n' 'tcp   LISTEN 0      5            0.0.0.0:9000       0.0.0.0:*     users:(("python3",pid=4,fd=3))'
STUB
chmod +x "$listen_stub/ss"
scratch_home="$(mktemp -d)"
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" PATH="$listen_stub:$PATH" "$LISTEN" 2>&1)"; rc=$?
assert_eq "listen_audit without a baseline is a report and exits 0" "0" "$rc"
assert_contains "listen_audit names the sshd owner" "$out" "sshd"
assert_contains "listen_audit names the nginx owner" "$out" "nginx"
assert_contains "listen_audit lists the loopback postgres port" "$out" "5432"
assert_contains "listen_audit marks loopback scope" "$out" "loopback"
assert_contains "listen_audit counts public and loopback listeners" "$out" "5 listener(s): 3 public, 2 loopback"
out="$(PATH="$listen_stub:$PATH" "$LISTEN" --public-only 2>&1)"
assert_not_contains "listen_audit --public-only hides loopback rows" "$out" "5432"

out="$(HOME="$scratch_home" TMPDIR="$scratch_home" PATH="$listen_stub:$PATH" "$LISTEN" --print 2>&1)"; rc=$?
assert_eq "listen_audit --print exits 0" "0" "$rc"
assert_contains "listen_audit --print writes sshd as proto/port/process" "$out" "tcp/22/sshd"
assert_contains "listen_audit --print writes nginx as proto/port/process" "$out" "tcp/443/nginx"
assert_not_contains "listen_audit --print carries no pids" "$out" "pid="
assert_not_contains "listen_audit --print leaves loopback out" "$out" "5432"
assert_not_contains "listen_audit --print carries no date" "$out" "$(date +%Y)"
assert_eq "listen_audit folds the IPv4/IPv6 sshd twins" "1" "$(grep -c '^tcp/22/sshd$' <<<"$out")"
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "listen_audit wrote nothing, --print included"
else
  err "listen_audit wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home"

listen_base="$(mktemp -d)"
printf '# expected\ntcp/22/sshd\n\ntcp/443/nginx\ntcp/3000/node  # gone\n' > "$listen_base/drifted"
out="$(PATH="$listen_stub:$PATH" "$LISTEN" --baseline "$listen_base/drifted" 2>&1)"; rc=$?
assert_eq "listen_audit fails on a listener the baseline lacks" "1" "$rc"
assert_contains "listen_audit names the new listener" "$out" "NEW listener tcp/9000"
assert_contains "listen_audit warns on an expected listener that is gone" "$out" "expected listener tcp/3000"

# Gone alone is a warning: the default --fail-on new passes it, any does not.
printf 'tcp/22/sshd\ntcp/443/nginx\ntcp/9000/python3\ntcp/3000/node\n' > "$listen_base/gone-only"
PATH="$listen_stub:$PATH" "$LISTEN" --baseline "$listen_base/gone-only" >/dev/null 2>&1; rc=$?
assert_eq "listen_audit passes a gone listener under --fail-on new" "0" "$rc"
PATH="$listen_stub:$PATH" "$LISTEN" --baseline "$listen_base/gone-only" --fail-on any >/dev/null 2>&1; rc=$?
assert_eq "listen_audit --fail-on any fails on a gone listener" "1" "$rc"

printf 'tcp/22/sshd\ntcp/443/nginx\ntcp/9000/python3\n' > "$listen_base/matching"
PATH="$listen_stub:$PATH" "$LISTEN" --baseline "$listen_base/matching" --fail-on any >/dev/null 2>&1; rc=$?
assert_eq "listen_audit passes a matching baseline" "0" "$rc"
printf 'tcp/22/sshd\ntcp/443/*\ntcp/9000-9100/*\n' > "$listen_base/wildcard"
PATH="$listen_stub:$PATH" "$LISTEN" --baseline "$listen_base/wildcard" >/dev/null 2>&1; rc=$?
assert_eq "listen_audit matches * processes and port ranges" "0" "$rc"

# A public entry is not satisfied by the same port rebound to loopback.
rebind_stub="$(mktemp -d)"
cat > "$rebind_stub/ss" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process'
printf '%s\n' 'tcp   LISTEN 0      511        127.0.0.1:80         0.0.0.0:*     users:(("nginx",pid=2,fd=6))'
STUB
chmod +x "$rebind_stub/ss"
printf 'tcp/80/nginx\n' > "$listen_base/public80"
out="$(PATH="$rebind_stub:$PATH" "$LISTEN" --baseline "$listen_base/public80" --fail-on any 2>&1)"; rc=$?
assert_eq "listen_audit: a loopback rebind does not satisfy a public entry" "1" "$rc"
assert_contains "listen_audit reports the rebound entry as gone" "$out" "expected listener tcp/80"
PATH="$rebind_stub:$PATH" "$LISTEN" --baseline "$listen_base/public80" --all --fail-on any >/dev/null 2>&1; rc=$?
assert_eq "listen_audit --all lets the loopback listener satisfy the entry" "0" "$rc"
rm -rf "$rebind_stub"

PATH="$listen_stub:$PATH" "$LISTEN" --allow 22,443,9000 >/dev/null 2>&1; rc=$?
assert_eq "listen_audit --allow covering every public port -> 0" "0" "$rc"
PATH="$listen_stub:$PATH" "$LISTEN" --allow 22 >/dev/null 2>&1; rc=$?
assert_eq "listen_audit --allow missing ports -> 1" "1" "$rc"

for bad in "--baseline /nonexistent" "--allow 99999" "--allow abc" "--fail-on sometimes" "--bogus"; do
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  PATH="$listen_stub:$PATH" "$LISTEN" $bad >/dev/null 2>&1
  rc=$?
  assert_eq "listen_audit rejects $bad -> 3" "3" "$rc"
done
printf 'tcp/notaport/sshd\n' > "$listen_base/bad"
PATH="$listen_stub:$PATH" "$LISTEN" --baseline "$listen_base/bad" >/dev/null 2>&1; rc=$?
assert_eq "listen_audit rejects a baseline line with a bad port -> 3" "3" "$rc"

# No ss at all: a wrong environment, not a usage error, and --help still works.
listen_bin="$(mktemp -d)"
for tool in bash awk sort grep tr sed cat uname; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ "$tool_path" == /* ]] && ln -s "$tool_path" "$listen_bin/$tool"
done
PATH="$listen_bin" "$LISTEN" >/dev/null 2>&1; rc=$?
assert_eq "listen_audit without ss -> 2" "2" "$rc"
PATH="$listen_bin" "$LISTEN" --help >/dev/null 2>&1; rc=$?
assert_eq "listen_audit --help works without ss" "0" "$rc"
rm -rf "$listen_stub" "$listen_base" "$listen_bin"

section "log_triage.sh"
TRIAGE="$L/log_triage.sh"
scratch_home="$(mktemp -d)"
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$TRIAGE" 2>&1)"; rc=$?
assert_eq "log_triage exits 0 with almost nothing installed" "0" "$rc"
assert_contains "log_triage prints a summary" "$out" "== summary =="
assert_contains "log_triage has a kernel section" "$out" "== kernel =="
assert_contains "log_triage has an auth section" "$out" "== auth =="
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "log_triage wrote nothing"
else
  err "log_triage wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home"

out="$("$TRIAGE" --quiet 2>&1)"
if grep -q '\[ ok \]' <<<"$out"; then
  err "log_triage --quiet still printed [ ok ] lines"
else
  ok "log_triage --quiet drops the healthy lines"
fi
assert_contains "log_triage --quiet still summarises" "$out" "== summary =="

triage_sections="$("$TRIAGE" --list-sections)"
for s in kernel units auth repeats; do
  assert_contains "log_triage lists section $s" "$triage_sections" "$s"
done
for bad in "--only nosuch" "--top 0" "--top abc" "--fail-on sometimes" "--bogus"; do
  # shellcheck disable=SC2086  # the pair is meant to split into two arguments
  "$TRIAGE" $bad >/dev/null 2>&1
  rc=$?
  assert_eq "log_triage rejects $bad -> 3" "3" "$rc"
done
"$TRIAGE" --only , >/dev/null 2>&1; rc=$?
assert_eq "log_triage --only empty selection -> 4" "4" "$rc"
# --since is passed to journalctl, so anything that could be read as one of its
# options, or that a shell would expand, is refused before a journal is read.
"$TRIAGE" --since '-n 5' >/dev/null 2>&1; rc=$?
assert_eq "log_triage refuses a --since that starts with a dash -> 3" "3" "$rc"
# shellcheck disable=SC2016  # the literal $(id) is the point
"$TRIAGE" --since '$(id)' >/dev/null 2>&1; rc=$?
assert_eq "log_triage refuses a --since with shell syntax -> 3" "3" "$rc"

# A container has no journal, so the parsers would never see a line. A stub
# journalctl ahead of PATH answers each read with fixture lines in the real
# `-o short` shape and records its argv, which is also how the run is proved
# read-only: nothing but reads ever reaches it.
triage_stub="$(mktemp -d)"
cat > "$triage_stub/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${0%/*}/argv.log"
case " $* " in
  *" -k "*)
    printf 'Oct 21 10:00:00 host kernel: Out of memory: Killed process 42 (java)\n'
    printf 'Oct 21 10:00:01 host kernel: EXT4-fs error (device sda1): ext4_find_entry: reading directory\n'
    ;;
  *" -p "*)
    i=0
    while (( i < 60 )); do
      printf 'Oct 21 10:00:02 host nginx[1]: upstream timed out\n'
      i=$((i + 1))
    done
    for n in 17 18 19; do
      printf 'Oct 21 10:00:03 host app[2]: boom %s\n' "$n"
    done
    ;;
  *" -u ssh "*)
    i=0
    while (( i < 30 )); do
      printf 'Oct 21 10:00:04 host sshd[9]: Failed password for invalid user admin from 203.0.113.9 port 4242 ssh2\n'
      i=$((i + 1))
    done
    ;;
esac
exit 0
STUB
chmod +x "$triage_stub/journalctl"
out="$(PATH="$triage_stub:$PATH" AUTH_LOG=/nonexistent "$TRIAGE" 2>&1)"; rc=$?
assert_eq "log_triage with findings still exits 0 by default" "0" "$rc"
assert_contains "log_triage counts OOM kernel messages" "$out" "OOM message(s)"
assert_contains "log_triage counts filesystem kernel messages" "$out" "filesystem message(s)"
assert_contains "log_triage ranks the noisiest identifier" "$out" "nginx"
assert_contains "log_triage warns on an identifier past 50 error lines" "$out" "nginx logged 60 error line(s)"
assert_contains "log_triage folds numbers in repeated messages" "$out" "boom N"
assert_contains "log_triage groups failed logins by source" "$out" "203.0.113.9"
assert_contains "log_triage names invalid users, not whole lines" "$out" "admin"
assert_contains "log_triage warns on brute force" "$out" "[warn]"
PATH="$triage_stub:$PATH" AUTH_LOG=/nonexistent "$TRIAGE" --fail-on warn >/dev/null 2>&1; rc=$?
assert_eq "log_triage --fail-on warn exits 1 on findings" "1" "$rc"
out="$(PATH="$triage_stub:$PATH" AUTH_LOG=/nonexistent "$TRIAGE" --only auth 2>&1)"
assert_not_contains "log_triage --only auth leaves the kernel out" "$out" "== kernel =="
argv_log="$(cat "$triage_stub/argv.log" 2>/dev/null || true)"
assert_contains "log_triage read the kernel log through journalctl" "$argv_log" "-k"
if grep -qE -- '--vacuum|--rotate|--flush|--sync|--relinquish' <<<"$argv_log"; then
  err "log_triage passed a journal-changing option to journalctl"
else
  ok "log_triage only ever reads the journal"
fi

# The file-only path: no journalctl on PATH at all, and the auth log named in
# AUTH_LOG. The PATH holds only the tools the script reads with, so a
# journalctl on the image cannot answer instead.
triage_bin="$(mktemp -d)"
for tool in bash awk sort uniq grep head tr sed date cat uname id wc; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ "$tool_path" == /* ]] && ln -s "$tool_path" "$triage_bin/$tool"
done
triage_log="$triage_stub/auth.log"
i=0
while (( i < 12 )); do
  printf 'Oct 21 10:00:05 host sshd[9]: Failed password for root from 198.51.100.7 port 5555 ssh2\n' >> "$triage_log"
  i=$((i + 1))
done
printf 'Oct 21 10:00:06 host sshd[9]: Accepted publickey for ops from 192.0.2.1 port 22 ssh2\n' >> "$triage_log"
out="$(PATH="$triage_bin" AUTH_LOG="$triage_log" "$TRIAGE" 2>&1)"; rc=$?
assert_eq "log_triage with only an auth log exits 0" "0" "$rc"
assert_contains "log_triage reads the named auth log" "$out" "auth.log"
assert_contains "log_triage ranks the auth log's sources" "$out" "198.51.100.7"
assert_contains "log_triage warns at ten failures from one source" "$out" "[warn]"
assert_contains "log_triage counts accepted logins" "$out" "1 accepted SSH login(s)"
assert_contains "log_triage skips the kernel without a journal or dmesg" "$out" "neither journalctl nor dmesg"

# A journalctl that rejects the read (the probe, which has no --since, still
# answers) must not turn into "no failed logins": the auth section warns that
# the source is unreadable and does not claim zero.
printf '#!/usr/bin/env bash\ncase " $* " in *" --since "*) exit 1 ;; esac\nexit 0\n' > "$triage_stub/journalctl"
out="$(PATH="$triage_stub:$PATH" AUTH_LOG=/nonexistent "$TRIAGE" --only auth 2>&1)"; rc=$?
if grep -q 'journal not readable' <<<"$out"; then
  ok "log_triage failing-journalctl auth test skipped (journal not readable for this user)"
else
  assert_contains "log_triage warns when journalctl fails on the auth read" "$out" "journalctl failed reading auth lines"
  assert_not_contains "log_triage does not claim zero failed logins on a failed read" "$out" "no failed SSH logins"
  assert_not_contains "log_triage does not claim zero failed sudo on a failed read" "$out" "no failed sudo"
  assert_eq "log_triage failed journal read exits 0 by default" "0" "$rc"
  PATH="$triage_stub:$PATH" AUTH_LOG=/nonexistent "$TRIAGE" --only auth --fail-on warn >/dev/null 2>&1; rc=$?
  assert_eq "log_triage --fail-on warn exits 1 on a failed journal read" "1" "$rc"
fi
rm -rf "$triage_stub" "$triage_bin"

section "schedule_report.sh"
SCHED="$L/schedule_report.sh"
scratch_home="$(mktemp -d)"
out="$(HOME="$scratch_home" TMPDIR="$scratch_home" "$SCHED" 2>&1)"; rc=$?
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

section "sysctl_defaults.sh"
SYSCTL="$L/sysctl_defaults.sh"
out="$("$SYSCTL" --list-groups 2>&1)"; rc=$?
assert_eq "sysctl_defaults --list-groups exits 0" "0" "$rc"
assert_contains "sysctl_defaults lists inotify" "$out" "inotify"
assert_contains "sysctl_defaults lists vm" "$out" "vm"

out="$("$SYSCTL" --only nosuchgroup 2>&1)"; rc=$?
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

out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --only inotify 2>&1
)"; rc=$?
assert_eq "sysctl_defaults report exits 0" "0" "$rc"
assert_contains "sysctl_defaults reports the current watch count" "$out" "8192"
assert_contains "sysctl_defaults names the desired watch count" "$out" "524288"

out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --apply --dry-run --only inotify --backup-file "$sysctl_root/tmp/backup.txt" 2>&1
)"; rc=$?
assert_eq "sysctl_defaults --apply --dry-run exits 0" "0" "$rc"
assert_contains "sysctl_defaults dry-run names the drop-in" "$out" "99-ops-toolbox.conf"
if [[ -e "$sysctl_root/sysctl.d/99-ops-toolbox.conf" || -e "$sysctl_root/tmp/backup.txt" ]]; then
  err "sysctl_defaults --dry-run wrote a drop-in or backup"
else
  ok "sysctl_defaults --apply --dry-run wrote nothing"
fi

out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --apply --only inotify --backup-file "$sysctl_root/tmp/backup.txt" 2>&1
)"; rc=$?
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

out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert --revert-from "$sysctl_root/tmp/backup.txt" 2>&1
)"; rc=$?
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
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert 2>&1
)"; rc=$?
assert_eq "sysctl_defaults --revert ignores a world-writable backup" "3" "$rc"

# Even from a file the caller owns, a key outside the managed table is data,
# not an instruction.
chmod 600 "$planted"
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert --revert-from "$planted" 2>&1
)"; rc=$?
assert_contains "sysctl_defaults --revert skips an unmanaged key" \
  "$out" "not a key this script manages"

# PROC_SYS exists so the suite can drive apply/revert without retuning the host.
# write_live used to fall back to sysctl(8) whenever the fixture file was not
# writable, which addresses the real kernel and walks straight out of the sandbox.
rm -f "$sysctl_root/proc/fs/inotify/max_user_watches"
printf 'fs.inotify.max_user_watches=8192\n' > "$sysctl_root/tmp/sandbox.txt"
chmod 600 "$sysctl_root/tmp/sandbox.txt"
out="$(
  SYSCTL_D="$sysctl_root/sysctl.d" PROC_SYS="$sysctl_root/proc" TMPDIR="$sysctl_root/tmp" \
    "$SYSCTL" --revert --revert-from "$sysctl_root/tmp/sandbox.txt" 2>&1
)"; rc=$?
assert_contains "sysctl_defaults refuses sysctl(8) under a PROC_SYS override" \
  "$out" "refusing 'sysctl -w"

rm -rf "$sysctl_root"

section "tls_expiry.sh"
TLS="$L/tls_expiry.sh"
"$TLS" >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry without --file or --host -> 3" "3" "$rc"

"$TLS" --days notanumber --file /dev/null >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry rejects --days notanumber -> 3" "3" "$rc"

"$TLS" --fail-on nope --file /dev/null >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry rejects --fail-on nope -> 3" "3" "$rc"

"$TLS" --file --days 7 >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry --file rejects the next flag as a path -> 3" "3" "$rc"

# The --deep family's usage errors, like the ones above, are answered before
# the openssl preflight, so they hold on an image without openssl.
"$TLS" --hosts-file /nonexistent >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry rejects an unreadable --hosts-file -> 3" "3" "$rc"
"$TLS" --hosts-file >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry --hosts-file without a value -> 3" "3" "$rc"
"$TLS" --min-key-bits 12 --file /dev/null >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry rejects --min-key-bits 12 -> 3" "3" "$rc"
"$TLS" --check-host --file /dev/null >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry --check-host without a value -> 3" "3" "$rc"
"$TLS" --deep >/dev/null 2>&1; rc=$?
assert_eq "tls_expiry --deep with no target -> 3" "3" "$rc"

# openssl is not in the tester image on purpose (see tester/Dockerfile): a
# missing binary must be exit 2, not a crash, and --help already ran above.
if ! command -v openssl >/dev/null 2>&1; then
  PATH="/usr/bin:/bin" "$TLS" --file /dev/null >/dev/null 2>&1; rc=$?
  assert_eq "tls_expiry without openssl -> 2" "2" "$rc"
  ok "tls_expiry PEM checks skipped (openssl not installed)"
else
  expired="$L/tests/fixtures/expired.pem"
  out="$("$TLS" --file "$expired" 2>&1)"; rc=$?
  assert_eq "tls_expiry expired fixture -> 1" "1" "$rc"
  assert_contains "tls_expiry names the expired leaf" "$out" "expired"
  assert_contains "tls_expiry prints a summary" "$out" "== summary =="

  out="$("$TLS" --file "$expired" --fail-on never 2>&1)"; rc=$?
  assert_eq "tls_expiry --fail-on never stays 0" "0" "$rc"

  soon="$(mktemp --suffix=.pem)"
  soon_key="$(mktemp)"
  openssl req -x509 -newkey rsa:2048 -keyout "$soon_key" -out "$soon" -days 7 -nodes -subj "/CN=soon.test" >/dev/null 2>&1
  rm -f "$soon_key"
  out="$("$TLS" --file "$soon" --days 30 --fail-on expired 2>&1)"; rc=$?
  assert_eq "tls_expiry soon-to-expire is warn not fail" "0" "$rc"
  assert_contains "tls_expiry warns inside the window" "$out" "[warn]"
  "$TLS" --file "$soon" --days 30 --fail-on warn >/dev/null 2>&1; rc=$?
  assert_eq "tls_expiry --fail-on warn exits 1 inside the window" "1" "$rc"

  valid="$(mktemp --suffix=.pem)"
  valid_key="$(mktemp)"
  openssl req -x509 -newkey rsa:2048 -keyout "$valid_key" -out "$valid" -days 3650 -nodes -subj "/CN=valid.test" >/dev/null 2>&1
  rm -f "$valid_key"
  out="$("$TLS" --file "$valid" --days 30 2>&1)"; rc=$?
  assert_eq "tls_expiry long-lived cert exits 0" "0" "$rc"
  assert_contains "tls_expiry passes a long-lived cert" "$out" "[pass]"

  globdir="$(mktemp -d)"
  cp "$expired" "$globdir/a.pem"
  cp "$expired" "$globdir/b.pem"
  out="$("$TLS" --file "$globdir/*.pem" --fail-on never 2>&1)"; rc=$?
  assert_eq "tls_expiry quoted glob exits 0 with --fail-on never" "0" "$rc"
  assert_contains "tls_expiry glob expands a.pem" "$out" "a.pem"
  assert_contains "tls_expiry glob expands b.pem" "$out" "b.pem"
  rm -rf "$globdir"

  # --check-host against a SAN. -addext needs OpenSSL 1.1.1; an older one
  # cannot build the fixture, which is said rather than passed silently.
  san="$(mktemp --suffix=.pem)"
  san_key="$(mktemp)"
  if openssl req -x509 -newkey rsa:2048 -keyout "$san_key" -out "$san" -days 3650 -nodes \
       -subj "/CN=san.test" -addext "subjectAltName=DNS:valid.test" >/dev/null 2>&1; then
    out="$("$TLS" --file "$san" --check-host valid.test 2>&1)"; rc=$?
    assert_eq "tls_expiry --check-host on a covered name exits 0" "0" "$rc"
    assert_contains "tls_expiry says the certificate covers the name" "$out" "covers valid.test"
    out="$("$TLS" --file "$san" --check-host other.test 2>&1)"; rc=$?
    assert_eq "tls_expiry --check-host on another name exits 1" "1" "$rc"
    assert_contains "tls_expiry says the certificate does not cover it" "$out" "does not cover other.test"
  else
    ok "tls_expiry --check-host skipped (openssl too old for -addext)"
  fi
  rm -f "$san" "$san_key"

  # The fixtures above are self-signed, which --deep reports as a warning:
  # a default run still passes, --fail-on warn does not.
  out="$("$TLS" --file "$valid" --deep 2>&1)"; rc=$?
  assert_eq "tls_expiry --deep on a self-signed leaf exits 0 by default" "0" "$rc"
  assert_contains "tls_expiry --deep warns on a self-signed leaf" \
    "$(grep -F 'self-signed' <<<"$out" || true)" "[warn]"
  assert_contains "tls_expiry --deep grades key strength" "$out" "strength: 2048 bit RSA"
  "$TLS" --file "$valid" --deep --fail-on warn >/dev/null 2>&1; rc=$?
  assert_eq "tls_expiry --deep --fail-on warn exits 1 on a self-signed leaf" "1" "$rc"

  # Some crypto policies refuse to make a 1024-bit key at all; that is a
  # skipped fixture, not a failed check.
  weak="$(mktemp --suffix=.pem)"
  weak_key="$(mktemp)"
  if openssl req -x509 -newkey rsa:1024 -keyout "$weak_key" -out "$weak" -days 3650 -nodes \
       -subj "/CN=weak.test" >/dev/null 2>&1 && [[ -s "$weak" ]]; then
    out="$("$TLS" --file "$weak" --deep 2>&1)"; rc=$?
    assert_eq "tls_expiry --deep fails a 1024-bit key" "1" "$rc"
    assert_contains "tls_expiry names the key-size minimum" "$out" "minimum 2048"
    "$TLS" --file "$weak" --deep --min-key-bits 1024 >/dev/null 2>&1; rc=$?
    assert_eq "tls_expiry --min-key-bits 1024 accepts it" "0" "$rc"
  else
    ok "tls_expiry weak-key check skipped (this openssl refuses rsa:1024)"
  fi
  rm -f "$weak" "$weak_key"

  # A hosts file: a comment and a blank line are not targets, and the one real
  # entry is a closed port, so exactly one host is tried and warned about.
  hosts_dir="$(mktemp -d)"
  printf '# endpoints\n\nlocalhost:1\n' > "$hosts_dir/hosts"
  out="$("$TLS" --hosts-file "$hosts_dir/hosts" 2>&1)"; rc=$?
  assert_eq "tls_expiry --hosts-file with an unreachable host exits 0" "0" "$rc"
  assert_contains "tls_expiry reads the hosts file entry" "$out" "localhost:1"
  assert_contains "tls_expiry warns on an unreachable host" "$out" "could not fetch a leaf certificate"
  assert_eq "tls_expiry tries exactly one target from the hosts file" "1" "$(grep -c '\[warn\]' <<<"$out")"
  rm -rf "$hosts_dir"

  "$TLS" --cafile /nonexistent --host localhost:1 >/dev/null 2>&1; rc=$?
  assert_eq "tls_expiry rejects an unreadable --cafile -> 3" "3" "$rc"

  # Verify codes 20 and 21 are ambiguous: a missing intermediate and a private
  # root this machine does not have look the same to s_client. A stub openssl
  # answers s_client with a canned handshake (and hands everything else to the
  # real one); the chain is a private root, an intermediate and a leaf.
  chain_dir="$(mktemp -d)"
  chain_real="$(command -v openssl)"
  if (
    cd "$chain_dir" || exit 1
    printf 'basicConstraints=CA:TRUE\n' > ca.ext
    printf 'subjectAltName=DNS:leaf.test\n' > leaf.ext
    openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.pem -days 3650 -subj "/CN=Chain Root" &&
    openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj "/CN=Chain Intermediate" &&
    openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -days 3650 -extfile ca.ext -out int.pem &&
    openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=leaf.test" &&
    openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial -days 3650 -extfile leaf.ext -out leaf.pem
  ) >/dev/null 2>&1 && [[ -s "$chain_dir/leaf.pem" ]]; then
    mkdir -p "$chain_dir/bin"
    cat > "$chain_dir/bin/openssl" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == s_client ]]; then
  cat "$chain_dir/handshake"
  exit 0
fi
exec "$chain_real" "\$@"
STUB
    chmod +x "$chain_dir/bin/openssl"

    # Only the leaf was sent and its issuer is not in the store: provable.
    { cat "$chain_dir/leaf.pem"; printf 'Verify return code: 21 (unable to verify the first certificate)\n'; } > "$chain_dir/handshake"
    out="$(PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep 2>&1)"; rc=$?
    assert_contains "tls_expiry fails a chain with no CA certificate sent" "$out" "incomplete chain"
    assert_contains "tls_expiry suggests fullchain.pem for it" "$out" "fullchain.pem"
    assert_eq "tls_expiry --deep fails a provably incomplete chain -> 1" "1" "$rc"

    # The intermediate was sent; what is absent is the private root. That is a
    # trust problem on this machine, not a missing intermediate.
    { cat "$chain_dir/leaf.pem" "$chain_dir/int.pem"; printf 'Verify return code: 20 (unable to get local issuer certificate)\n'; } > "$chain_dir/handshake"
    out="$(PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep 2>&1)"; rc=$?
    assert_contains "tls_expiry reports an untrusted issuer neutrally" "$out" "issuer not trusted locally: private CA or missing intermediate"
    assert_contains "tls_expiry suggests --cafile for it" "$out" "--cafile"
    assert_not_contains "tls_expiry does not claim a missing intermediate for it" "$out" "incomplete chain"
    assert_not_contains "tls_expiry does not suggest fullchain.pem for it" "$out" "fullchain.pem"
    assert_eq "tls_expiry --deep with an untrusted private root exits 0" "0" "$rc"
    PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep --fail-on warn >/dev/null 2>&1; rc=$?
    assert_eq "tls_expiry --deep --fail-on warn exits 1 for it" "1" "$rc"

    # --cafile means the private root replaces system trust. A recording stub
    # lists the -no-CApath/-no-CAstore options in its help (or not), so what
    # reaches s_client and verify, and what the output admits, is asserted.
    cat > "$chain_dir/bin/openssl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$chain_dir/argv.log"
case "\${1:-} \${2:-}" in
  "s_client -help"|"verify -help") cat "$chain_dir/help"; exit 1 ;;
esac
[[ "\${1:-}" == version ]] && { cat "$chain_dir/version"; exit 0; }
if [[ "\${1:-}" == s_client ]]; then
  cat "$chain_dir/handshake"
  exit 0
fi
exec "$chain_real" "\$@"
STUB
    chmod +x "$chain_dir/bin/openssl"
    # Leaf only: the probe (openssl verify) runs only when the last certificate
    # sent is not a CA, so the verify arguments can be asserted.
    { cat "$chain_dir/leaf.pem"; printf 'Verify return code: 21 (unable to verify the first certificate)\n'; } > "$chain_dir/handshake"

    printf 'OpenSSL 3.0.13 30 Jan 2024\n' > "$chain_dir/version"
    printf 'usage: -CAfile -no-CApath -no-CAstore -no-CAfile\n' > "$chain_dir/help"
    : > "$chain_dir/argv.log"
    out="$(PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep --cafile "$chain_dir/root.pem" 2>&1)"
    assert_contains "tls_expiry --cafile drops system dirs for s_client" \
      "$(grep '^s_client' "$chain_dir/argv.log")" "-CAfile $chain_dir/root.pem -no-CApath -no-CAstore"
    assert_contains "tls_expiry --cafile drops system dirs for verify too" \
      "$(grep '^verify -CAfile' "$chain_dir/argv.log")" "-CAfile $chain_dir/root.pem -no-CApath -no-CAstore"
    assert_not_contains "tls_expiry --cafile says nothing of system trust when it can drop it" "$out" "system trust sources may still apply"

    printf 'OpenSSL 3.0.13 30 Jan 2024\n' > "$chain_dir/version"
    printf 'usage: -CAfile -no-CApath\n' > "$chain_dir/help"
    out="$(PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep --cafile "$chain_dir/root.pem" 2>&1)"
    assert_contains "tls_expiry --cafile admits system trust may apply on 3.x without -no-CAstore" \
      "$out" "system trust sources may still apply"

    printf 'OpenSSL 1.1.1w  11 Sep 2023\n' > "$chain_dir/version"
    printf 'usage: -CAfile -no-CApath\n' > "$chain_dir/help"
    : > "$chain_dir/argv.log"
    out="$(PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep --cafile "$chain_dir/root.pem" 2>&1)"
    assert_not_contains "tls_expiry --cafile needs no -no-CAstore on a build without stores" "$out" "system trust sources may still apply"
    assert_not_contains "tls_expiry --cafile does not pass an option the build lacks" \
      "$(grep '^s_client' "$chain_dir/argv.log")" "-no-CAstore"
    assert_contains "tls_expiry --cafile still drops the directory for verify without stores" \
      "$(grep '^verify -CAfile' "$chain_dir/argv.log")" "-no-CApath"
    assert_not_contains "tls_expiry --cafile does not pass verify an option the build lacks" \
      "$(grep '^verify -CAfile' "$chain_dir/argv.log")" "-no-CAstore"

    printf 'OpenSSL 1.0.2k-fips  26 Jan 2017\n' > "$chain_dir/version"
    printf 'usage: -CAfile\n' > "$chain_dir/help"
    : > "$chain_dir/argv.log"
    out="$(PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep --cafile "$chain_dir/root.pem" 2>&1)"
    assert_contains "tls_expiry --cafile admits system trust may apply without -no-CApath" "$out" "system trust sources may still apply"
    assert_not_contains "tls_expiry --cafile passes no unsupported option" \
      "$(grep '^s_client' "$chain_dir/argv.log")" "-no-CApath"

    # Without --cafile nothing is probed or added.
    : > "$chain_dir/argv.log"
    PATH="$chain_dir/bin:$PATH" "$TLS" --host leaf.test --deep >/dev/null 2>&1
    assert_not_contains "tls_expiry without --cafile adds no trust options" "$(cat "$chain_dir/argv.log")" "-no-CA"
  else
    ok "tls_expiry chain checks skipped (this openssl cannot build the fixture chain)"
  fi
  rm -rf "$chain_dir"

  scratch_home="$(mktemp -d)"
  HOME="$scratch_home" TMPDIR="$scratch_home" "$TLS" --file "$valid" >/dev/null 2>&1
  if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
    ok "tls_expiry wrote nothing"
  else
    err "tls_expiry wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
  fi
  rm -rf "$scratch_home" "$soon" "$valid"
fi

section "config_backup.sh"
BACKUP="$L/config_backup.sh"
"$BACKUP" >/dev/null 2>&1; rc=$?
assert_eq "config_backup without --yes -> 3" "3" "$rc"

"$BACKUP" --yes --paths / >/dev/null 2>&1; rc=$?
assert_eq "config_backup refuses to archive / -> 3" "3" "$rc"

# As with disk_cleanup, the literal '/' was the only spelling checked here, and
# every one of these reaches the same directory — with tar pointed at --dest.
for backup_root in '//' '/.' '/../' '/etc/..'; do
  "$BACKUP" --yes --paths "$backup_root" --dest /tmp >/dev/null 2>&1; rc=$?
  assert_eq "config_backup refuses --paths $backup_root -> 3" "3" "$rc"
done

"$BACKUP" --yes --paths relative/path --dest /tmp >/dev/null 2>&1; rc=$?
assert_eq "config_backup rejects a relative path -> 3" "3" "$rc"

src="$(mktemp -d)"
dest="$(mktemp -d)"
printf 'keep-me\n' > "$src/payload.txt"
mkdir -p "$src/nested"
printf 'also\n' > "$src/nested/file.txt"

out="$("$BACKUP" --dry-run --paths "$src" --dest "$dest" 2>&1)"; rc=$?
assert_eq "config_backup --dry-run exits 0" "0" "$rc"
assert_contains "config_backup dry-run names the archive" "$out" "would write"
assert_contains "config_backup dry-run reports no changes" "$out" "dry-run complete; no changes written"
if [[ -z "$(ls -A "$dest" 2>/dev/null)" ]]; then
  ok "config_backup --dry-run wrote nothing"
else
  err "config_backup --dry-run wrote into dest: $(ls -A "$dest" | tr '\n' ' ')"
fi

out="$("$BACKUP" --yes --paths "$src" --dest "$dest" --keep 2 2>&1)"; rc=$?
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

# The default --paths is /etc and the script expects to be run privileged — it
# treats tar's exit 1 as "unreadable files under /etc, archive still written".
# Nothing here set a mode, so under the stock 022 umask tar created the archive
# 0644 and `sudo ./config_backup.sh --yes` left shadow, the sshd host keys and
# sudoers in a tarball every local account could read. The umask is forced in
# the subshell so the assertion is about the script rather than about whatever
# the suite happened to inherit, and a separate --prefix keeps this archive out
# of the rotation counted below.
mode_dest="$(mktemp -d)"
( umask 022; "$BACKUP" --yes --paths "$src" --dest "$mode_dest" --prefix modecheck >/dev/null 2>&1 )
mode_archive="$(ls -1 "$mode_dest"/modecheck-*.tar.gz 2>/dev/null | head -n 1)"
assert_eq "config_backup writes the archive mode 600" "600" \
  "$(stat -c '%a' "$mode_archive" 2>/dev/null || printf 'no-archive')"
rm -rf "$mode_dest"

out="$("$BACKUP" --list --dest "$dest" 2>&1)"; rc=$?
assert_eq "config_backup --list exits 0" "0" "$rc"
assert_contains "config_backup --list shows the payload" "$out" "payload.txt"

empty_dest="$(mktemp -d)"
"$BACKUP" --list --dest "$empty_dest" >/dev/null 2>&1; rc=$?
assert_eq "config_backup --list with no archives -> 3" "3" "$rc"
rmdir "$empty_dest"

# Second write, then a third with --keep 1, must leave a single archive.
sleep 1
"$BACKUP" --yes --paths "$src" --dest "$dest" --keep 2 >/dev/null 2>&1 || err "config_backup --keep 2 exited $? — the retention count below would be met by the first archive alone"
sleep 1
"$BACKUP" --yes --paths "$src" --dest "$dest" --keep 1 >/dev/null 2>&1 || err "config_backup --keep 1 exited $? — the retention count below would be met by the first archive alone"
left="$(ls -1 "$dest"/config-*.tar.gz 2>/dev/null | grep -c . || true)"
assert_eq "config_backup --keep 1 retains one archive" "1" "$left"
rm -rf "$src" "$dest"

bash "$L/tests/test_config_backup.sh"
assert_eq "config_backup publication regression suite exits 0" "0" "$?"

section "ssh_client_doctor.sh"
SSHDOC="$L/ssh_client_doctor.sh"
missing_dir="$(mktemp -d)"
rmdir "$missing_dir"
out="$("$SSHDOC" --ssh-dir "$missing_dir" 2>&1)"; rc=$?
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

out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
assert_eq "ssh_client_doctor clean dir with missing IdentityFile -> 0 (warn only)" "0" "$rc"
assert_contains "ssh_client_doctor passes 700 on the directory" "$out" "mode 700"

# The only config fixture above is 600, which passed under both the old
# enumeration (group/other in 0|4) and the write-bit rule that replaced it — so
# neither spelling of the check was actually covered. OpenSSH objects to these
# files being writable by group or other, not readable: 755 grants no write and
# must pass, 660 does and must not.
chmod 755 "$good/config"
out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
assert_eq "ssh_client_doctor accepts config mode 755 (no group/other write)" "0" "$rc"
assert_contains "ssh_client_doctor names the accepted mode" "$out" "config mode 755"

chmod 660 "$good/config"
out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
assert_eq "ssh_client_doctor rejects config mode 660 (group write) -> 1" "1" "$rc"
chmod 600 "$good/config"
assert_contains "ssh_client_doctor warns on a missing IdentityFile" "$out" "missing-key"

"$SSHDOC" --ssh-dir "$good" --fail-on warn >/dev/null 2>&1; rc=$?
assert_eq "ssh_client_doctor --fail-on warn exits 1 for missing IdentityFile" "1" "$rc"

chmod 644 "$good/id_ed25519"
out="$("$SSHDOC" --ssh-dir "$good" 2>&1)"; rc=$?
assert_eq "ssh_client_doctor world-readable private key -> 1" "1" "$rc"
assert_contains "ssh_client_doctor fails a 644 private key" "$out" "id_ed25519 mode 644"

scratch_home="$(mktemp -d)"
HOME="$scratch_home" TMPDIR="$scratch_home" "$SSHDOC" --ssh-dir "$good" >/dev/null 2>&1
if [[ -z "$(ls -A "$scratch_home" 2>/dev/null)" ]]; then
  ok "ssh_client_doctor wrote nothing"
else
  err "ssh_client_doctor wrote into HOME/TMPDIR: $(ls -A "$scratch_home" | tr '\n' ' ')"
fi
rm -rf "$scratch_home" "$good"

# The keys, known_hosts, authorized_keys, risks and agent groups. The tester
# images have no openssh-client, so ssh-keygen and ssh-add are stubs: -y
# succeeds (no passphrase) only for a key whose name says "plain", -l reports
# a 2048-bit RSA key for *rsa* files and Ed25519 otherwise, and ssh-add says
# no agent answered.
sshdoc_stub="$(mktemp -d)"
cat > "$sshdoc_stub/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
for last in "$@"; do :; done
last="${last##*/}"
case " $* " in
  *" -y "*) [[ "$last" == *plain* ]] && exit 0; exit 1 ;;
  *" -l "*)
    case "$last" in
      *rsa*) printf '2048 SHA256:abc comment (RSA)\n' ;;
      *)     printf '256 SHA256:def comment (ED25519)\n' ;;
    esac
    ;;
esac
exit 0
STUB
cat > "$sshdoc_stub/ssh-add" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
chmod +x "$sshdoc_stub/ssh-keygen" "$sshdoc_stub/ssh-add"
keys_dir="$(mktemp -d)"
chmod 700 "$keys_dir"
for k in id_rsa_plain id_ed25519; do
  printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'not-a-real-key' '-----END OPENSSH PRIVATE KEY-----' > "$keys_dir/$k"
  chmod 600 "$keys_dir/$k"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest %s\n' "$k" > "$keys_dir/$k.pub"
done
out="$(PATH="$sshdoc_stub:$PATH" "$SSHDOC" --ssh-dir "$keys_dir" --only keys 2>&1)"; rc=$?
assert_eq "ssh_client_doctor keys group warns but does not fail" "0" "$rc"
assert_contains "ssh_client_doctor warns on a key with no passphrase" \
  "$(grep -F 'id_rsa_plain has no passphrase' <<<"$out" || true)" "[warn]"
assert_contains "ssh_client_doctor warns on a 2048-bit RSA key" "$out" "id_rsa_plain is a 2048-bit RSA key"
assert_contains "ssh_client_doctor passes an Ed25519 key" \
  "$(grep -F 'id_ed25519 is an ED25519 key' <<<"$out" || true)" "[pass]"
assert_contains "ssh_client_doctor passes a protected key" "$out" "id_ed25519 is passphrase-protected"
assert_not_contains "ssh_client_doctor --only keys leaves the directory group out" "$out" "== directory =="
touch -d '3 years ago' "$keys_dir/id_ed25519"
out="$(PATH="$sshdoc_stub:$PATH" "$SSHDOC" --ssh-dir "$keys_dir" --only keys --max-key-age 1 2>&1)"
assert_contains "ssh_client_doctor warns on an old key" "$out" "consider rotating"
out="$(PATH="$sshdoc_stub:$PATH" "$SSHDOC" --ssh-dir "$keys_dir" --only keys --max-key-age 0 2>&1)"
assert_not_contains "ssh_client_doctor --max-key-age 0 turns the age check off" "$out" "consider rotating"

printf '%s\n' 'example.com ssh-ed25519 AAAA1' 'example.com ssh-ed25519 AAAA2' \
  '|1|c2FsdA==|aGFzaA== ssh-ed25519 AAAA3' > "$keys_dir/known_hosts"
chmod 644 "$keys_dir/known_hosts"
out="$("$SSHDOC" --ssh-dir "$keys_dir" --only known_hosts 2>&1)"; rc=$?
assert_eq "ssh_client_doctor known_hosts conflicts warn, not fail" "0" "$rc"
assert_contains "ssh_client_doctor warns on conflicting host keys" "$out" "host example.com has conflicting ssh-ed25519 keys"
assert_contains "ssh_client_doctor counts only the plain entries as unhashed" "$out" "2 of 3 entries are unhashed"
printf '%s\n' 'old.example.com ssh-dss AAAA4' >> "$keys_dir/known_hosts"
out="$("$SSHDOC" --ssh-dir "$keys_dir" --only known_hosts 2>&1)"; rc=$?
assert_contains "ssh_client_doctor fails an ssh-dss host key" "$out" "[FAIL]"
assert_eq "ssh_client_doctor ssh-dss host key -> 1" "1" "$rc"

printf '%s\n' 'ssh-ed25519 AAAAdup one@example' 'from="10.0.0.1" ssh-ed25519 AAAAdup again@example' \
  'ssh-ed25519 AAAAother other@example' > "$keys_dir/authorized_keys"
chmod 600 "$keys_dir/authorized_keys"
out="$("$SSHDOC" --ssh-dir "$keys_dir" --only authorized_keys 2>&1)"
assert_contains "ssh_client_doctor warns on a duplicate authorized key" "$out" "1 duplicate key line(s)"
assert_contains "ssh_client_doctor counts keys with no options" "$out" "2 of 3 key(s) carry no options"

risky_dir="$(mktemp -d)"
chmod 700 "$risky_dir"
printf '%s\n' 'Host *' '  StrictHostKeyChecking no' '  ForwardAgent yes' > "$risky_dir/config"
chmod 600 "$risky_dir/config"
out="$("$SSHDOC" --ssh-dir "$risky_dir" 2>&1)"; rc=$?
assert_contains "ssh_client_doctor fails StrictHostKeyChecking no for every host" \
  "$(grep -F 'StrictHostKeyChecking' <<<"$out" || true)" "[FAIL]"
assert_contains "ssh_client_doctor names the config line" "$out" "line 2, Host *"
assert_contains "ssh_client_doctor warns on ForwardAgent for every host" \
  "$(grep -F 'ForwardAgent' <<<"$out" || true)" "[warn]"
assert_eq "ssh_client_doctor Host * without host key checking -> 1" "1" "$rc"
printf '%s\n' 'Host build-*' '  StrictHostKeyChecking no' '  ForwardAgent yes' > "$risky_dir/config"
out="$("$SSHDOC" --ssh-dir "$risky_dir" --only risks 2>&1)"; rc=$?
assert_not_contains "ssh_client_doctor leaves a per-host exception ungraded" "$out" "[FAIL]"
assert_eq "ssh_client_doctor per-host exception -> 0" "0" "$rc"
# A negated pattern carves hosts out, so Host * !pattern is not global.
printf '%s\n' 'Host * !trusted.example' '  StrictHostKeyChecking no' '  ForwardAgent yes' > "$risky_dir/config"
out="$("$SSHDOC" --ssh-dir "$risky_dir" --only risks 2>&1)"; rc=$?
assert_not_contains "ssh_client_doctor does not grade Host * with a negation as global" "$out" "[FAIL]"
assert_not_contains "ssh_client_doctor does not warn on Host * with a negation" "$out" "[warn]"
assert_contains "ssh_client_doctor says all hosts except the negated one" "$out" "for all hosts except !trusted.example"
assert_eq "ssh_client_doctor Host * with a negation -> 0" "0" "$rc"
# First value wins: an earlier block that sets the keyword narrows a later
# Host * value to the hosts that block does not match.
printf '%s\n' 'Host trusted.example' '  StrictHostKeyChecking yes' '  ForwardAgent no' \
  'Host *' '  StrictHostKeyChecking no' '  ForwardAgent yes' > "$risky_dir/config"
out="$("$SSHDOC" --ssh-dir "$risky_dir" --only risks 2>&1)"; rc=$?
assert_not_contains "ssh_client_doctor does not fail a Host * value an earlier block overrides" "$out" "[FAIL]"
assert_not_contains "ssh_client_doctor does not warn on an overridden Host * ForwardAgent" "$out" "[warn]"
assert_contains "ssh_client_doctor says Host * applies to hosts not matched earlier" "$out" "for hosts not matched by an earlier block that sets it"
assert_eq "ssh_client_doctor Host * after an earlier same keyword -> 0" "0" "$rc"
printf '%s\n' 'Host trusted.example' '  StrictHostKeyChecking yes' \
  'Host *' '  ForwardAgent yes' '  StrictHostKeyChecking no' > "$risky_dir/config"
out="$("$SSHDOC" --ssh-dir "$risky_dir" --only risks 2>&1)"; rc=$?
assert_contains "ssh_client_doctor still warns on a Host * keyword no earlier block sets" \
  "$(grep -F 'ForwardAgent' <<<"$out" || true)" "[warn]"
assert_not_contains "ssh_client_doctor still spares the keyword an earlier block set" \
  "$(grep -F 'StrictHostKeyChecking' <<<"$out" || true)" "[FAIL]"

out="$(SSH_AUTH_SOCK=/nonexistent PATH="$sshdoc_stub:$PATH" "$SSHDOC" --ssh-dir "$risky_dir" --only agent 2>&1)"
assert_contains "ssh_client_doctor warns on a dead agent socket" "$out" "dead agent"
out="$("$SSHDOC" --ssh-dir "$risky_dir" --only agent 2>&1)"
assert_contains "ssh_client_doctor skips the agent when none is set" "$out" "SSH_AUTH_SOCK is not set"

sshdoc_groups="$("$SSHDOC" --list-groups)"
for g in directory files config keys known_hosts authorized_keys risks agent; do
  assert_contains "ssh_client_doctor lists group $g" "$sshdoc_groups" "$g"
done
"$SSHDOC" --only bogus >/dev/null 2>&1; rc=$?
assert_eq "ssh_client_doctor rejects an unknown group -> 3" "3" "$rc"
"$SSHDOC" --max-key-age soon >/dev/null 2>&1; rc=$?
assert_eq "ssh_client_doctor rejects --max-key-age soon -> 3" "3" "$rc"
rm -rf "$sshdoc_stub" "$keys_dir" "$risky_dir"

section "status.sh"
status_sections="$("$L/status.sh" --list-sections)"
for section in os disk packages reboot timer git; do
  assert_contains "status lists section $section" "$status_sections" "$section"
done
"$L/status.sh" --only nosuch >/dev/null 2>&1; rc=$?
assert_eq "status rejects unknown --only section -> 3" "3" "$rc"
"$L/status.sh" --only , >/dev/null 2>&1; rc=$?
assert_eq "status --only empty selection -> 4" "4" "$rc"
out="$(env -u HOME "$L/status.sh" --list-sections 2>&1)"; rc=$?
assert_eq "status --list-sections works with HOME unset" "0" "$rc"
out="$("$L/status.sh" --only os 2>&1)"; rc=$?
assert_eq "status --only os exits 0" "0" "$rc"
assert_contains "status --only os prints the os section" "$out" "os"

echo
end_section
# The file's own floor: it reached this line having opened sections, each of
# which asserted something. Reaching it at all is what the removal of `-e`
# put in question, and the count of sections is what a truncated copy of this
# file would get wrong.
if (( sections == 0 || checks == 0 )); then
  echo "no section ran ($sections sections, $checks checks) — the suite is not asserting anything" >&2
  exit 1
fi
if (( failures > 0 )); then
  echo "$failures of $checks linux script check(s) failed" >&2
  exit 1
fi
echo "=== all $checks linux script checks passed in $sections sections ($EXPECT_PKG_MGR) ==="
exit 0

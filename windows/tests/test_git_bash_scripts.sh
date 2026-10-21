#!/usr/bin/env bash
# Behavioural checks for the Git Bash scripts in windows/git-bash/.
#
# run.sh keeps its original handful of checks; this file holds the ones that
# need fixtures: a scratch home with dotfiles, a .gitconfig, and shims on PATH
# standing in for the Windows tools (reg.exe, cygpath) and for ssh-add and
# ssh-keygen, so every probe answers the same way on a Linux runner, a
# developer's machine and Git Bash itself.
#
# No `-e`, for the reason linux/tests/test_linux_scripts.sh gives: a suite that
# aborts on the first non-zero exit throws away the output that explains it.
# Every failure is a named assertion, and a section that asserted nothing
# fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GB="$REPO_ROOT/windows/git-bash"
DOCTOR="$GB/gitbash_doctor.sh"

# git reads these, and the doctor runs git. Left alone they would aim its
# reads at the developer's own configuration instead of the fixtures below.
unset GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR
export NO_COLOR=1

# Every fixture below starts from `mktemp -d`. Without `-e` a failed mktemp
# leaves the variable empty and the paths built from it absolute, so prove
# once that scratch space works.
SCRATCH="$(mktemp -d 2>/dev/null)"
if [[ -z "$SCRATCH" || ! -d "$SCRATCH" ]]; then
  echo "cannot create scratch directories under ${TMPDIR:-/tmp}" >&2
  exit 1
fi
trap 'rm -rf "$SCRATCH"' EXIT

failures=0
checks=0
section_checks=0
sections=0
section_name=""
ok()  { checks=$((checks + 1)); section_checks=$((section_checks + 1)); echo "[ ok ] $*"; }
err() { checks=$((checks + 1)); section_checks=$((section_checks + 1)); echo "[fail] $*" >&2; failures=$((failures + 1)); }

section() {
  end_section
  section_name="$1"
  section_checks=0
  sections=$((sections + 1))
  printf '\n--- %s ---\n' "$1"
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

# Names, modes and mtimes, plus a checksum of every file, so a rewrite that
# lands in the same minute is still caught.
snapshot() {
  find "$1" -mindepth 1 -exec ls -ld {} + 2>/dev/null | sort
  find "$1" -type f -exec cksum {} + 2>/dev/null | sort
}

# A tiny executable standing in for a tool: shim PATH BODY.
shim() {
  printf '#!/bin/sh\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

# PATH for the fixtures: the real one with duplicates and missing directories
# removed, so the doctor's own PATH checks see a clean PATH unless a case adds
# something to it.
BASE_PATH=""
IFS=':' read -r -a _path_entries <<<"$PATH"
for _dir in "${_path_entries[@]}"; do
  [[ -n "$_dir" && -d "$_dir" ]] || continue
  case ":$BASE_PATH:" in *":$_dir:"*) continue ;; esac
  BASE_PATH="${BASE_PATH:+$BASE_PATH:}$_dir"
done

# A home the doctor has nothing to say about: the repository's dotfiles, a
# protected key with its .pub, a complete .gitconfig, and shims for every
# Windows-side probe. Prints the fixture directory.
new_doctor_fixture() {
  local fx
  fx="$(mktemp -d "$SCRATCH/doctor.XXXXXX")"
  mkdir -p "$fx/home/.ssh" "$fx/bin"
  cp "$GB/.bashrc" "$GB/.bash_profile" "$GB/.aliases" "$fx/home/"
  printf 'not a real key\n' > "$fx/home/.ssh/id_ed25519"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE test\n' > "$fx/home/.ssh/id_ed25519.pub"
  cat > "$fx/home/.gitconfig" <<'EOF'
[user]
	name = Test User
	email = test@example.invalid
[core]
	longpaths = true
[credential]
	helper = manager
EOF
  : > "$fx/system-gitconfig"
  # Bodies print their text through %s, never as a printf format: sh's printf
  # would read the \a in C:\Users\a as an escape.
  shim "$fx/bin/reg.exe" "printf '%s\\r\\n' '' 'HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' '    LongPathsEnabled    REG_DWORD    0x1' ''"
  shim "$fx/bin/cygpath" "printf '%s\\n' 'C:\\Users\\a'"
  shim "$fx/bin/ssh-add" 'exit 0'
  # Exit 1 is what ssh-keygen -y -P "" answers for a key that has a passphrase.
  shim "$fx/bin/ssh-keygen" 'exit 1'
  shim "$fx/bin/ssh" 'exit 0'
  shim "$fx/bin/python" 'exit 0'
  shim "$fx/bin/python3" 'exit 0'
  printf '%s\n' "$fx"
}

# run_doctor FIXTURE [PATH-PREFIX] [ARGS...]: output in $out, exit in $rc.
# The system git config is pointed at an empty file so a runner whose Git sets
# core.longpaths or a credential helper system-wide cannot answer for the
# fixture.
run_doctor() {
  local fx="$1" prefix="$2"
  shift 2
  out="$(HOME="$fx/home" PATH="${prefix:+$prefix:}$fx/bin:$BASE_PATH" \
    GIT_CONFIG_SYSTEM="$fx/system-gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    "$DOCTOR" --home "$fx/home" "$@" 2>&1)"
  rc=$?
}

# --------------------------------------------------------------------------
section "gitbash_doctor help and usage"
out="$("$DOCTOR" --help 2>&1)"; rc=$?
assert_eq "gitbash_doctor --help -> 0" 0 "$rc"
assert_contains "gitbash_doctor --help prints usage" "$out" "Usage:"
assert_not_contains "gitbash_doctor --help offers no preview flag it does not have" "$out" "--dry-run"
"$DOCTOR" --bogus >/dev/null 2>&1; rc=$?
assert_eq "gitbash_doctor --bogus -> 3" 3 "$rc"
"$DOCTOR" --fail-on=bogus >/dev/null 2>&1; rc=$?
assert_eq "gitbash_doctor --fail-on=bogus -> 3" 3 "$rc"
"$DOCTOR" --home >/dev/null 2>&1; rc=$?
assert_eq "gitbash_doctor --home with no value -> 3" 3 "$rc"
"$DOCTOR" --home "$SCRATCH/does-not-exist" >/dev/null 2>&1; rc=$?
assert_eq "gitbash_doctor --home <missing directory> -> 2" 2 "$rc"

# --------------------------------------------------------------------------
section "gitbash_doctor clean home"
fx="$(new_doctor_fixture)"
run_doctor "$fx" ""
assert_eq "clean home -> 0" 0 "$rc"
assert_not_contains "clean home has no failure" "$out" "[FAIL]"
assert_contains "clean home summary counts no warnings" "$out" ", 0 warnings, 0 failed,"
run_doctor "$fx" "" --fail-on warn
assert_eq "clean home -> 0 even with --fail-on warn" 0 "$rc"
run_doctor "$fx" "" --source "$GB"
assert_eq "clean home matches the repository -> 0" 0 "$rc"
assert_contains "--source compares the dotfiles" "$out" ".aliases present and parses"

# --------------------------------------------------------------------------
section "gitbash_doctor findings"
fx="$(new_doctor_fixture)"
printf 'alias x=y\r\n' >> "$fx/home/.aliases"
run_doctor "$fx" ""
assert_eq "CRLF in .aliases -> 1" 1 "$rc"
assert_contains "CRLF is named" "$out" "CRLF line endings"
assert_contains "the sed fix is printed" "$out" "sed -i"

fx="$(new_doctor_fixture)"
printf 'if then\n' > "$fx/home/.bashrc.local"
run_doctor "$fx" ""
assert_eq ".bashrc.local with a syntax error -> 1" 1 "$rc"
assert_contains ".bashrc.local is named" "$out" ".bashrc.local does not parse"

fx="$(new_doctor_fixture)"
printf 'SSH_AUTH_SOCK=/tmp/ssh-x/agent.1; export SSH_AUTH_SOCK;\nSSH_AGENT_PID=999999; export SSH_AGENT_PID;\n' \
  > "$fx/home/.ssh/agent.env"
run_doctor "$fx" ""
assert_eq "stale agent.env is a warning, not a failure -> 0" 0 "$rc"
assert_contains "stale agent.env is reported" "$out" "stale agent.env: pid 999999"
run_doctor "$fx" "" --fail-on warn
assert_eq "stale agent.env with --fail-on warn -> 1" 1 "$rc"

fx="$(new_doctor_fixture)"
shim "$fx/bin/reg.exe" "printf '%s\\r\\n' '    LongPathsEnabled    REG_DWORD    0x0'"
run_doctor "$fx" ""
assert_contains "LongPathsEnabled 0x0 is a warning" "$out" "LongPathsEnabled is 0x0"

fx="$(new_doctor_fixture)"
shim "$fx/bin/cygpath" "printf '%s\\n' 'C:\\Users\\a b\\OneDrive\\x'"
run_doctor "$fx" ""
assert_contains "a space in HOME is reported" "$out" "HOME contains a space"
assert_contains "HOME under OneDrive is reported" "$out" "HOME is under OneDrive"
assert_contains "and nothing else is" "$out" ", 2 warnings, 0 failed,"

fx="$(new_doctor_fixture)"
cat > "$fx/home/.gitconfig" <<'EOF'
[user]
	name = Test User
	email = test@example.invalid
[credential]
	helper = manager
[safe]
	directory = *
EOF
run_doctor "$fx" ""
assert_contains ".gitconfig without core.longpaths is reported" "$out" "core.longpaths is not true"
assert_contains "safe.directory = * is reported" "$out" "disables the ownership check"

fx="$(new_doctor_fixture)"
mkdir -p "$fx/win/System32/OpenSSH"
shim "$fx/win/System32/OpenSSH/ssh" 'exit 0'
run_doctor "$fx" "$fx/win/System32/OpenSSH"
assert_contains "Windows OpenSSH ahead of Git's ssh is reported" "$out" "Windows OpenSSH, not Git's ssh"

fx="$(new_doctor_fixture)"
mkdir -p "$fx/AppData/Local/Microsoft/WindowsApps"
shim "$fx/AppData/Local/Microsoft/WindowsApps/python" 'exit 9009'
run_doctor "$fx" "$fx/AppData/Local/Microsoft/WindowsApps"
assert_contains "the Store python stub is reported" "$out" "Microsoft Store alias stub"

fx="$(new_doctor_fixture)"
shim "$fx/bin/ssh-keygen" 'exit 0'
run_doctor "$fx" ""
assert_contains "a key without a passphrase is reported" "$out" "private key has no passphrase"
assert_not_contains "and no key material is printed" "$out" "AAAAC3NzaC1lZDI1NTE5AAAAIFAKE"

# --------------------------------------------------------------------------
section "gitbash_doctor is read-only"
fx="$(new_doctor_fixture)"
printf 'SSH_AGENT_PID=999999; export SSH_AGENT_PID;\n' > "$fx/home/.ssh/agent.env"
printf 'if then\n' > "$fx/home/.bashrc.local"
before="$(snapshot "$fx/home")"
run_doctor "$fx" "" --fail-on warn --source "$GB"
after="$(snapshot "$fx/home")"
assert_eq "a run with findings exits 1" 1 "$rc"
if [[ -n "$before" && "$before" == "$after" ]]; then
  ok "gitbash_doctor left the home directory exactly as it found it"
else
  err "gitbash_doctor changed the home directory"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/       /' >&2
fi

echo
end_section
if (( sections == 0 || checks == 0 )); then
  echo "no section ran ($sections sections, $checks checks) — the suite is not asserting anything" >&2
  exit 1
fi
if (( failures > 0 )); then
  echo "$failures of $checks Git Bash script check(s) failed" >&2
  exit 1
fi
echo "=== all $checks Git Bash script checks passed in $sections sections ==="
exit 0

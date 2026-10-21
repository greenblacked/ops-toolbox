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
INSTALL="$GB/install_dotfiles.sh"

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
skip() { checks=$((checks + 1)); section_checks=$((section_checks + 1)); echo "[skip] $*"; }

# Git Bash on Windows makes ln -s copy the file unless real symlinks are
# enabled, so the assertions about symlinks only mean something where one is.
HAVE_SYMLINKS=0
if [[ -n "$SCRATCH" ]]; then
  : > "$SCRATCH/.symlink-probe-target"
  if ln -s "$SCRATCH/.symlink-probe-target" "$SCRATCH/.symlink-probe" 2>/dev/null && [[ -L "$SCRATCH/.symlink-probe" ]]; then
    HAVE_SYMLINKS=1
  fi
  rm -f "$SCRATCH/.symlink-probe" "$SCRATCH/.symlink-probe-target"
fi

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

# The start of an OpenSSH private key whose body names the bcrypt KDF and
# aes256-ctr, which is how a key with a passphrase begins. Not a usable key:
# the ssh-keygen shims decide what the doctor is told about it.
write_encrypted_key() {
  {
    echo '-----BEGIN OPENSSH PRIVATE KEY-----'
    echo 'b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBzYWx0c2FsdHNhbHRzYWx0AAAAEAAAAAEAAAAzAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    echo '-----END OPENSSH PRIVATE KEY-----'
  } > "$1"
}

# A home the doctor has nothing to say about: the repository's dotfiles, a
# protected key with its .pub, a complete .gitconfig, and shims for every
# Windows-side probe. Prints the fixture directory.
new_doctor_fixture() {
  local fx
  fx="$(mktemp -d "$SCRATCH/doctor.XXXXXX")"
  mkdir -p "$fx/home/.ssh" "$fx/bin"
  cp "$GB/.bashrc" "$GB/.bash_profile" "$GB/.aliases" "$fx/home/"
  write_encrypted_key "$fx/home/.ssh/id_ed25519"
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
  # What ssh-keygen -y -P "" answers for a key that has a passphrase: exit 1
  # and an error that names the passphrase.
  shim "$fx/bin/ssh-keygen" "echo 'Load key \"key\": incorrect passphrase supplied to decrypt private key' >&2; exit 1"
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

# A source directory that lacks a managed file is a failure for that file,
# not a quiet pass.
part_source="$(mktemp -d "$SCRATCH/partsource.XXXXXX")"
cp "$GB/.bashrc" "$GB/.bash_profile" "$part_source/"
run_doctor "$fx" "" --source "$part_source"
assert_eq "--source missing a managed file -> 1" 1 "$rc"
assert_contains "and names the file and the source" "$out" ".aliases is missing from the source $part_source"
assert_not_contains "and does not pass that file" "$out" ".aliases present and parses"
assert_contains "while the files the source holds still pass" "$out" ".bashrc present and parses"

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

# A failing ssh-keygen -y does not prove a passphrase. Told apart: the error
# text, then the file's own markers; a key that is neither is a failure.
fx="$(new_doctor_fixture)"
run_doctor "$fx" ""
assert_contains "a key ssh-keygen reports an incorrect passphrase for is protected" "$out" "private key is passphrase-protected"

fx="$(new_doctor_fixture)"
shim "$fx/bin/ssh-keygen" 'exit 1'
run_doctor "$fx" ""
assert_contains "a silent failure on a key with the bcrypt KDF marker is protected" "$out" "private key is passphrase-protected"
assert_not_contains "and not reported as unusable" "$out" "not a usable private key"

fx="$(new_doctor_fixture)"
shim "$fx/bin/ssh-keygen" 'exit 1'
printf -- '-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----\n' > "$fx/home/.ssh/id_ed25519"
run_doctor "$fx" ""
assert_contains "a PEM key marked ENCRYPTED is protected" "$out" "private key is passphrase-protected"

fx="$(new_doctor_fixture)"
shim "$fx/bin/ssh-keygen" 'exit 1'
printf 'not a real key\n' > "$fx/home/.ssh/id_ed25519"
run_doctor "$fx" "" --fail-on fail
assert_contains "a key that fails with no sign of a passphrase is a failure" "$out" "not a usable private key"
assert_not_contains "and is not called protected" "$out" "private key is passphrase-protected"
assert_eq "and the run exits 1 under --fail-on fail" 1 "$rc"

fx="$(new_doctor_fixture)"
shim "$fx/bin/ssh-keygen" "echo 'Load key \"key\": invalid format' >&2; exit 1"
run_doctor "$fx" ""
assert_contains "a malformed key is reported as unreadable, even with the KDF marker" "$out" "private key cannot be read"
assert_contains "with what ssh-keygen said" "$out" "invalid format"
assert_not_contains "and not called protected" "$out" "private key is passphrase-protected"
assert_not_contains "no key material is printed for it either" "$out" "AAAAC3NzaC1lZDI1NTE5AAAAIFAKE"

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

# --------------------------------------------------------------------------
section "install_dotfiles backups"

# A home with current dotfiles, three backup sets with fixed stamps and
# distinct content (the oldest holds only .bashrc), and a file that merely
# looks like a backup. Prints the directory.
new_backup_home() {
  local h stamp name
  h="$(mktemp -d "$SCRATCH/home.XXXXXX")"
  for name in .bashrc .bash_profile .aliases; do
    printf 'current %s\n' "$name" > "$h/$name"
  done
  printf '.bashrc from 20260101-000000\n' > "$h/.bashrc.backup-20260101-000000"
  for stamp in 20260201-000000 20260301-000000; do
    for name in .bashrc .bash_profile .aliases; do
      printf '%s from %s\n' "$name" "$stamp" > "$h/$name.backup-$stamp"
    done
  done
  printf 'my own notes\n' > "$h/.bashrc.backup-notes"
  printf '%s\n' "$h"
}

# run_install HOME [ARGS...]: output in $out, exit in $rc.
run_install() {
  local h="$1"
  shift
  out="$(HOME="$h" "$INSTALL" --home "$h" "$@" 2>&1)"
  rc=$?
}

h="$(new_backup_home)"
run_install "$h" --list-backups
assert_eq "--list-backups -> 0" 0 "$rc"
assert_eq "--list-backups lists the sets newest first, naming what each holds" \
  $'20260301-000000  .bashrc .bash_profile .aliases\n20260201-000000  .bashrc .bash_profile .aliases\n20260101-000000  .bashrc' \
  "$out"
assert_not_contains "--list-backups ignores a file that only looks like a backup" "$out" "notes"
run_install "$(mktemp -d "$SCRATCH/empty.XXXXXX")" --list-backups
assert_eq "--list-backups with no backups -> 4" 4 "$rc"
run_install "$h" --list-backups --dry-run
assert_eq "--list-backups --dry-run -> 3" 3 "$rc"

h="$(new_backup_home)"
run_install "$h" --restore latest
assert_eq "--restore latest -> 0" 0 "$rc"
assert_eq "--restore latest puts the newest set back" ".bashrc from 20260301-000000" "$(cat "$h/.bashrc")"
saved=""
for f in "$h"/.bashrc.backup-*; do
  case "$f" in *-20260101-000000|*-20260201-000000|*-20260301-000000|*-notes) continue ;; esac
  saved="$f"
done
if [[ -n "$saved" && "$(cat "$saved")" == "current .bashrc" ]]; then
  ok "--restore saved the file it replaced as a new backup set"
else
  err "--restore did not keep the pre-restore .bashrc as a new backup (found '$saved')"
fi

h="$(new_backup_home)"
run_install "$h" --restore 20260101-000000
assert_eq "--restore STAMP -> 0" 0 "$rc"
assert_eq "--restore STAMP restores that set" ".bashrc from 20260101-000000" "$(cat "$h/.bashrc")"
assert_eq "--restore STAMP leaves a file the set does not hold alone" "current .aliases" "$(cat "$h/.aliases")"

h="$(new_backup_home)"
run_install "$h" --restore 19990101-000000
assert_eq "--restore <unknown stamp> -> 3" 3 "$rc"
assert_contains "and names the sets that exist" "$out" "20260301-000000"
run_install "$h" --restore
assert_eq "--restore with no value -> 3" 3 "$rc"
run_install "$h" --restore=latest
assert_eq "--restore=latest -> 0" 0 "$rc"

# A destination that is a directory is skipped, the rest of the set still
# comes back, and the exit status says the restore was only partial.
h="$(new_backup_home)"
rm -f "$h/.bash_profile"
mkdir "$h/.bash_profile"
run_install "$h" --restore latest
assert_eq "--restore with a directory in the way -> 1" 1 "$rc"
assert_contains "--restore names the directory it skipped" "$out" ".bash_profile is a directory"
assert_contains "--restore calls the result partial" "$out" "partial restore"
assert_eq "--restore still restores the files before the directory" ".bashrc from 20260301-000000" "$(cat "$h/.bashrc")"
assert_eq "--restore still restores the files after the directory" ".aliases from 20260301-000000" "$(cat "$h/.aliases")"
if [[ -d "$h/.bash_profile" && ! -L "$h/.bash_profile" ]]; then
  ok "--restore left the directory where it was"
else
  err "--restore replaced the directory"
fi
# Not "latest": the restore above saved what it replaced as a newer set, which
# holds no .bash_profile, so "latest" would now name a set with no directory
# conflict at all.
before="$(snapshot "$h")"
run_install "$h" --restore 20260301-000000 --dry-run
after="$(snapshot "$h")"
assert_eq "--restore --dry-run with a directory in the way -> 1" 1 "$rc"
assert_contains "--restore --dry-run names the directory it would skip" "$out" ".bash_profile is a directory"
assert_eq "--restore --dry-run with a directory in the way wrote nothing" "$before" "$after"

h="$(new_backup_home)"
before="$(snapshot "$h")"
run_install "$h" --restore latest --dry-run
after="$(snapshot "$h")"
assert_eq "--restore --dry-run -> 0" 0 "$rc"
assert_contains "--restore --dry-run prints what it would run" "$out" "would run"
assert_eq "--restore --dry-run wrote nothing" "$before" "$after"

h="$(new_backup_home)"
printf 'managed by a dotfiles repository\n' > "$h/managed-bashrc"
ln -s "$h/managed-bashrc" "$h/.bashrc.backup-20260401-000000"
run_install "$h" --restore 20260401-000000
assert_eq "--restore of a symlink backup -> 0" 0 "$rc"
if (( HAVE_SYMLINKS == 0 )); then
  skip "symlink restore: this platform's ln -s makes copies, not symlinks"
elif [[ -L "$h/.bashrc" && "$(readlink "$h/.bashrc")" == "$h/managed-bashrc" ]]; then
  ok "a symlinked .bashrc backup comes back as the same symlink"
else
  err "a symlinked .bashrc backup was not restored as a symlink"
fi
assert_eq "and the file it points at is untouched" "managed by a dotfiles repository" "$(cat "$h/managed-bashrc")"

h="$(new_backup_home)"
before="$(snapshot "$h")"
run_install "$h" --prune-backups 1
after="$(snapshot "$h")"
assert_eq "--prune-backups without --yes -> 0" 0 "$rc"
assert_contains "--prune-backups without --yes says how to delete" "$out" "pass --yes"
assert_eq "--prune-backups without --yes deletes nothing" "$before" "$after"
run_install "$h" --prune-backups 1 --dry-run --yes
assert_contains "--prune-backups --dry-run --yes still only previews" "$out" "dry-run: would run: rm -f"
run_install "$h" --prune-backups 1 --yes
assert_eq "--prune-backups 1 --yes -> 0" 0 "$rc"
run_install "$h" --list-backups
assert_eq "--prune-backups 1 --yes keeps exactly the newest set" \
  "20260301-000000  .bashrc .bash_profile .aliases" "$out"
assert_eq "--prune-backups leaves an unrelated look-alike alone" "my own notes" "$(cat "$h/.bashrc.backup-notes")"
assert_eq "--prune-backups leaves the dotfiles themselves alone" "current .bashrc" "$(cat "$h/.bashrc")"

run_install "$h" --prune-backups x
assert_eq "--prune-backups x -> 3" 3 "$rc"
run_install "$h" --prune-backups=-1
assert_eq "--prune-backups=-1 -> 3" 3 "$rc"
run_install "$h" --yes
assert_eq "--yes alone -> 3" 3 "$rc"
run_install "$h" --restore latest --status
assert_eq "--restore with --status -> 3" 3 "$rc"
run_install "$h" --list-backups --prune-backups 1
assert_eq "--list-backups with --prune-backups -> 3" 3 "$rc"

# The source files are not needed to roll back: a copy of the script in ~/bin
# with no checkout beside it must still restore.
h="$(new_backup_home)"
run_install "$h" --restore latest --source "$(mktemp -d "$SCRATCH/nosource.XXXXXX")"
assert_eq "--restore works with --source pointing at an empty directory" 0 "$rc"

# --------------------------------------------------------------------------
section "install_dotfiles --diff"

# A home holding exact copies of the repository's dotfiles. Prints it.
new_diff_home() {
  local h
  h="$(mktemp -d "$SCRATCH/diffhome.XXXXXX")"
  cp "$GB/.bashrc" "$GB/.bash_profile" "$GB/.aliases" "$h/"
  printf '%s\n' "$h"
}

h="$(new_diff_home)"
run_install "$h" --diff --source "$GB"
assert_eq "--diff with every target current -> 0" 0 "$rc"
assert_eq "--diff prints three MATCH lines" 3 "$(grep -c '^MATCH   ' <<<"$out")"
assert_not_contains "--diff prints no diff when nothing differs" "$out" "---"
assert_contains "--diff counts what differs" "$out" "0 file(s) differ"

printf '# local alias\n' >> "$h/.aliases"
before="$(snapshot "$h")"
run_install "$h" --diff --source "$GB"
after="$(snapshot "$h")"
assert_eq "--diff with a local edit -> 4" 4 "$rc"
assert_contains "--diff names the drifted file" "$out" "DRIFT   $h/.aliases"
if grep -qx -- '-# local alias' <<<"$out"; then
  ok "the local line is shown as one an install would remove"
else
  err "--diff did not show '-# local alias' as a removed line"
  printf '%s\n' "$out" | head -20 >&2
fi
assert_contains "the old side is labelled as the installed file" "$out" "--- installed: $h/.aliases"
assert_contains "the new side is labelled as the repository file" "$out" "+++ repo: $GB/.aliases"
assert_eq "--diff wrote nothing" "$before" "$after"

rm -f "$h/.bashrc"
run_install "$h" --diff --source "$GB"
assert_eq "--diff with a missing target -> 4" 4 "$rc"
assert_contains "--diff reports the missing target" "$out" "MISSING $h/.bashrc"

h="$(new_diff_home)"
crlf_source="$(mktemp -d "$SCRATCH/crlf.XXXXXX")"
cp "$GB/.bashrc" "$GB/.bash_profile" "$GB/.aliases" "$crlf_source/"
printf 'alias crlf=1\r\n' >> "$crlf_source/.aliases"
run_install "$h" --diff --source "$crlf_source"
assert_eq "--diff against a CRLF source -> 1, as --status does" 1 "$rc"
run_install "$h" --diff --source "$crlf_source" --force
assert_eq "--diff --force against a CRLF source reports the drift -> 4" 4 "$rc"

run_install "$h" --diff --dry-run
assert_eq "--diff --dry-run -> 3" 3 "$rc"
run_install "$h" --diff --status
assert_eq "--diff --status -> 3" 3 "$rc"
run_install "$h" --diff --restore latest
assert_eq "--diff --restore -> 3" 3 "$rc"

h="$(new_diff_home)"
printf '# managed elsewhere\n' > "$h/linked-bashrc"
rm -f "$h/.bashrc"
ln -s "$h/linked-bashrc" "$h/.bashrc"
before="$(snapshot "$h")"
run_install "$h" --diff --source "$GB"
assert_eq "--diff through a symlinked target -> 4" 4 "$rc"
assert_contains "the symlinked target is compared by its content" "$out" "DRIFT   $h/.bashrc"
assert_contains "and the diff shows the linked file's lines" "$out" "-# managed elsewhere"
if (( HAVE_SYMLINKS == 0 )); then
  skip "--diff symlink check: this platform's ln -s makes copies, not symlinks"
elif [[ -L "$h/.bashrc" && "$(readlink "$h/.bashrc")" == "$h/linked-bashrc" ]]; then
  ok "--diff left the symlink as it was"
else
  err "--diff changed the symlinked .bashrc"
fi
assert_eq "--diff through a symlinked target changed no file" "$before" "$(snapshot "$h")"

# --------------------------------------------------------------------------
section "ctx"
# The developer's own environment must not steer these: every variable ctx
# reads is cleared here and again for each run below.
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID TF_WORKSPACE \
  KUBECONFIG CTX_DANGER_PATTERN APPDATA DOCKER_CONTEXT AWS_CONFIG_FILE \
  AWS_SHARED_CREDENTIALS_FILE DOCKER_HOST CLOUDSDK_ACTIVE_CONFIG_NAME \
  CLOUDSDK_CORE_PROJECT

ctx_root="$(mktemp -d "$SCRATCH/ctx.XXXXXX")"
mkdir -p "$ctx_root/home/.docker" "$ctx_root/work/.terraform" \
  "$ctx_root/appdata/gcloud/configurations" "$ctx_root/bin" "$ctx_root/empty"
printf '{\n  "auths": {},\n  "currentContext": "desktop-linux"\n}\n' > "$ctx_root/home/.docker/config.json"
# Terraform writes the workspace name with no trailing newline.
printf 'prod' > "$ctx_root/work/.terraform/environment"
printf 'default\n' > "$ctx_root/appdata/gcloud/active_config"
printf '[core]\naccount = me@example.invalid\nproject = acme-prod\n' \
  > "$ctx_root/appdata/gcloud/configurations/config_default"
# cygpath -u PATH answers PATH, which is what it does for a path that is
# already POSIX.
# shellcheck disable=SC2016  # the $2 belongs to the shim, not to this file
shim "$ctx_root/bin/cygpath" 'printf "%s\n" "$2"'

# run_ctx [VAR=VALUE...] [-- CTX-ARGS...]: output in $out, status in $rc.
# Runs ctx from the repository's .aliases in a fresh bash, from the fixture
# work directory, with kubectl and git stubbed as functions the way the kns
# check in run.sh stubs kubectl. CTX_STUBS=none makes both answer nothing.
run_ctx() {
  local assigns=() args=()
  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then
      shift
      args=("$@")
      break
    fi
    assigns+=("$1")
    shift
  done
  # shellcheck disable=SC2016  # the script body expands in the child bash
  out="$(cd "$ctx_root/work" && env -u AWS_PROFILE -u AWS_REGION -u AWS_DEFAULT_REGION \
    -u AWS_ACCESS_KEY_ID -u TF_WORKSPACE -u KUBECONFIG -u CTX_DANGER_PATTERN \
    -u DOCKER_CONTEXT -u NO_COLOR -u CTX_STUBS -u AWS_CONFIG_FILE -u AWS_SHARED_CREDENTIALS_FILE \
    -u DOCKER_HOST -u CLOUDSDK_ACTIVE_CONFIG_NAME -u CLOUDSDK_CORE_PROJECT \
    HOME="$ctx_root/home" APPDATA="$ctx_root/appdata" PATH="$ctx_root/bin:$PATH" \
    ${assigns[@]+"${assigns[@]}"} "${BASH:-bash}" -c '
      kubectl() {
        [ "${CTX_STUBS:-}" = none ] && return 1
        case "$*" in
          "config view --minify --output=jsonpath={.current-context}") printf "prod-eu" ;;
          "config view --minify --output=jsonpath={..namespace}") printf "payments" ;;
          *) return 1 ;;
        esac
      }
      git() {
        [ "${CTX_STUBS:-}" = none ] && return 128
        case "$*" in
          "rev-parse --abbrev-ref HEAD") printf "feature/x\n" ;;
          "config --get remote.origin.url") printf "git@github.com:acme/app.git\n" ;;
          *) return 1 ;;
        esac
      }
      . "$0"
      ctx "$@"
      status=$?
      # ctx keeps its variables local; one escaping would linger in the
      # interactive shell that sourced .aliases.
      [ -n "${plain+x}${printed+x}${pattern+x}${aws_profile+x}${tf_ws+x}" ] && echo "LEAKED"
      exit "$status"
    ' "$GB/.aliases" ${args[@]+"${args[@]}"} 2>&1)"
  rc=$?
}

run_ctx AWS_PROFILE=prod-admin AWS_REGION=eu-west-1
assert_eq "ctx with targets configured -> 0" 0 "$rc"
assert_contains "ctx shows the kube context and namespace" "$out" "kube    prod-eu / payments!"
assert_contains "ctx shows the AWS profile and region" "$out" "aws     prod-admin!  (eu-west-1)"
assert_contains "ctx shows the gcloud project" "$out" "gcloud  acme-prod!"
assert_contains "ctx shows the Terraform workspace and where it came from" "$out" "tf      prod!  (.terraform/environment)"
assert_contains "ctx shows the Docker context" "$out" "docker  desktop-linux"$'\n'
assert_contains "ctx shows the branch and the origin host" "$out" "git     feature/x  origin=github.com"
assert_not_contains "ctx leaves its variables local" "$out" "LEAKED"
assert_not_contains "without a terminal there is no colour" "$out" $'\033'

run_ctx AWS_PROFILE=stg AWS_REGION=eu-west-1
assert_contains "a staging profile carries no mark" "$out" "aws     stg  (eu-west-1)"$'\n'

run_ctx AWS_PROFILE=stg CTX_DANGER_PATTERN='^stg$'
assert_contains "CTX_DANGER_PATTERN decides what is marked" "$out" "aws     stg!"
assert_contains "and what is not" "$out" "kube    prod-eu / payments"$'\n'

# No AWS_PROFILE and no exported keys: the CLI uses [default] of the shared
# files, so ctx shows that profile and its region. Only a region is ever read
# from them, never a key.
mkdir -p "$ctx_root/aws" "$ctx_root/awshome/.aws"
printf '[profile dev]\nregion = eu-north-1\n\n[default]\nregion = ap-south-1\noutput = json\n' > "$ctx_root/aws/config"
printf '[default]\naws_access_key_id = AKIASECRETKEY\naws_secret_access_key = topsecretvalue\n' > "$ctx_root/aws/credentials"
printf '[profile dev]\nregion = eu-north-1\n' > "$ctx_root/aws/config-nodefault"
cp "$ctx_root/aws/config" "$ctx_root/awshome/.aws/config"

run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config" AWS_SHARED_CREDENTIALS_FILE="$ctx_root/aws/none"
assert_contains "ctx shows the default AWS profile and its region from the config file" "$out" "aws     default  (ap-south-1)"
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config" AWS_REGION=eu-west-1
assert_contains "AWS_REGION still wins over the default profile's region" "$out" "aws     default  (eu-west-1)"
run_ctx HOME="$ctx_root/awshome"
assert_contains "the config file is looked for in ~/.aws by default" "$out" "aws     default  (ap-south-1)"
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/none" AWS_SHARED_CREDENTIALS_FILE="$ctx_root/aws/credentials"
assert_contains "a credentials file with a [default] profile is enough" "$out" "aws     default"$'\n'
assert_not_contains "and no key from it is printed" "$out" "AKIASECRETKEY"
assert_not_contains "nor its secret" "$out" "topsecretvalue"
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config-nodefault" AWS_SHARED_CREDENTIALS_FILE="$ctx_root/aws/none"
assert_not_contains "files without a [default] profile show no AWS line" "$out" "aws     "
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config" AWS_ACCESS_KEY_ID=AKIAFAKE
assert_contains "exported keys still show as no profile, not default" "$out" "aws     (no profile)"
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config" AWS_PROFILE=stg
assert_contains "AWS_PROFILE wins over the default profile" "$out" "aws     stg"
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config" AWS_SHARED_CREDENTIALS_FILE="$ctx_root/aws/credentials" AWS_PROFILE=dev
assert_contains "a named profile's region comes from its [profile NAME] section" "$out" "aws     dev  (eu-north-1)"
assert_not_contains "and the default profile's region is not used for it" "$out" "ap-south-1"
assert_not_contains "and no key is printed" "$out" "AKIASECRETKEY"
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config" AWS_PROFILE=dev AWS_REGION=eu-west-1
assert_contains "AWS_REGION still wins over the named profile's region" "$out" "aws     dev  (eu-west-1)"
run_ctx AWS_CONFIG_FILE="$ctx_root/aws/config" AWS_PROFILE=nosuch
assert_contains "a named profile with no region shows none" "$out" "aws     nosuch"$'\n'

run_ctx DOCKER_HOST=tcp://prod-docker:2376
assert_contains "DOCKER_HOST overrides the saved Docker context" "$out" "docker  tcp://prod-docker:2376  (DOCKER_HOST)"
run_ctx DOCKER_HOST=tcp://prod-docker:2376 DOCKER_CONTEXT=staging
assert_contains "DOCKER_CONTEXT stays above DOCKER_HOST" "$out" "docker  staging  (DOCKER_CONTEXT)"
assert_not_contains "and DOCKER_HOST is then not shown" "$out" "prod-docker"

mkdir -p "$ctx_root/tfinit/.terraform"
# shellcheck disable=SC2016  # the script body expands in the child bash
out="$(cd "$ctx_root/tfinit" && env -u TF_WORKSPACE HOME="$ctx_root/empty" CTX_STUBS=none \
  "${BASH:-bash}" -c 'kubectl() { return 1; }; git() { return 128; }; . "$0"; ctx' "$GB/.aliases" 2>&1)"
assert_contains "an initialised directory with no environment file is on default" "$out" "tf      default  (default)"

printf '[core]\nproject = acme-stg\n' > "$ctx_root/appdata/gcloud/configurations/config_other"
run_ctx CLOUDSDK_ACTIVE_CONFIG_NAME=other
assert_contains "CLOUDSDK_ACTIVE_CONFIG_NAME selects the configuration read" "$out" "gcloud  acme-stg"$'\n'
run_ctx CLOUDSDK_CORE_PROJECT=override-prod
assert_contains "CLOUDSDK_CORE_PROJECT overrides the project in the file" "$out" "gcloud  override-prod!"
assert_not_contains "and the file project is not shown" "$out" "acme-prod"

run_ctx TF_WORKSPACE=Production-EU
assert_contains "TF_WORKSPACE wins over .terraform/environment, matched in any case" "$out" "tf      Production-EU!  (TF_WORKSPACE)"

run_ctx AWS_ACCESS_KEY_ID=AKIAFAKE
assert_contains "exported AWS keys are named as such" "$out" "static-keys"
assert_not_contains "and never printed" "$out" "AKIAFAKE"

run_ctx NO_COLOR=1 AWS_PROFILE=prod-admin -- --plain
assert_eq "ctx --plain -> 0" 0 "$rc"
assert_not_contains "ctx --plain with NO_COLOR has no escape byte" "$out" $'\033'
assert_contains "and still marks production" "$out" "prod-admin!"

# shellcheck disable=SC2016  # the script body expands in the child bash
out="$(cd "$ctx_root/empty" && env -u AWS_PROFILE -u AWS_REGION -u AWS_DEFAULT_REGION \
  -u AWS_ACCESS_KEY_ID -u TF_WORKSPACE -u KUBECONFIG -u CTX_DANGER_PATTERN -u APPDATA \
  -u DOCKER_CONTEXT -u AWS_CONFIG_FILE -u AWS_SHARED_CREDENTIALS_FILE \
  -u DOCKER_HOST -u CLOUDSDK_ACTIVE_CONFIG_NAME -u CLOUDSDK_CORE_PROJECT \
  HOME="$ctx_root/empty" CTX_STUBS=none "${BASH:-bash}" -c '
    kubectl() { return 1; }
    git() { return 128; }
    . "$0"
    ctx
  ' "$GB/.aliases" 2>&1)"
rc=$?
assert_eq "ctx with nothing configured returns 1" 1 "$rc"
assert_eq "and prints nothing" "" "$out"

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

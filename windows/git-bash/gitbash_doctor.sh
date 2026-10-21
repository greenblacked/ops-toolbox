#!/usr/bin/env bash
# gitbash_doctor.sh - read-only check of a Git Bash environment on Windows.
#
# Git Bash fails in a handful of quiet, repeatable ways: a dotfile saved with
# CRLF, a ~/.ssh/agent.env pointing at an agent that died with the last
# reboot, Windows' own OpenSSH client ahead of Git's on PATH so the agent's
# keys are invisible, a HOME under OneDrive or with a space in it, long paths
# off on both the Git and the Windows side, and the Microsoft Store python
# stub shadowing a real Python. install_dotfiles.sh --status only says
# whether the dotfiles match; git/git_ssh_doctor.py needs a repository. This
# looks at the machine around them and prints the command that fixes each
# finding. It changes nothing: no file is written, no agent is started or
# killed, and no key material is printed.
#
# A probe whose tool is absent is a skip, not a failure, so this also runs on
# Linux and in the test suite, the way install_dotfiles.sh does.
#
# Exit codes:
#   0   no findings at or above the failure threshold
#   1   one or more findings at or above the threshold (--fail-on)
#   2   wrong environment (no home directory, or --home/--source is not one)
#   3   bad CLI arguments

set -u
set -o pipefail

FAIL_ON="fail"
QUIET=0
HOME_DIR="${HOME:-}"
SOURCE_DIR=""
SSH_KEY_FILE=""

# The three files install_dotfiles.sh installs.
DOTFILES=".bashrc .bash_profile .aliases"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); (( QUIET )) || printf "  %s[pass]%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "  %s[warn]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "  %s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf "         %s%s%s\n" "$C_DIM" "$2" "$C_RESET"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); (( QUIET )) || printf "  %s[skip]%s %s\n" "$C_DIM" "$C_RESET" "$1"; }
info() { (( QUIET )) || printf "  %s[info]%s %s\n" "$C_BLUE" "$C_RESET" "$1"; }
err()  { printf "%s[err ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  cat <<EOF
gitbash_doctor.sh - read-only check of a Git Bash environment

Reports CRLF or broken dotfiles, a stale ssh-agent, the wrong ssh on PATH,
a OneDrive or spaced HOME, long paths, missing Git settings and the Store
python stub. Changes nothing.

Usage:
  $(basename "$0") [--home DIR] [--source DIR] [--ssh-key FILE] [--fail-on warn|fail] [--quiet]

Options:
  --home DIR       Home directory to inspect (default: \$HOME)
  --source DIR     Compare the dotfiles with a checkout of windows/git-bash
                   (default: no comparison)
  --ssh-key FILE   Private key to check (default: <home>/.ssh/id_ed25519)
  --fail-on LEVEL  Exit 1 on 'fail' (default) or on 'warn' and above
  --quiet          Print only warnings and failures
  -h, --help       Show this help

Exit codes: 0 clean, 1 findings at or above --fail-on, 2 wrong environment
(home or source is not a directory), 3 usage
EOF
}

# Byte-identical to git/git_sync_default.sh's copy - see CONTRIBUTING.md for
# why this is copied rather than sourced from a shared library.
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    printf "%s requires a value\n" "$option" >&2
    exit 3
  fi
}

# --help is handled here, before any preflight check.
while (( $# > 0 )); do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    --home)      require_value "$1" "${2:-}"; HOME_DIR="$2"; shift ;;
    --home=*)    HOME_DIR="${1#*=}"; require_value "--home" "$HOME_DIR" ;;
    --source)    require_value "$1" "${2:-}"; SOURCE_DIR="$2"; shift ;;
    --source=*)  SOURCE_DIR="${1#*=}"; require_value "--source" "$SOURCE_DIR" ;;
    --ssh-key)   require_value "$1" "${2:-}"; SSH_KEY_FILE="$2"; shift ;;
    --ssh-key=*) SSH_KEY_FILE="${1#*=}"; require_value "--ssh-key" "$SSH_KEY_FILE" ;;
    --fail-on)   require_value "$1" "${2:-}"; FAIL_ON="$2"; shift ;;
    --fail-on=*) FAIL_ON="${1#*=}"; require_value "--fail-on" "$FAIL_ON" ;;
    --quiet)     QUIET=1 ;;
    *)
      err "unknown option: $1"
      usage >&2
      exit 3
      ;;
  esac
  shift
done

case "$FAIL_ON" in
  warn|fail) ;;
  *) err "--fail-on must be warn or fail, got: $FAIL_ON"; exit 3 ;;
esac

# --- preflight -------------------------------------------------------------
if [[ -z "$HOME_DIR" ]]; then
  err "\$HOME is not set; pass --home DIR"
  exit 2
fi
if [[ ! -d "$HOME_DIR" ]]; then
  err "home directory does not exist: $HOME_DIR"
  exit 2
fi
if [[ -n "$SOURCE_DIR" && ! -d "$SOURCE_DIR" ]]; then
  err "source directory does not exist: $SOURCE_DIR"
  exit 2
fi
[[ -n "$SSH_KEY_FILE" ]] || SSH_KEY_FILE="$HOME_DIR/.ssh/id_ed25519"

group() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$1" "$C_RESET"; }

# Same test install_dotfiles.sh uses. LC_ALL=C keeps grep from deciding the
# file is binary and answering with a summary line instead of a match.
has_cr() {
  LC_ALL=C grep -q $'\r' "$1"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# --- dotfiles --------------------------------------------------------------
group "dotfiles"
for name in $DOTFILES; do
  f="$HOME_DIR/$name"
  if [[ ! -f "$f" ]]; then
    fail "$name is missing from $HOME_DIR" "install it with install_dotfiles.sh"
    continue
  fi
  # A CR breaks every backslash continuation, so a parse error would only be
  # the echo of this one. Report the cause and the fix.
  if has_cr "$f"; then
    fail "$name has CRLF line endings: every prompt redraw throws a syntax error" \
      "fix: sed -i 's/\\r\$//' $f"
    continue
  fi
  if ! "$BASH" -n "$f" 2>/dev/null; then
    fail "$name does not parse" "see: $BASH -n $f"
    continue
  fi
  if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/$name" ]] && ! cmp -s "$f" "$SOURCE_DIR/$name"; then
    warn "$name differs from $SOURCE_DIR/$name" "review with: install_dotfiles.sh --status --source $SOURCE_DIR"
    continue
  fi
  pass "$name present and parses"
done

local_rc="$HOME_DIR/.bashrc.local"
if [[ ! -f "$local_rc" ]]; then
  skip ".bashrc.local not present (optional)"
elif has_cr "$local_rc"; then
  fail ".bashrc.local has CRLF line endings" "fix: sed -i 's/\\r\$//' $local_rc"
elif ! "$BASH" -n "$local_rc" 2>/dev/null; then
  fail ".bashrc.local does not parse, and .bashrc sources it on every start" "see: $BASH -n $local_rc"
else
  pass ".bashrc.local parses"
fi
if [[ -z "$SOURCE_DIR" ]]; then
  skip "drift against the repository not checked (pass --source DIR)"
fi

# --- home ------------------------------------------------------------------
group "home"
if command -v cygpath >/dev/null 2>&1; then
  win_home="$(cygpath -w "$HOME_DIR" 2>/dev/null)"
  if [[ -z "$win_home" ]]; then
    skip "cygpath gave no Windows path for $HOME_DIR"
  else
    home_findings=0
    if [[ "$win_home" == *' '* ]]; then
      warn "HOME contains a space: $win_home" "unquoted \$HOME in scripts and makefiles splits there"
      home_findings=$((home_findings + 1))
    fi
    if LC_ALL=C grep -q '[^ -~]' <<<"$win_home"; then
      warn "HOME contains a non-ASCII character: $win_home" "some MSYS and native tools mangle it"
      home_findings=$((home_findings + 1))
    fi
    if [[ "$(lowercase "$win_home")" == *'\onedrive'* ]]; then
      warn "HOME is under OneDrive: $win_home" "synced folder: slow git and ssh, ~/.ssh may be replicated"
      home_findings=$((home_findings + 1))
    fi
    (( home_findings > 0 )) || pass "HOME is $win_home"
  fi
else
  skip "cygpath not found (not Git Bash); HOME path not checked"
fi

# --- ssh -------------------------------------------------------------------
group "ssh"
agent_env="$HOME_DIR/.ssh/agent.env"
if [[ -f "$agent_env" ]]; then
  # The pid only; the socket path is not needed to tell a live agent from a
  # dead one, and kill -0 sends no signal.
  agent_pid="$(sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\).*/\1/p' "$agent_env")"
  agent_pid="${agent_pid%%$'\n'*}"
  if [[ -z "$agent_pid" ]]; then
    warn "agent.env has no SSH_AGENT_PID line" "the next .bashrc start replaces it"
  elif kill -0 "$agent_pid" 2>/dev/null; then
    pass "agent.env points at a running agent (pid $agent_pid)"
  else
    warn "stale agent.env: pid $agent_pid is not running" "the next .bashrc start replaces it"
  fi
else
  skip "no ~/.ssh/agent.env (no agent started by .bashrc yet)"
fi

# Mapped the way .bashrc maps it: 2 means no agent can be reached, 1 means an
# agent with no keys loaded yet.
if command -v ssh-add >/dev/null 2>&1; then
  ssh-add -l >/dev/null 2>&1 </dev/null
  case $? in
    0) pass "ssh-agent reachable with keys loaded" ;;
    1) info "ssh-agent reachable, no keys loaded yet" ;;
    *) warn "no ssh-agent reachable from this shell" "open a new Git Bash window, or: source ~/.bashrc" ;;
  esac
else
  skip "ssh-add not found"
fi

if [[ ! -f "$SSH_KEY_FILE" ]]; then
  warn "key not found: $SSH_KEY_FILE" "create one: ssh-keygen -t ed25519 -f $SSH_KEY_FILE, or pass --ssh-key FILE"
else
  [[ -f "$SSH_KEY_FILE.pub" ]] || warn "no public key beside it: $SSH_KEY_FILE.pub" "recreate it: ssh-keygen -y -f $SSH_KEY_FILE > $SSH_KEY_FILE.pub"
  if command -v ssh-keygen >/dev/null 2>&1; then
    # An empty passphrase and stdin from /dev/null, so it cannot prompt. The
    # derived public key is discarded; only the exit status is kept.
    if ssh-keygen -y -P '' -f "$SSH_KEY_FILE" >/dev/null 2>&1 </dev/null; then
      warn "private key has no passphrase: $SSH_KEY_FILE" "add one: ssh-keygen -p -f $SSH_KEY_FILE"
    else
      pass "private key is passphrase-protected: $SSH_KEY_FILE"
    fi
  else
    skip "ssh-keygen not found; passphrase not checked"
  fi
fi

ssh_path="$(command -v ssh 2>/dev/null)"
if [[ -z "$ssh_path" ]]; then
  skip "ssh not found on PATH"
elif [[ "$(lowercase "$ssh_path")" == */system32/openssh/* ]]; then
  warn "ssh resolves to Windows OpenSSH, not Git's ssh: it cannot see this ssh-agent ($ssh_path)" \
    "put Git's /usr/bin ahead of it on PATH, or point git at it: git config --global core.sshCommand /usr/bin/ssh"
else
  pass "ssh is $ssh_path"
fi

# --- git -------------------------------------------------------------------
group "git"
gitconfig="$HOME_DIR/.gitconfig"
if ! command -v git >/dev/null 2>&1; then
  skip "git not found"
elif [[ ! -f "$gitconfig" ]]; then
  warn "no $gitconfig: no identity, credential helper or long-path setting" \
    "set them with: git config --global user.name ...; git/set_git_profile.sh does all of it"
else
  # Read from the one file, never the ambient environment, so what is
  # reported is what that file says. The system file is consulted only for
  # the two settings Git for Windows' installer can put there.
  user_value() { git config --file "$gitconfig" "$@" 2>/dev/null; }
  system_value() { git config --system "$@" 2>/dev/null; }

  longpaths="$(user_value --bool --get core.longpaths)"
  [[ -n "$longpaths" ]] || longpaths="$(system_value --bool --get core.longpaths)"
  if [[ "$longpaths" == "true" ]]; then
    pass "core.longpaths is true"
  else
    warn "core.longpaths is not true: checkouts with paths over 260 characters fail" \
      "fix: git config --global core.longpaths true"
  fi

  helper="$(user_value --get-all credential.helper)"
  [[ -n "$helper" ]] || helper="$(system_value --get-all credential.helper)"
  if [[ -n "$helper" ]]; then
    pass "credential.helper is set (${helper%%$'\n'*})"
  else
    warn "no credential.helper: every HTTPS push asks for a password or token" \
      "fix: git config --global credential.helper manager"
  fi

  if grep -qx '\*' <<<"$(user_value --get-all safe.directory)"; then
    warn "safe.directory = * disables the ownership check for every repository" \
      "list the repositories instead: git config --global --add safe.directory <path>"
  fi

  if [[ "$(user_value --bool --get core.autocrlf)" == "true" ]]; then
    info "core.autocrlf = true differs from this repository's eol=lf policy; .gitattributes still wins for the dotfiles"
  fi

  for key in user.name user.email; do
    value="$(user_value --get "$key")"
    if [[ -n "$value" ]]; then
      pass "$key is set"
    else
      warn "$key is not set in $gitconfig" "fix: git config --global $key ..."
    fi
  done
fi

if command -v reg.exe >/dev/null 2>&1; then
  # MSYS rewrites arguments that start with / into Windows paths, which turns
  # /v into C:/Program Files/Git/v. Both variables switch that off for this
  # one call.
  reg_out="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' /v LongPathsEnabled 2>/dev/null)"
  reg_value="$(grep -o '0x[0-9a-fA-F]*' <<<"$reg_out")"
  reg_value="${reg_value%%$'\n'*}"
  case "$reg_value" in
    0x1) pass "Windows LongPathsEnabled is 1" ;;
    '')  warn "Windows LongPathsEnabled is not set (long paths off)" \
           "elevated PowerShell: Set-ItemProperty HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem LongPathsEnabled 1" ;;
    *)   warn "Windows LongPathsEnabled is $reg_value (long paths off)" \
           "elevated PowerShell: Set-ItemProperty HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem LongPathsEnabled 1" ;;
  esac
else
  skip "reg.exe not found (not Windows); LongPathsEnabled not checked"
fi

# --- path ------------------------------------------------------------------
group "path"
seen=$'\n'
dupes=0
dupe_names=""
missing=0
missing_names=""
IFS=':' read -r -a path_entries <<<"$PATH"
for entry in "${path_entries[@]}"; do
  [[ -n "$entry" ]] || continue
  if [[ "$seen" == *$'\n'"$entry"$'\n'* ]]; then
    dupes=$((dupes + 1))
    (( dupes <= 5 )) && dupe_names="$dupe_names $entry"
    continue
  fi
  seen="$seen$entry"$'\n'
  if [[ ! -d "$entry" ]]; then
    missing=$((missing + 1))
    (( missing <= 5 )) && missing_names="$missing_names $entry"
  fi
done
if (( dupes > 0 )); then
  warn "duplicate PATH entries ($dupes):$dupe_names" \
    "dedup_path in .bashrc removes them; an old .bashrc, or one sourced before it, does not"
else
  pass "no duplicate PATH entries"
fi
(( missing == 0 )) || info "PATH entries that are not a directory ($missing):$missing_names"

for py in python python3; do
  py_path="$(command -v "$py" 2>/dev/null)"
  if [[ -z "$py_path" ]]; then
    skip "$py not found"
  elif [[ "$(lowercase "$py_path")" == */windowsapps/* ]]; then
    warn "$py resolves to the Microsoft Store alias stub ($py_path)" \
      "turn it off: Settings > Apps > Advanced app settings > App execution aliases"
  else
    pass "$py is $py_path"
  fi
done

# --- tools -----------------------------------------------------------------
# .aliases defines each block only when its tool is installed, so a missing
# tool here explains a missing alias rather than being a problem.
group "tools"
for tool in docker kubectl terraform glab; do
  tool_path="$(command -v "$tool" 2>/dev/null)"
  if [[ -n "$tool_path" ]]; then
    info "$tool: $tool_path"
  else
    skip "$tool not installed; its aliases stay undefined"
  fi
done

printf "\n%s== summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  %s%s passed%s, %s%s warnings%s, %s%s failed%s, %s%s skipped%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_DIM" "$SKIP_COUNT" "$C_RESET"

case "$FAIL_ON" in
  warn) (( FAIL_COUNT + WARN_COUNT > 0 )) && exit 1; exit 0 ;;
  fail) (( FAIL_COUNT > 0 )) && exit 1; exit 0 ;;
esac
exit 0

#!/usr/bin/env bash
# Aliases and helpers for day-to-day work on a Linux machine.
#
# Sourced, not executed. Prefer install_aliases.sh, which writes a marked
# block once and can take it back out:
#
#     ./install_aliases.sh
#
# The echo one-liner appends a second copy on every rerun. This file carries
# a .sh extension rather than being a dotfile so it is picked up by the
# repository-wide `bash -n` and ShellCheck passes for free — a `.bash_aliases`
# would fall out of every glob and go unchecked, which is exactly what happened
# to the Git Bash dotfiles for a long time.
#
# Every alias for a tool that may not be installed is guarded. An alias to a
# missing binary is worse than no alias: it fails at use time, in the middle of
# something else, with a confusing message.

# Sourcing guard: running this file directly does nothing useful, so say so
# rather than exiting silently and leaving someone puzzled.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'bash_aliases.sh is meant to be sourced, not run:\n' >&2
  printf '  %s/install_aliases.sh\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" >&2
  exit 3
fi

_pus_have() { command -v "$1" >/dev/null 2>&1; }

# --- listing ---------------------------------------------------------------
if _pus_have eza; then
  alias ls='eza --group-directories-first'
  alias ll='eza -l --group-directories-first --git'
  alias la='eza -la --group-directories-first --git'
  alias lt='eza --tree --level=2'
else
  alias ll='ls -lh --group-directories-first'
  alias la='ls -lah --group-directories-first'
fi

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# --- safety ----------------------------------------------------------------
# Interactive by default on the three that cannot be undone. Pass -f to
# override, which is a deliberate keystroke rather than a habit.
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias mkdir='mkdir -p'

alias df='df -h'
alias du='du -h'
alias free='free -h'

# --- grep / find -----------------------------------------------------------
_pus_have rg && alias grep='rg'
if _pus_have fdfind; then
  alias fd='fdfind'   # Debian and Ubuntu ship fd as fdfind
fi

# --- git -------------------------------------------------------------------
if _pus_have git; then
  alias gs='git status --short --branch'
  alias gd='git diff'
  alias gds='git diff --staged'
  alias gl='git log --oneline --graph --decorate -20'
  alias gp='git pull --ff-only'
  alias gb='git branch --sort=-committerdate'
fi

# --- systemd ---------------------------------------------------------------
if _pus_have systemctl; then
  alias sc='systemctl'
  alias scu='systemctl --user'
  alias jf='journalctl -f'
  # Failed units first: the question you actually ask when something is wrong.
  alias failed='systemctl list-units --state=failed'
fi

# --- containers ------------------------------------------------------------
if _pus_have docker; then
  alias d='docker'
  alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
  alias dcu='docker compose up -d'
  alias dcd='docker compose down'
  alias dcl='docker compose logs -f --tail=100'
fi

if _pus_have kubectl; then
  alias k='kubectl'
  alias kctx='kubectl config current-context'
  alias kns='kubectl config view --minify --output=jsonpath={..namespace}'
  alias kpods='kubectl get pods --all-namespaces'
fi
_pus_have terraform && alias tf='terraform'

# --- functions -------------------------------------------------------------

# What is eating the disk in this directory? Sorted, human units, top 20.
bigdirs() {
  du -h --max-depth="${2:-1}" "${1:-.}" 2>/dev/null | sort -rh | head -20
}

# Ports something is listening on, without remembering which flag set ss wants.
listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn 2>/dev/null | grep -i listen
  else
    netstat -tulpn 2>/dev/null | grep -i listen
  fi
}

# Extract any archive without looking up the flags again.
extract() {
  if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    printf 'usage: extract <archive>\n' >&2
    return 3
  fi
  case "$1" in
    *.tar.bz2|*.tbz2) tar xjf "$1" ;;
    *.tar.gz|*.tgz)   tar xzf "$1" ;;
    *.tar.xz)         tar xJf "$1" ;;
    *.tar)            tar xf  "$1" ;;
    *.zip)            unzip "$1" ;;
    *.gz)             gunzip "$1" ;;
    *.bz2)            bunzip2 "$1" ;;
    *.7z)             7z x "$1" ;;
    *) printf 'extract: unsupported archive: %s\n' "$1" >&2; return 3 ;;
  esac
}

# Make a dated backup of a file before editing it in anger.
bak() {
  if [ -z "${1:-}" ] || [ ! -e "$1" ]; then
    printf 'usage: bak <file>\n' >&2
    return 3
  fi
  cp -a "$1" "$1.$(date +%Y%m%d-%H%M%S).bak" && printf 'backed up %s\n' "$1"
}

# ================================ package scripts ==========================
# Resolve the directory this file lives in so the aliases keep working
# regardless of where the repo is cloned or symlinked. Copied on its own
# into ~/bin, none of these fire, which is the same guard git_aliases.sh uses.
_pus_linux_aliases_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"

_pus_linux_alias() {
  local name="$1"
  local script="$2"
  if [ -n "$_pus_linux_aliases_dir" ] && [ -x "$_pus_linux_aliases_dir/$script" ]; then
    alias "$name=$(printf '%q' "$_pus_linux_aliases_dir/$script")"
  fi
}

_pus_linux_alias stay-fresh        stay_fresh.sh
_pus_linux_alias install-devtools  install_devtools.sh
_pus_linux_alias install-aliases   install_aliases.sh
_pus_linux_alias disk-cleanup      disk_cleanup.sh
_pus_linux_alias system-doctor     system_doctor.sh
_pus_linux_alias net-doctor        net_doctor.sh
_pus_linux_alias hardening-audit   hardening_audit.sh
_pus_linux_alias sysctl-defaults   sysctl_defaults.sh
_pus_linux_alias pkg-set           packages.sh
_pus_linux_alias schedule-report   schedule_report.sh
_pus_linux_alias tls-expiry        tls_expiry.sh
_pus_linux_alias config-backup     config_backup.sh
_pus_linux_alias ssh-client-doctor ssh_client_doctor.sh

if [ -x "$_pus_linux_aliases_dir/systemd/stay_fresh_timer.sh" ]; then
  alias stay-fresh-timer="$(printf '%q' "$_pus_linux_aliases_dir/systemd/stay_fresh_timer.sh")"
fi

# Discoverable command palette for the guarded repository shortcuts above.
# It reports only scripts that are executable in this checkout, so copying this
# aliases file without the rest of the package never advertises broken commands.
toolbox-help() {
  printf 'Linux toolbox commands available in this checkout:\n'
  [ -x "$_pus_linux_aliases_dir/install_devtools.sh" ] && \
    printf '  %-20s %s\n' install-devtools 'install language and IaC toolchains'
  [ -x "$_pus_linux_aliases_dir/install_aliases.sh" ] && \
    printf '  %-20s %s\n' install-aliases 'install bash_aliases.sh into ~/.bashrc'
  [ -x "$_pus_linux_aliases_dir/stay_fresh.sh" ] && \
    printf '  %-20s %s\n' stay-fresh 'run recurring machine maintenance'
  [ -x "$_pus_linux_aliases_dir/disk_cleanup.sh" ] && \
    printf '  %-20s %s\n' disk-cleanup 'free space without upgrading packages'
  [ -x "$_pus_linux_aliases_dir/system_doctor.sh" ] && \
    printf '  %-20s %s\n' system-doctor 'report whether this machine is well'
  [ -x "$_pus_linux_aliases_dir/net_doctor.sh" ] && \
    printf '  %-20s %s\n' net-doctor 'report routing, DNS and listening sockets'
  [ -x "$_pus_linux_aliases_dir/hardening_audit.sh" ] && \
    printf '  %-20s %s\n' hardening-audit 'audit security posture'
  [ -x "$_pus_linux_aliases_dir/sysctl_defaults.sh" ] && \
    printf '  %-20s %s\n' sysctl-defaults 'report/apply/revert sysctl values'
  [ -x "$_pus_linux_aliases_dir/packages.sh" ] && \
    printf '  %-20s %s\n' pkg-set 'capture or restore the package set'
  [ -x "$_pus_linux_aliases_dir/schedule_report.sh" ] && \
    printf '  %-20s %s\n' schedule-report 'list systemd timers and cron jobs'
  [ -x "$_pus_linux_aliases_dir/tls_expiry.sh" ] && \
    printf '  %-20s %s\n' tls-expiry 'check leaf certificate expiry'
  [ -x "$_pus_linux_aliases_dir/config_backup.sh" ] && \
    printf '  %-20s %s\n' config-backup 'dated tar of /etc (or --paths)'
  [ -x "$_pus_linux_aliases_dir/ssh_client_doctor.sh" ] && \
    printf '  %-20s %s\n' ssh-client-doctor 'audit ~/.ssh permissions and IdentityFile'
  [ -x "$_pus_linux_aliases_dir/systemd/stay_fresh_timer.sh" ] && \
    printf '  %-20s %s\n' stay-fresh-timer 'manage the stay_fresh user timer'
}

unset -f _pus_linux_alias

#!/usr/bin/env bash
# Git helper aliases for bash — the same names git_aliases.zsh defines for zsh.
#
# Sourced, not executed:
#
#     echo '. /path/to/ops-toolbox/git/git_aliases.sh' >> ~/.bashrc
#
# It carries a .sh extension rather than being a dotfile so it is picked up by
# the repository-wide `bash -n` and ShellCheck passes for free, the same
# reasoning as linux/bash_aliases.sh.
#
# Every alias is guarded on the script being there. An alias pointing at a
# script that is not installed is worse than no alias: it fails at use time, in
# the middle of something else, with a message about a missing file rather than
# about the alias. So each one is defined only if the script sits next to this
# file, or failing that if its name is on PATH for anyone who copied the
# scripts into ~/bin.
#
# The names avoid the two-letter git aliases in linux/bash_aliases.sh (gs, gd,
# gl, gp, gb) so both files can be sourced by the same shell.

# Sourcing guard: running this file directly does nothing useful, so say so
# rather than exiting silently and leaving someone puzzled.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'git_aliases.sh is meant to be sourced, not run:\n' >&2
  printf '  echo ". %s" >> ~/.bashrc\n' "${BASH_SOURCE[0]}" >&2
  exit 3
fi

_pus_have() { command -v "$1" >/dev/null 2>&1; }

# Resolved once, here, because $PWD at use time says nothing about where this
# file was sourced from.
_pus_git_aliases_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"

_pus_git_alias() {
  local name="$1"
  local script="$2"
  if [ -n "$_pus_git_aliases_dir" ] && [ -x "$_pus_git_aliases_dir/$script" ]; then
    # %q so a checkout under a path with spaces still produces an alias that
    # runs rather than one that splits into a command and an argument.
    alias "$name=$(printf '%q' "$_pus_git_aliases_dir/$script")"
  elif _pus_have "$script"; then
    alias "$name=$script"
  fi
}

# --- committing ------------------------------------------------------------
_pus_git_alias gacp     gacp.sh
_pus_git_alias gamend   git_amend_last.sh
_pus_git_alias gundo    git_undo_last_commit.sh

# --- looking around --------------------------------------------------------
_pus_git_alias gsum     git_status_summary.sh
_pus_git_alias gdiffb   git_diff_branch.sh
_pus_git_alias grecent  git_recent_branches.sh
_pus_git_alias groot    git_repo_root.sh
_pus_git_alias gwho     git_whoami.sh

# --- housekeeping ----------------------------------------------------------
_pus_git_alias gsync    git_sync_default.sh
_pus_git_alias gmerged  git_cleanup_merged.sh
_pus_git_alias ggone    git_prune_gone.sh
_pus_git_alias gstale   git_stale_branches.sh
_pus_git_alias gsize    git_size_report.sh
_pus_git_alias ghooks   git_hooks_install.sh

# --- identity and diagnostics ----------------------------------------------
_pus_git_alias gprofile set_git_profile.sh
_pus_git_alias gssh     git_ssh_doctor.py
_pus_git_alias gsign    git_signing_doctor.py
_pus_git_alias gremote  git_remote_doctor.py

unset -f _pus_git_alias
unset _pus_git_aliases_dir

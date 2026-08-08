# Git helper aliases for zsh.
#
# Usage:
#   source /path/to/ops-toolbox/git/git_aliases.zsh
#
# The bash sibling is git_aliases.sh, with the same names.
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

_pretty_git_aliases_file="${(%):-%N}"
_pretty_git_aliases_dir="${${_pretty_git_aliases_file:A}:h}"

_pretty_git_alias() {
  local name="$1" script="$2"
  if [[ -x "$_pretty_git_aliases_dir/$script" ]]; then
    # ${(q)} so a checkout under a path with spaces still produces an alias
    # that runs rather than one that splits into a command and an argument.
    alias "$name=${(q)_pretty_git_aliases_dir}/$script"
  elif command -v "$script" >/dev/null 2>&1; then
    alias "$name=$script"
  fi
}

# --- committing ------------------------------------------------------------
_pretty_git_alias gacp     gacp.sh
_pretty_git_alias gamend   git_amend_last.sh
_pretty_git_alias gundo    git_undo_last_commit.sh

# --- looking around --------------------------------------------------------
_pretty_git_alias gsum     git_status_summary.sh
_pretty_git_alias gdiffb   git_diff_branch.sh
_pretty_git_alias grecent  git_recent_branches.sh
_pretty_git_alias groot    git_repo_root.sh
_pretty_git_alias gwho     git_whoami.sh

# --- housekeeping ----------------------------------------------------------
_pretty_git_alias gsync    git_sync_default.sh
_pretty_git_alias gmerged  git_cleanup_merged.sh
_pretty_git_alias ggone    git_prune_gone.sh
_pretty_git_alias gstale   git_stale_branches.sh
_pretty_git_alias gsize    git_size_report.sh
_pretty_git_alias ghooks   git_hooks_install.sh

# --- identity and diagnostics ----------------------------------------------
_pretty_git_alias gprofile set_git_profile.sh
_pretty_git_alias gssh     git_ssh_doctor.py
_pretty_git_alias gsign    git_signing_doctor.py
_pretty_git_alias gremote  git_remote_doctor.py

unfunction _pretty_git_alias
unset _pretty_git_aliases_file _pretty_git_aliases_dir

# Git helper aliases for zsh.
#
# Usage:
#   source /path/to/ops-toolbox/git/git_aliases.zsh

_pretty_git_aliases_file="${(%):-%N}"
_pretty_git_aliases_dir="${${_pretty_git_aliases_file:A}:h}"

if [[ -x "$_pretty_git_aliases_dir/gacp.sh" ]]; then
  alias gacp="$_pretty_git_aliases_dir/gacp.sh"
else
  alias gacp='gacp.sh'
fi

unset _pretty_git_aliases_file _pretty_git_aliases_dir

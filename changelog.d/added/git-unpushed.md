- `git/git_unpushed.sh` answers "what would I lose if this clone
  disappeared?" in one report: commits on no remote, branches with no
  upstream, stashes, uncommitted and untracked files, and with `--tags` the
  local tags the remote does not have. `--remote` narrows what counts as
  pushed to one remote, and `--strict` exits 1 while anything exists only on
  this machine, so a decommission script can refuse to delete a clone that
  still holds work.

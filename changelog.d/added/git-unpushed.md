- `git/git_unpushed.sh` answers "what would I lose if this clone
  disappeared?" in one report: commits on no remote, branches with no
  upstream, stashes, uncommitted and untracked files, and with `--tags` the
  local tags the remote does not have or has at a different object.
  `--remote` narrows what counts as pushed to one remote, and `--strict`
  exits 1 while anything exists only on this machine, so a decommission
  script can refuse to delete a clone that still holds work. A remote that
  lists no peeled `NAME^{}` line for an annotated tag is compared on the tag
  object alone, so a matching tag is not reported.
  A check that could not run (`git status` failing, or `--tags` unable to
  reach the remote) prints `incomplete: could not check ...` instead of
  claiming nothing exists only on this machine.

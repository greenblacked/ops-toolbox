- `git/git_repos_status.sh` reports every checkout under one or more
  directories on one screen: branch, ahead and behind, changed paths, stashes
  and commits that no remote has, with a summary of how many hold work that
  exists only on this machine. `--strict` exits 1 while any of it does, which
  makes the report a safe-to-wipe gate before re-imaging a laptop, and
  `--fetch` refreshes (and prunes) remote-tracking refs first; a failed
  fetch counts as work at risk.

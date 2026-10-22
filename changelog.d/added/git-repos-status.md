- `git/git_repos_status.sh` reports every checkout under one or more
  directories on one screen: branch, ahead and behind, changed paths, stashes
  and commits that no remote has, with a summary of how many hold work that
  exists only on this machine. `--strict` exits 1 while any of it does, which
  makes the report a safe-to-wipe gate before re-imaging a laptop, and
  `--fetch` refreshes (and prunes) the remote-tracking refs of every
  remote first; a fetch failing on any remote counts as work at risk, and
  so does a history walk that fails (a missing or unreadable object), noted
  `walk-failed`, and a stash list that fails (a damaged `refs/stash`),
  noted `stash-failed`. A row that could
  not be checked (also a failed `git status`, noted `status-failed`, or an
  `unreadable` checkout) is kept under every `--only` filter, so none can
  hide it from `--strict`.

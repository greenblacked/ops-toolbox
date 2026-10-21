- `git/clone-repos.sh` gains `--update`: a checkout from the list that is
  already there is fetched and fast-forwarded on its current branch instead
  of skipped, so one command brings the whole list up to date. A checkout
  with a detached HEAD, no upstream, modified tracked files, a `git status`
  that cannot be read or a diverged branch is held and reported, never merged
  into, stashed or switched, and a held checkout does not fail the run.

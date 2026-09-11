- `.gitignore` re-included the whole `.claude/hooks/` directory rather than
  the two files that are tracked, so a scratch hook written there showed up
  as untracked and could be swept into a `git add -A`.

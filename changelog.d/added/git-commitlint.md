- `git/git_commitlint.sh` lints every commit message a pull request adds,
  so the Conventional Commit rule the local commit-msg hook enforces also
  holds in CI, where `git commit --no-verify` cannot skip it. Beyond the
  subject pattern it reports subjects over `--max-subject`, a missing blank
  line before the body, unsquashed fixup commits, and messages matching a
  `--forbid` pattern; every problem of every commit is listed, and merge
  commits are left alone.

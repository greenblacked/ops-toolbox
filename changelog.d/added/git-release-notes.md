- `git/git_release_notes.sh` turns the commits since the last tag into
  release notes grouped by Conventional Commit type, breaking changes first,
  as text or with `--format` markdown ready to paste into a release or a
  change ticket. Subjects that follow no convention land under Other rather
  than disappearing, merge commits are left out, and `--next-version` prints
  the semver bump the commits imply. A `--from` that is not an ancestor of
  `--to` is refused instead of listing the whole history.

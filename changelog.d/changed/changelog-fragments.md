- New changelog entries are files under `changelog.d/<type>/`, one per
  change, instead of edits to the top of `[Unreleased]` in `CHANGELOG.md`.
  Every pull request inserted at the same line, so any two open at once
  conflicted the moment one merged; the four open on one day cost six
  resolutions and a CI cycle each. `changelog.d/changelog.sh preview` prints
  the section as it will read, `check` validates every fragment and runs in
  the static suite, and `release VERSION` moves the fragments and the
  entries still in `[Unreleased]` under a dated version heading and deletes
  the fragment files. The entries already in `[Unreleased]` stay where they
  are until the first release moves them.

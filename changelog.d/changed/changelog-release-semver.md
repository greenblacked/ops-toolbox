- `changelog.sh release` accepts only a `MAJOR.MINOR.PATCH` version newer than
  the latest one already in `CHANGELOG.md`. It used to take any single token,
  so `1.0`, `v1.0.0` or a version below the last release would each have been
  written as a section heading, and the version is now also a tag name. The
  comparison is numeric per field, so `1.10.0` counts as newer than `1.9.0`.
  Pre-release suffixes are refused rather than ordered wrongly.

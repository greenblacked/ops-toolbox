- Releases are tagged. `.github/workflows/release.yml` cuts one in two steps:
  run by hand with a version, it runs `changelog.sh release` on a
  `chore/release-<version>` branch and opens that as a pull request; merging
  it tags the merge commit `v<version>` and publishes a GitHub Release whose
  notes are the version's section of this file. Only the push that adds a
  version's heading is tagged, so a later edit here never moves a release, and
  notes too long for a release description are linked and attached instead of
  failing the publish. Until now the repository had no tag at all, and
  `changelog.d/README.md` described tagging as a command to remember to type.
- `changelog.sh latest` prints the newest released version and `changelog.sh
  notes VERSION` prints that version's section, so the workflow reads
  `CHANGELOG.md` through the tested script instead of parsing it itself.

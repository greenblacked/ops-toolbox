- Every binary CI downloads is now checked against the SHA-256 recorded in
  `.github/ci-tool-checksums.env` before it is unpacked or installed, and the
  step fails on a mismatch. That file declared itself the source of truth for
  these digests and warned in its own header that a version pin without a digest
  still trusts whoever answers the URL — while nothing in the tree read it. A
  search for its name returned the file and nothing else, so ShellCheck,
  actionlint, Hadolint, kubeconform and ruff were each installed on a version
  pin alone, and the two Darwin digests recorded for the `macos-native` job had
  never once been compared against anything. The Ubuntu jobs verify with
  `sha256sum -c` and the macOS job with `shasum -a 256 -c`, since GNU coreutils
  is not part of the macOS base system; the macOS step selects its digest by
  runner architecture alongside the asset, so the two cannot disagree.
- `test-env/static/check_conventions.sh` asserts that the `env:` block of
  `.github/workflows/ci.yml` and `.github/ci-tool-checksums.env` name the same
  tools at the same versions, and that every digest recorded there is named by a
  step in the workflow. A bump that edited a version in one file and forgot the
  other used to be invisible in review and silent until a job installed the
  tool; it now fails the static suite naming both values. yamllint and
  PSScriptAnalyzer arrive through pipx and Install-Module rather than as release
  downloads, and are declared as such in the digest file itself rather than
  exempted inside the test.

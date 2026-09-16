- `LINT_FETCH=1 ./run-tests.sh lint` can install actionlint and Hadolint on a
  Mac. Both fetchers asked for the `linux_amd64` asset whatever
  machine was asking, and `.github/ci-tool-checksums.env` recorded a digest for
  that platform alone, so on macOS the two were skipped as uninstallable and
  the local suite ran one linter of six — on the platform most likely to be
  running it. ShellCheck beside them had chosen its asset per platform all
  along. The digests for the macOS builds come from each project's published
  checksums file, including Hadolint's, which this repository had recorded as
  not existing and had therefore been pinning to a hash of its own download.
  The review-time check that every digest is read by something now counts
  `test-env/lint/run.sh` as a reader alongside `ci.yml`, deriving the tools and
  platforms it covers from the runner itself; a digest nothing fetches still
  fails.

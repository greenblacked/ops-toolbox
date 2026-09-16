- `./run-tests.sh lint` runs, locally, what CI's `Lint` job runs: `bash -n`,
  ShellCheck (both passes), actionlint, Hadolint, PSScriptAnalyzer, yamllint
  and markdownlint-cli2, at the versions pinned in
  `.github/ci-tool-checksums.env` and `ci.yml`. Those seven had no local entry
  point at all, which is how a changelog fragment reached a pull request with a
  markdownlint violation while the linter sat installed on the same machine. A
  missing or differently-versioned tool is a named skip, a run in which no
  linter ran fails, every zero-file case fails, and nothing is fetched unless
  `LINT_FETCH=1` — the three release binaries are then verified against the
  recorded digests. The `Lint` job now calls the suite instead of carrying its
  own copy of each invocation, and markdownlint-cli2 is pinned by version
  (`MARKDOWNLINT_VERSION`) rather than only by the action SHA that wrapped it.

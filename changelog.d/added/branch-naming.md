- Branch names follow one convention, `<type>/<slug>` with the type one of
  `feat`, `fix`, `docs`, `ci`, `test`, `perf`, `refactor`, `deps` or
  `release`, written down in `CONTRIBUTING.md` and enforced by the new `Branch
  name` workflow through `test-env/static/check_branch_name.sh`. `chore/` is
  gone: the RouterOS version workflow now opens `deps/routeros-<version>`
  titled `deps(mikrotik): ...`, the Release workflow opens
  `release/<version>` titled `release: <version>`, and Dependabot's commits
  use the `deps` prefix. A pull request title opening with a `chore` type is
  refused, because a squash merge makes it the commit subject on `master`.
  The `pull_request` target filters in `ci.yml`, `chr.yml` and `security.yml`
  now list every type. Before, a pull request stacked onto a `docs/`,
  `test/`, `perf/` or `refactor/` branch ran no checks at all and merged
  green.

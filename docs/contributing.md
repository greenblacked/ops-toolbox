# Contributing

Contributions are welcome, but this is a personal toolkit with a single
maintainer: there is no response-time commitment. The authoritative rules live
in the repository, not on this site.

- [CONTRIBUTING.md](https://github.com/greenblacked/ops-toolbox/blob/master/CONTRIBUTING.md)
  holds the script conventions and the checklist for new work.
- [Code of conduct](https://github.com/greenblacked/ops-toolbox/blob/master/CODE_OF_CONDUCT.md)
- [Security policy](https://github.com/greenblacked/ops-toolbox/blob/master/SECURITY.md)
  explains how to report a vulnerability.
- [Templates](https://github.com/greenblacked/ops-toolbox/tree/master/templates)
  contain working starting points for Bash, PowerShell and Python.

## The one rule

!!! note "A script should work when copied alone into ~/bin"
    That is why helper code is duplicated between scripts on purpose. Do not
    factor shared code into a sourced library. The exceptions are scripts that
    ship with data or helpers they need. See
    [Philosophy](getting-started/philosophy.md#modularity).

## Workflow in short

1. Branch from `master` using `<type>/<slug>`, for example `docs/mkdocs-site`.
2. Copy a template, put the script in the package it belongs to, and
   `chmod +x` it and `git add` it.
3. Run `./run-tests.sh static` and the suite for your package. See
   [Testing](contributing/testing.md).
4. Update the folder README and the root README row, and add a changelog
   fragment.
5. Open a pull request into `master`.

[Development conventions](contributing/development.md){ .md-button }
[Testing](contributing/testing.md){ .md-button }

## Not user-facing

These repository folders are for contributors and are not platform pages:
`templates/` (starting points for new scripts), `test-env/` (test runners and
fixtures) and `.github/` (workflows).

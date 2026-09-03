# test-env

Test machinery that does not live inside a script package. Two different kinds
of thing share this folder, and the difference matters:

[`CONTRIBUTING.md`](../CONTRIBUTING.md) describes how to work with all of this
— the suite table, the hand-rolled harness style, and the defects that shaped
what a test here has to assert.

| Path | What it is | Run by `./run-tests.sh`? |
| --- | --- | --- |
| [`static/`](static/) | The repository-wide convention checks (`./run-tests.sh static`) | **yes**, and by CI |
| [`python/`](python/) | The unit tests for the Python helpers (`./run-tests.sh python`) | **yes**, and by CI |
| [`lib/`](lib/) | `discover_clis.sh`, the "which tracked files are command-line scripts" rule | sourced by `static/check_conventions.sh` and `static/test_doc_citations.sh`; the python suite does not use it |
| [`chef/`](chef/) | A self-contained Chef cookbook sandbox | **no** |
| [`go/`](go/) | A self-contained Go sandbox | **no** |

## The suites that run

**[`static/`](static/)** — `check_conventions.sh`, the two RouterOS checks that
need no Docker, `test_run_tests.sh` for the aggregator's own contract, and
`test_doc_citations.sh` for the documentation ones. It discovers its own subjects from the git index rather
than keeping a list, so a new script is covered by the commit that adds it:
the `--help` and unknown-flag contracts, shebangs, file modes, `.gitattributes`
coverage, Bash 3.2 constructs, the deliberately-duplicated blocks, and the
dry-run promise checked against the filesystem. **No Docker and no network.**
Almost all of it is bash + git; the one exception is the `.winget`
configuration shape check, which shells out to `python3` with PyYAML and
prints a `warn` and skips if either is missing.

**[`python/`](python/)** — `run.sh` runs the helpers' unit tests under stdlib
`unittest` with whichever `python3` it finds (`/usr/bin/python3` on macOS,
because that is the interpreter the shell scripts call), then `ruff check` over
the repository if ruff is installed and says it skipped the lint if not. There
is **no Docker image, no `justfile` and no dev container here** — the modules
under test import nothing outside the standard library, so the sandbox one
would provide buys nothing.

Both are called through [`../run-tests.sh`](../run-tests.sh), which CI calls in
turn, so a green run locally and a green run in CI mean the same thing.

## The sandboxes that do not

`chef/` and `go/` are **local playgrounds for writing Chef cookbooks and Go
code**, kept here because they are useful and self-contained. They are not part
of this repository's test run:

- `./run-tests.sh` has no `chef` or `go` suite. Nothing in
  [`.github/workflows/`](../.github/workflows/) invokes their `run.sh` or their
  `just ci`. Those run when you run them, on your machine, with Docker up.
- What CI *does* cover is the scaffolding as text, through the repository-wide
  lint job: ShellCheck over every tracked `*.sh` (so both `run.sh` files),
  yamllint over the compose and config YAML, markdownlint over the READMEs.
  The `Dockerfile`s are linted by `just lint-env` inside the sandbox and by
  pinned Hadolint over every tracked Dockerfile in repository CI. The
  language/tool runtime checks below remain opt-in.

So a change to `chef/` or `go/` that breaks a converge or a test will not be
caught by opening a pull request. Run `just ci` in the folder you touched.

Both share the same shape: a Docker runner (`run.sh` with
`up`/`down`/`logs`/`ps`/`shell`, `--once`, `--rebuild`), a `justfile` of
shortcuts, a dev container reusing the same image, and two layers of linting —
the target code (Cookstyle, golangci-lint) and the scaffolding itself
(`shellcheck`, `hadolint`, `yamllint`, exposed as `just lint-env` and included
in `just ci`).

### Chef (`chef/`)

Chef Infra cookbook toolchain in one place: [Test Kitchen](https://kitchen.ci/)
with the [kitchen-dokken](https://github.com/test-kitchen/kitchen-dokken)
driver, so converges run in containers on the host's Docker socket, plus
Cookstyle for lint, ChefSpec for unit tests and InSpec for integration. Full
commands, layout table, and cookbook authoring notes:
**[`chef/README.md`](chef/README.md)**.

### Go (`go/`)

Go 1.23 in Docker with **golangci-lint**, **goimports** and **govulncheck**;
module and build caches live in named volumes so rebuilds are fast. Details and
layout table: **[`go/README.md`](go/README.md)**.

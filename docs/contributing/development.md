# Development

<!-- markdownlint-disable MD046 -->

A summary of the conventions in
[CONTRIBUTING.md](https://github.com/greenblacked/ops-toolbox/blob/master/CONTRIBUTING.md).
If this page and that file disagree, the file wins.

## Branch names

A branch is `<type>/<slug>`. The slug uses lowercase letters, digits, `.`, `_`
and `-`.

| Type | For |
| --- | --- |
| `feat/` | A new script, flag or behavior. |
| `fix/` | A bug fix. |
| `docs/` | Documentation only. |
| `ci/` | Workflows, linters, the static suite. |
| `test/` | Tests only. |
| `perf/` | Faster, same behavior. |
| `refactor/` | Same behavior, different shape. |
| `deps/` | A version bump: a pinned tool, image or RouterOS release. |
| `release/` | A release pull request, `release/<MAJOR.MINOR.PATCH>`. |

There is no `chore/` type, and tool-named prefixes are refused. Check a name
with `test-env/static/check_branch_name.sh BRANCH`.

## Changelog fragments

Each change ships one file under `changelog.d/<type>/` (for example
`changelog.d/added/clone-repos.md`), written as it will appear in the
changelog: a list item, continuation lines indented two spaces. Check with
`changelog.d/changelog.sh check`. See the
[fragment guide](https://github.com/greenblacked/ops-toolbox/blob/master/changelog.d/README.md).

## Scripts

Bash
:   Line 1 is `#!/usr/bin/env bash`, line 2 a comment saying what the script is
    for. Scripts in `git/`, `macos-initial-setup/`, `linux/` and `dotfiles/`
    must parse under Bash 3.2: no `mapfile`, no `declare -A`, no `${x,,}`.

Dry runs
:   `--dry-run` is an integer flag (`DRY_RUN=0`, set to `1`), tested in
    arithmetic context. A dry run must write nothing.

Help
:   Every script answers `--help` with exit 0, and an unknown flag exits 3.

PowerShell
:   Scripts use `-DryRun` and `-Yes`; start from `templates/new_script.ps1`.

RouterOS
:   Scripts are pasted into `/system script`. Avoid underscores in `:global`
    and `:local` names, which RouterOS 7.24 refuses.

Python
:   Standard library only, Python 3.9+, checked with `ruff`.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, including every `--help`. |
| `1` | Generic failure. |
| `2` | Wrong environment or failed preflight. |
| `3` | Invalid usage. |
| `4` | Domain no-op. |
| `5` | Reserved to `gacp.sh`. |

## Documentation site

The site you are reading is built with MkDocs and the Material theme. Its
source is `docs/` and `mkdocs.yml` at the repository root.

!!! warning "Links"
    Inside `docs/`, link to other pages with relative links. Anything outside
    `docs/` must be an absolute GitHub URL, because the repository's link
    checker resolves relative links and MkDocs strict mode rejects links that
    leave `docs/`. Do not write line-number citations such as a file name
    followed by a colon and a number.

The Roadmap and Changelog pages are filled from `ROADMAP.md` and `CHANGELOG.md`
at build time by a hook in `docs/hooks/`, so edit those root files, not the
pages.

### Preview locally

```bash
python3 -m venv .venv
.venv/bin/pip install -r docs/requirements.txt
.venv/bin/mkdocs serve
```

Open <http://127.0.0.1:8000>. Check for warnings before opening a pull request;
CI runs the same strict build on every pull request that touches the site:

```bash
.venv/bin/mkdocs build --strict
```

The build writes `site/`, which is ignored by Git.

### Deploy

The site is hosted at <https://ops.szolotov.com>. A push to `master` updates
the stage preview and a release deploys production; both are done by CI, not
by hand. [Deployment](deployment.md) has the flow, the setup, the commands and
the rollback steps. (`mkdocs gh-deploy` still works for a fork that wants
GitHub Pages.)

!!! tip "Last updated dates"
    The "last updated" date on each page comes from Git history. A shallow
    clone has none, so the build falls back to the build date. The
    CI workflow fetches full history for accurate dates.

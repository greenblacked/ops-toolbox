# Docs hooks

[Ops Toolbox](../../README.md) / **Docs hooks**

MkDocs hooks for the documentation site configured in `mkdocs.yml`. They run
only while the site is built; nothing here is a command-line tool.

| File | Purpose |
| --- | --- |
| `repo_files.py` | Fills the Roadmap and Changelog pages from `ROADMAP.md` and `CHANGELOG.md` at build time, so the site never holds a second copy. |

The hook replaces a marker comment in the page with the root file, drops that
file's title and breadcrumb line, and rewrites relative links to absolute
GitHub URLs on `master`. The `exclude_docs` setting in `mkdocs.yml` keeps this
folder out of the published site.

Only root files listed in the `ALLOWED` set in `repo_files.py` can be
included; any other name in a marker fails the build with an error naming the
marker and the page. To include another root file, add its name to `ALLOWED`
and put the marker in the page.

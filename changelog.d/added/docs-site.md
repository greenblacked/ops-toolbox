- A documentation site, built with MkDocs and the Material theme from `docs/`
  and `mkdocs.yml`. It has a quick start, the report, preview and apply
  philosophy, one page per platform, a table of the main scripts, testing
  and contributing guides, and the roadmap and changelog rendered from the
  root files at build time so they cannot drift. The build tools are pinned
  in `docs/requirements.in` and hash-locked with their dependencies in
  `docs/requirements.txt`, and `README.md` and `CONTRIBUTING.md` show how
  to preview it locally. The `docs.yml` workflow builds it on pull requests
  and deploys it with wrangler as one Cloudflare Worker (`worker/`): a push to
  `master` updates the stage preview at <https://stage.ops.szolotov.com>, and a
  release, or a manual run with a `v*` tag, deploys <https://ops.szolotov.com>,
  rolling back if its smoke test fails.

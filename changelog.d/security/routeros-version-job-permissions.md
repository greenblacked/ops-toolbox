- `.github/workflows/routeros-version.yml` declared `actions: write`,
  `contents: write` and `pull-requests: write` at the workflow's top level,
  where every job in the file inherits them — and this is the one workflow
  here that can push a commit and open a pull request. The scopes are genuinely
  needed by `check-test-and-propose`, so they moved to that job instead of
  being removed; the top level is now `permissions: {}`. A job added to this
  workflow later starts with no access rather than three write scopes nobody
  granted it on purpose.

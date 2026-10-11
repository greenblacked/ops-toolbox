- `release.yml` now dispatches `security.yml` and `branch-name.yml` on the
  release branch next to `ci.yml`, and `branch-name.yml` accepts a manual
  dispatch (it reads the branch from the ref and skips the title check, which
  needs a pull request). The release pull request is opened with
  `GITHUB_TOKEN`, which starts no checks, so "Branch name", "Repository secret
  scan", "CodeQL (actions)" and "CodeQL (python)" never ran and the pull
  request stayed blocked.

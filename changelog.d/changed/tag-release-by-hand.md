- Releasing is now three steps, and merging the release pull request no longer
  tags or deploys production. `release-prepare.yml` pushes a
  `release/<version>` branch with the `release: <version>` commit and opens no
  pull request, so a person opens it and it gets its checks. Merging it deploys
  stage like any change. `release.yml`, run by hand from `master`, then checks
  that CI and Security passed on `master`'s HEAD, tags it `v<version>`, creates
  the GitHub Release and deploys production.

- Feature branches now open pull requests into a long-lived `dev` branch.
  A push to `dev` runs CI and Security, and one that touches the site also
  runs the docs build, which uploads the built site as the `site-preview`
  artifact for a private preview, with no deploy and no secrets (a manual
  run on `dev` builds it too). Merging `dev` into `master` still deploys
  the stage site, and a release is still cut from `master`. Dependency
  pull requests target `dev`, the RouterOS bump included. The heading
  anchors (the pilcrow links) are removed from the documentation site.

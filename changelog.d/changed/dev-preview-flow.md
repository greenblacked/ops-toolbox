- Feature branches now open pull requests into a long-lived `dev` branch.
  A push to `dev` runs CI, Security and the docs build, and the docs build
  uploads the built site as the `site-preview` artifact for a private
  preview, with no deploy and no secrets. Merging `dev` into `master` still
  deploys the stage site, and a release is still cut from `master`.
  Dependency pull requests target `dev`. The heading anchors (the pilcrow
  links) are removed from the documentation site.

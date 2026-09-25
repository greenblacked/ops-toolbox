- `.github/dependabot.yml` now sets `cooldown: default-days: 7` on both the
  `github-actions` and `docker` ecosystems. Every action here is already
  pinned to a commit SHA and every base image to a version tag, watched by
  Dependabot rather than left to rot — but a same-day bump still adopts a
  release before anyone has had a chance to notice it was compromised. A
  seven-day wait does not weaken the pin, it delays what replaces it.
  `default-days` is the only cooldown key set here — the `semver-*-days`
  variants are documented as applying only to package managers that support
  SemVer, and neither github-actions nor docker resolves its version that
  way (actions read a ref, docker reads a tag), so those keys are left
  unset rather than added on an unconfirmed guess at what setting them
  would do.

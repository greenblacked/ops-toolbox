- `.github/dependabot.yml` now sets `cooldown: default-days: 7` on both the
  `github-actions` and `docker` ecosystems. Every action here is already
  pinned to a commit SHA and every base image to a version tag, watched by
  Dependabot rather than left to rot — but a same-day bump still adopts a
  release before anyone has had a chance to notice it was compromised. A
  seven-day wait does not weaken the pin, it delays what replaces it, and
  `default-days` is the only cooldown key either ecosystem accepts — the
  `semver-*-days` variants are rejected for both, since neither resolves a
  version as semver.

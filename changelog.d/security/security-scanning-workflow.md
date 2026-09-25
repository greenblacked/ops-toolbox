- Added `.github/workflows/security.yml`. Nothing before it scanned this
  repository for a committed credential, a workflow that lets untrusted input
  reach a `run:` block, or a dependency pulled in the day it was published —
  `ci.yml`'s `Lint` job checks that a script or workflow is well formed, not
  that it is safe. The new workflow scans the working tree for secrets with
  Trivy and gates on a hit, scans git history for secrets with gitleaks and
  reports rather than gates (a history finding needs a rewrite plus rotation,
  not a blocked pull request), audits the workflows with zizmor, runs CodeQL
  over the `actions` and `python` languages — the only two this repository has
  anything for — and runs OpenSSF Scorecard against `master` on a schedule.
  SARIF from every tool lands in the Security tab.

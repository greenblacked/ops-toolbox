- Added `.github/workflows/security.yml`. Nothing before it scanned this
  repository for a committed credential, a workflow that lets untrusted input
  reach a `run:` block, or a dependency pulled in the day it was published —
  `ci.yml`'s `Lint` job checks that a script or workflow is well formed, not
  that it is safe. The new workflow scans the working tree for secrets with
  Trivy and gates on a hit, scans git history for secrets with gitleaks
  (`--no-color`, its stderr-only summary line captured too) and reports
  rather than gates (a history finding needs a rewrite plus rotation, not a
  blocked pull request; the two fixture matches already in history are
  suppressed via `.gitleaksignore`), audits the workflows with zizmor —
  online, via `GH_TOKEN`, so its token-gated audits such as
  `impostor-commit` actually run, and a failure to run zizmor at all now
  fails the job instead of a swallowed `|| true` — runs CodeQL over the
  `actions` and `python` languages (Go and Ruby are also CodeQL-supported
  here, but exist only as `test-env/` fixtures and are left out on
  purpose), and runs OpenSSF Scorecard against `master` only, on a
  schedule — gated on `github.ref` as well as the event, since
  `workflow_dispatch` from any other branch is a scan Scorecard itself
  refuses to run. SARIF from every tool lands in the Security tab.

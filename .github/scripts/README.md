# Workflow scripts

[Ops Toolbox](../../README.md) / **Workflow scripts**

Helpers that the GitHub Actions workflows run with `bash`. They are not
command-line tools: they read their input from environment variables set by
the workflow, so they have no `--help` and are not executable.

## `stage-stale.sh`

Decides whether a stage deploy is stale, that is, whether the stage address
already serves a commit that includes the build's own. `docs.yml` runs it
twice: in the `check-stage` job and again in the `deploy` job. It writes
`stale=true` or `stale=false` to `GITHUB_OUTPUT`.

It fails closed. It reads `version.txt` and, if needed, compares commits with
`gh api`, retrying each a few times with a growing pause. Only an
HTTP 404 from `version.txt` (nothing deployed yet) means deploy. Any other
failure after the retries (including a `curl` transfer error after a 200
header), an empty body, a body that is not a 40-character SHA, or a live commit
the repository does not know, prints an `::error::` and exits non-zero, so the job
fails and nothing is deployed; re-run the workflow later. See
[Deployment](../../docs/contributing/deployment.md).

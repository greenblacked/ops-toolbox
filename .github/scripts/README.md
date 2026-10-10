# Workflow scripts

[Ops Toolbox](../../README.md) / **Workflow scripts**

Helpers that the GitHub Actions workflows run with `bash`. They are not
command-line tools: they read their input from environment variables set by
the workflow, so they have no `--help` and are not executable.

## `stage-stale.sh`

Decides whether a stage deploy is stale, that is, whether the stage address
already serves a commit that includes the build's own. `docs.yml` runs it
twice: in the `check-stage` job and again in the `deploy` job. It writes
`stale=true` or `stale=false`, and `skip=true` or `skip=false` (the stage
deploy must not run), to `GITHUB_OUTPUT`. `docs.yml` gates on `skip`.

It fails closed. It reads `version.txt` and, if needed, compares commits with
`gh api`, retrying each a few times with a growing pause. An HTTP 404 from
`version.txt` means nothing is deployed yet, so deploy. A stage host that does
not resolve (`curl` exit 6) on every attempt, with a DNS lookup confirming
NXDOMAIN, means stage does not exist yet (observed: the stage hostname has no
DNS record before the first production deploy, and the Worker may not exist
either) AND the production host (`PRODUCTION_URL`) is also confirmed NXDOMAIN,
so production was never deployed: the script sets `skip=true` and
`reason=no-stage-host`, prints a notice to deploy production first, and exits
0. The deploy job is skipped (or, in its second run of the check, wrangler and
the smoke test are), so the run stays green; after production, the next push
to `master` deploys stage. If production resolves (NOERROR, even without an
answer, since NODATA means the name exists) while stage is NXDOMAIN, the stage
record was lost: the script prints an `::error::` ("stage has no DNS record
although production exists") and exits non-zero. A resolver failure that
recovers on a later attempt takes the normal path; SERVFAIL, a timeout or a
missing `dig` (for stage or for the production lookup) fail closed. Any other
failure after the retries (including a `curl` transfer error after a 200
header), an empty body, a body that is not a 40-character SHA, or a live
commit the repository does not know, prints an `::error::` and exits non-zero,
so the job fails and nothing is deployed; re-run the workflow later. See
[Deployment](../../docs/contributing/deployment.md).

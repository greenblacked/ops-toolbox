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
the host has no address (NXDOMAIN, or NOERROR with no A and no AAAA record, i.e.
NODATA, which is how Cloudflare-hosted DNSSEC zones answer a nonexistent name:
compact denial of existence, RFC 9824), means stage does not exist yet (observed: the stage hostname has no
DNS record before the first production deploy, and the Worker may not exist
either) AND GitHub has recorded no successful production deployment (the
`deploy` job enters the `production` environment, so each production deploy is a
deployment there; read with `gh api repos/$REPO/deployments?environment=production`
and each deployment's `/statuses`, which needs only `deployments: read`; a
release tag cannot serve, because `release.yml` pushes it before the production
deploy): the script sets `skip=true` and `reason=no-stage-host`, prints a
notice to deploy production first, and exits 0. The skip therefore applies
until production has a successful deployment, which covers the stage run of the
first release push and a first production deploy that is still running or
failed (a failed run, including a smoke test that was rolled back, ends with a
failure status). The deploy job is skipped (or, in its second run of the check,
wrangler and the smoke test are), so the run stays green; after production, the
next push to `master` deploys stage. Once a production deployment has
succeeded, a stage host without DNS means the Custom Domain or its preview
wildcard was lost: the script prints an `::error::` ("production was deployed
(deployment ID for SHA) but ... has no DNS record") and exits non-zero. The
REST docs promise no order for the lists, so deployments are walked until one
has any `success` status. A failed deployments or statuses lookup fails
closed. A resolver failure that
recovers on a later attempt takes the normal path; SERVFAIL, REFUSED, a timeout, a
missing `dig`, or NOERROR with an A or AAAA answer while `curl` cannot resolve
(inconsistent) fail closed. Any other
failure after the retries (including a `curl` transfer error after a 200
header), an empty body, a body that is not a 40-character SHA, or a live
commit the repository does not know, prints an `::error::` and exits non-zero,
so the job fails and nothing is deployed; re-run the workflow later. See
[Deployment](../../docs/contributing/deployment.md).

# Deployment

The documentation site is built with MkDocs and served by one Cloudflare
Worker, `ops-toolbox` (the [`worker/`](https://github.com/greenblacked/ops-toolbox/tree/master/worker)
folder). The workflow is
[`docs.yml`](https://github.com/greenblacked/ops-toolbox/blob/master/.github/workflows/docs.yml).

## The flow

| Event | What happens | Where | GitHub environment |
| --- | --- | --- | --- |
| Pull request touching the site | `mkdocs build --strict`, then `wrangler deploy --dry-run`. No secrets, nothing deployed. | Nowhere | none |
| Push to `master` | Build, then a Worker Preview named `stage`. | <https://stage.ops.szolotov.com> | `staging` |
| Release published | Build the tag, deploy, smoke-test, roll back on failure. | <https://ops.szolotov.com> | `production` |
| Run workflow, *Use workflow from* a `v*` tag | The same production deploy, to promote or redeploy a release by hand. | <https://ops.szolotov.com> | `production` |

"Touching the site" means `docs/`, `mkdocs.yml`, `worker/`, `ROADMAP.md`,
`CHANGELOG.md`, `docs.yml` itself or `.github/scripts/stage-stale.sh`.

Every build writes `site/version.txt` holding the commit SHA. After a deploy
the workflow fetches `version.txt` from the live address and waits until it
matches, so the new version is told from the old one. The stage preview must
answer `X-Robots-Tag: noindex`, and production must not. Before it deploys
stage, a run reads the commit stage serves; if that commit already includes the
run's own, the run succeeds without deploying, so an older build that finishes
last never replaces newer content on stage. The check fails closed: only a
stage with nothing deployed yet (`version.txt` answers 404 or is empty) counts
as "unknown, so deploy". If it cannot read or compare the live version after a
few retries, the run fails and deploys nothing. The check runs twice. In its own
job it catches a stale run before the run enters the `staging` environment, so
GitHub records no deployment. It runs again as the first step of the deploy
job, because a run can pass the first and then queue behind a newer deploy in
the environment's concurrency group. A run caught only by that second check has
already entered the environment: it deploys nothing and skips the rest of the
job, but GitHub records a successful `staging` deployment for its commit, so the
environment can show an older commit as the latest while stage serves newer
content. Trust the stage address, not that record, for what stage serves.
Production is not affected.

!!! note "Why the release workflow calls the deploy"
    The release workflow creates the tag and the GitHub Release with the
    built-in `GITHUB_TOKEN`, and events created by that token start no other
    workflow. A deploy triggered by "release published" would never run, so
    `release.yml` calls `docs.yml` as a reusable workflow after its publish
    job succeeds. It does so only for the run that created the tag. A later
    edit to `CHANGELOG.md`, or a re-run once the tag exists, deploys nothing
    to production; promote the tag by hand then.

No checkout in the workflow uses a ref taken from an input or computed in a
step; every one checks out `github.sha`, which cannot move. This is what CodeQL's
"Cache poisoning via execution of untrusted code" check asks for, since the
build installs packages with pip and npm. So a tag is never checked out; it is
checked against the commit the run started on:

- **Release workflow.** `docs.yml` runs at the commit the publish job tagged.
  The build asserts that `refs/tags/<tag>` resolves to exactly that commit and
  fails otherwise.
- **Manual promote.** There is no tag input. Start the run from the tag: *Actions,
  Docs, Run workflow, Use workflow from: tag `vX.Y.Z`*. Starting from a branch
  fails with a message asking for a `v*` tag. The workflow file that runs is the
  one on that tag, so an old tag redeploys with its own version of the
  workflow.

Either way the tag must match `v1.2.3` and its commit must be on `master`.

## One-time setup

### Cloudflare

1. Add the `szolotov.com` zone to the Cloudflare account.
2. Create an API token for the deploy. It needs to edit Workers scripts on the
   account and to manage Workers routes, DNS records and zone settings on the
   `szolotov.com` zone, because deploying a Custom Domain creates DNS records
   and certificates. Verify the exact permission names against the Cloudflare
   documentation for Workers Custom Domains and Worker Previews before you
   create the token; they have been renamed before.
3. Note the account ID.

The first production deploy creates the `ops.szolotov.com` Custom Domain and
the wildcard that serves previews one level below it. A deploy replaces the
Worker's whole set of Custom Domains, so one added only in the dashboard is
detached.

### GitHub

Create two environments under *Settings, Environments*:

| Environment | Used by | Recommended protection |
| --- | --- | --- |
| `staging` | Push to `master` | Deployment branches: `master` only. |
| `production` | Release or manual run | Deployment branches and tags: branch `master` and tag pattern `v*`; required reviewers. |

On each environment add the secret `CLOUDFLARE_API_TOKEN` and the variable
`CLOUDFLARE_ACCOUNT_ID` (a secret of that name also works). Only the wrangler
steps read the token. Pull requests, forks included, never get it.

A production run has one of two refs: `master`, for the release workflow (it
runs on a push to `master`), or a `v*` tag, for a manual promote. The
`production` environment's deployment rules must therefore allow the branch
`master` and the tag pattern `v*`. Without the tag rule a manual run fails when
it asks for the environment.

Allowing tags means a workflow file on any pushed `v*` tag can reach the token,
so also protect the tags: add a tag ruleset (*Settings, Rules, Rulesets*) for
`v*` that restricts who may create, update and delete them (and blocks force
pushes), and keep required reviewers on `production`. Then only a trusted
person can make a tag that runs, and a reviewer approves each production deploy
before the token is released.

## Local commands

Preview the pages while you write:

```bash
python3 -m venv .venv
.venv/bin/pip install -r docs/requirements.txt
.venv/bin/mkdocs serve
```

Build exactly as CI does, then run the Worker on top of the result:

```bash
.venv/bin/mkdocs build --strict
cd worker
npm ci --ignore-scripts
npx wrangler dev                   # http://localhost:8787
npx wrangler deploy --dry-run      # checks the Worker, needs no account
```

`mkdocs gh-deploy` still publishes a build to GitHub Pages for a fork, but
this repository does not use it.

## Check a deploy

```bash
curl -sSI https://stage.ops.szolotov.com/ | grep -i 'x-robots-tag\|x-frame-options'
curl -sS https://stage.ops.szolotov.com/version.txt
curl -sSI https://ops.szolotov.com/
curl -sS https://ops.szolotov.com/version.txt
```

- `version.txt` holds the SHA of the deployed commit.
- `X-Robots-Tag: noindex` appears on stage and not on production.
- Both answer with `X-Content-Type-Options`, `Referrer-Policy` and
  `X-Frame-Options`.
- An unknown path answers 404 with the site's 404 page.

## Roll back

- **Production, automatic.** If `version.txt` does not show the new SHA within
  five minutes, or the site answers wrongly, the workflow rolls back to the
  version it recorded before deploying and still fails the run.
- **Production, by hand.** From `worker/`, with the token and account ID in
  `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`:

    ```bash
    npx wrangler deployments list
    npx wrangler rollback <version-id>
    ```

    Or run the workflow again from an older `v*` tag (*Use workflow from*), which
    rebuilds and redeploys that release.
- **Stage.** A preview takes no production traffic. Push the fix: a re-run
  of an older push run deploys nothing when stage already serves a newer
  commit, because stage never goes back.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "set the CLOUDFLARE_API_TOKEN secret" | The secret or variable is missing from the environment. A called workflow gets a secret only if the caller passes it, so `release.yml` passes both by name to `docs.yml`; an environment secret not passed resolves to an empty string. Keep the values on the environments. |
| Nothing deploys after a release | The tag already existed, so the release workflow skipped the call. Run `docs.yml` by hand from the tag. A tag or release created with `GITHUB_TOKEN` starts no workflow of its own. |
| "pick a release tag (v1.2.3) in 'Use workflow from'" | A manual run was started from a branch. Choose the tag `vX.Y.Z` in *Use workflow from*; there is no tag input. |
| A manual run is rejected by the environment | The `production` environment does not allow tags. Add the tag pattern `v*` to its deployment rules. |
| "tag vX.Y.Z is ..., not the commit this run started on" | The release workflow called the deploy for a tag that points elsewhere: it was moved or deleted and recreated. Restore the tag and run again from it. |
| The custom domain fails to attach | A DNS record already exists at `ops.szolotov.com`. A CI deploy replaces it; otherwise delete it in the dashboard. |
| The stage address does not answer | The first production deploy has not run yet, so the preview wildcard and certificate do not exist. Deploy production once. |
| Stage shows an older commit, or a run skipped its stage deploy | Stage already served a commit that includes the run's own, so it deployed nothing. If stage still shows an older commit than you expect, re-run the workflow for the commit you want. A run that cannot read or compare stage's version fails instead (next row). |
| "stage freshness check failed" | The run could not read stage's `version.txt` or compare it with the build's commit after several retries (a network error, a GitHub API error, or a live commit unknown to the repository), so it deployed nothing. Re-run the failed jobs later; if it keeps failing, check what `curl -sS https://stage.ops.szolotov.com/version.txt` returns. |
| "Last updated" dates on every page are equal | A shallow clone. The workflow fetches full history; a local build needs `git fetch --unshallow`. |
| "this tag's commit is not on master" | Only tags whose commit is on `master` reach production. |

## Risks

- The Cloudflare token can change the zone's DNS. Keep it in the two
  environments only, restrict `production` to `master`, `v*` tags (protected by a tag ruleset) and required reviewers, and give it
  no more permissions than the list above.
- The production deploy runs inside the release run, which holds the `release`
  concurrency group. A production approval left pending keeps that group, and
  GitHub keeps only one pending run per group, so a later `CHANGELOG.md` push
  can cancel an earlier pending run, which may be the one that should tag the
  next release. Approve or reject the deploy promptly.
- A deploy replaces the Worker's Custom Domains and any DNS record already at
  the name.
- There is no `Content-Security-Policy` header: Material for MkDocs uses
  inline scripts and loads fonts from Google Fonts.
- The automatic rollback needs a recorded earlier version. The first
  production deploy has none and fails without one to go back to.
- Live Cloudflare behaviour, such as Worker Previews (an open beta feature at
  the time of writing), is not tested in CI beyond the smoke test after a
  deploy.

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
| Run workflow with a `v*` tag | The same production deploy, to promote or redeploy a release by hand. | <https://ops.szolotov.com> | `production` |

"Touching the site" means `docs/`, `mkdocs.yml`, `worker/`, `ROADMAP.md`,
`CHANGELOG.md` or `docs.yml` itself.

Every build writes `site/version.txt` holding the commit SHA. After a deploy
the workflow fetches `version.txt` from the live address and waits until it
matches, so the new version is told from the old one. The stage preview must
answer `X-Robots-Tag: noindex`, and production must not. Before it deploys
stage, a run reads the commit stage serves; if that commit already includes the
run's own, the run succeeds without deploying, so an older build that
finishes last never replaces newer content on stage. Production is not
affected.

!!! note "Why the release workflow calls the deploy"
    The release workflow creates the tag and the GitHub Release with the
    built-in `GITHUB_TOKEN`, and events created by that token start no other
    workflow. A deploy triggered by "release published" would never run, so
    `release.yml` calls `docs.yml` as a reusable workflow after its publish
    job succeeds. It does so only for the run that created the tag. A later
    edit to `CHANGELOG.md`, or a re-run once the tag exists, deploys nothing
    to production; promote the tag by hand then.

Production only serves a tag whose commit is on `master`, and a manual run
must be started from `master`. The tag must match `v1.2.3`.

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
| `production` | Release or manual run | Deployment branches: `master` only; required reviewers. |

On each environment add the secret `CLOUDFLARE_API_TOKEN` and the variable
`CLOUDFLARE_ACCOUNT_ID` (a secret of that name also works). Only the wrangler
steps read the token. Pull requests, forks included, never get it.

Every production run has `master` as its ref: the release workflow runs on a
push to `master`, and a manual run must start from `master`. The tag is only
the commit that gets checked out and built, so the environment needs no tag
rule. Allowing tags would only let a workflow file on any pushed `v*` tag reach
the token.

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

    Or run the workflow again with an older `v*` tag, which rebuilds and
    redeploys that release.
- **Stage.** A preview takes no production traffic. Push the fix: a re-run
  of an older push run deploys nothing when stage already serves a newer
  commit, because stage never goes back.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "set the CLOUDFLARE_API_TOKEN secret" | The secret or variable is missing from the environment. A called workflow gets a secret only if the caller passes it, so `release.yml` passes both by name to `docs.yml`; an environment secret not passed resolves to an empty string. Keep the values on the environments. |
| Nothing deploys after a release | The tag already existed, so the release workflow skipped the call. Run `docs.yml` by hand with the tag. A tag or release created with `GITHUB_TOKEN` starts no workflow of its own. |
| The custom domain fails to attach | A DNS record already exists at `ops.szolotov.com`. A CI deploy replaces it; otherwise delete it in the dashboard. |
| The stage address does not answer | The first production deploy has not run yet, so the preview wildcard and certificate do not exist. Deploy production once. |
| Stage shows an older commit, or a run skipped its stage deploy | Stage already served a commit that includes the run's own, so it deployed nothing. If stage still shows an older commit than you expect, re-run the workflow for the commit you want. A run that cannot read or compare stage's version deploys. |
| "Last updated" dates on every page are equal | A shallow clone. The workflow fetches full history; a local build needs `git fetch --unshallow`. |
| "this tag's commit is not on master" | Only tags whose commit is on `master` reach production. |

## Risks

- The Cloudflare token can change the zone's DNS. Keep it in the two
  environments only, restrict `production` to `master` and required reviewers, and give it
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

# Deployment

The documentation site is built with MkDocs and served by one Cloudflare
Worker, `ops-toolbox` (the [`worker/`](https://github.com/greenblacked/ops-toolbox/tree/master/worker)
folder). The workflow is
[`docs.yml`](https://github.com/greenblacked/ops-toolbox/blob/master/.github/workflows/docs.yml).

## The flow

Feature branches open pull requests into `dev`. `dev` is merged into `master`
with a merge commit, which deploys stage, and a release is cut from `master`,
which deploys production. After a release, merge `master` back into `dev`.

| Event | What happens | Where | GitHub environment |
| --- | --- | --- | --- |
| Pull request touching the site | `mkdocs build --strict`, then `wrangler deploy --dry-run`. No secrets, nothing deployed. | Nowhere | none |
| Push to `dev` that touches the site (the paths `docs.yml` watches), including a merged pull request | Build, then upload the site as the `site-preview` artifact (7 days). No Cloudflare, no environment, no secrets: the maintainer publishes the artifact as a private preview for review. A push builds only when its own commit touches those paths, so a new `dev` branch, or a `dev` push that touches none, gives no preview: run `gh workflow run docs.yml --ref dev` to build one. | The workflow run's artifacts | none |
| Push to `master` (the merged `dev` pull request) | Build, then a Worker Preview named `stage`. | <https://stage.ops.szolotov.com> | `staging` |
| Release cut (the Release workflow, run by hand) | Build the tag, deploy, smoke-test, roll back on failure. | <https://ops.szolotov.com> | `production` |
| `gh workflow run docs.yml --ref vX.Y.Z` (or the REST API) | The same production deploy, to promote or redeploy a release by hand. | <https://ops.szolotov.com> | `production` |

"Touching the site" means `docs/`, `mkdocs.yml`, `overrides/`, `worker/`, `ROADMAP.md`,
`CHANGELOG.md`, `docs.yml` itself or `.github/scripts/stage-stale.sh`.

Every build writes `site/version.txt` holding the commit SHA. After a deploy
the workflow fetches `version.txt` from the live address and waits until it
matches, so the new version is told from the old one. The stage preview must
answer `X-Robots-Tag: noindex`, and production must not.

### The smoke test and Bot Fight Mode

Bot Fight Mode is on for the whole `szolotov.com` zone. It answers a GitHub
runner's request for a page (any non-static path, such as `/`) with HTTP 403,
and no WAF rule can skip it, so it stays on and the checks work around it.
Static files such as `version.txt` pass.

- **Production.** The blocking smoke test goes to the Worker's `workers.dev`
  address (`https://ops-toolbox.<account>.workers.dev`), which is outside the
  zone and serves the same deployment as `ops.szolotov.com`. Wrangler reports
  it, and the version ID it just deployed, in its output file
  (`WRANGLER_OUTPUT_FILE_PATH`, the `deploy` entry's `targets` and
  `version_id`). `version.txt` must hold the run's SHA, `/` must answer 200 and
  there must be no `X-Robots-Tag`. A second blocking step then runs
  `wrangler deployments status --json` and requires that the deployed version
  is the only one active, at 100%, which is what makes `ops.szolotov.com`
  serve what was tested. A failure of any of these rolls back as before. Last,
  `https://ops.szolotov.com/` and `/version.txt` are probed for information
  only: a 403 prints a notice and never fails the run. `workers_dev` must stay
  `true` in `worker/wrangler.jsonc` (Wrangler turns it off by default once
  `routes` is set); without it the deploy fails for want of an address.
- **Stage.** Workers.dev preview URLs are off on purpose (`preview_urls` is
  `false`), so a preview has no address outside the zone. The smoke test asks
  the stage host: `version.txt` must hold the SHA and carry
  `X-Robots-Tag: noindex`, and `/` must answer 200, except that a 403 on `/` is
  noted and not failed, but only when Cloudflare marks it as a challenge
  (`cf-mitigated: challenge`); any other 403 fails. A 403 on `version.txt`
  fails the run, as does a missing DNS record or a connection error.

Production also requires wrangler's deploy output to list
`ops.szolotov.com` as an attached custom domain.

### Stage freshness check

Before it deploys stage, a run reads the commit stage serves; if that commit already includes the
run's own, the run succeeds without deploying, so an older build that finishes
last never replaces newer content on stage. The check fails closed: only a
stage with nothing deployed yet (`version.txt` answers HTTP 404) counts as
"unknown, so deploy". If the stage hostname does not resolve on every attempt
and a DNS lookup says the host has no address (NXDOMAIN, or NODATA: NOERROR with no A or AAAA record), and GitHub has recorded no successful
production deployment yet, stage cannot exist yet, so the run prints a notice
and skips the stage deploy. The `deploy` job does not run, no token is used,
and the run stays green. This holds until production has a successful
deployment, so it covers the stage runs before the first release is cut,
including the merge of the release pull request, and any run while the first
production deploy is still going (a release tag cannot tell, because it is
pushed first); a failed first production deploy also stays a skip. Once
production has deployed successfully, a stage host without DNS means the Custom
Domain or its preview wildcard is missing, and the run fails with an error
instead. Deploy
production first; after that, a push to `master` deploys stage normally. If the
check cannot read or compare the live version after a few retries, the run
fails and deploys nothing. The check runs twice. In its own
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
    Production deploys only when you cut a release. Merging the release pull
    request (prepared by `release-prepare.yml`) deploys stage like any other
    change; it does not tag or touch production. Then you run `release.yml`
    from `master`. It creates the tag and the GitHub Release with the built-in
    `GITHUB_TOKEN`, and events created by that token start no other workflow,
    so a deploy triggered by "release published" would never run.
    `release.yml` therefore calls `docs.yml` as a reusable workflow after its
    publish job succeeds. To redeploy or promote a tag later, use
    `gh workflow run docs.yml --ref vX.Y.Z` (see Manual promote below).

No checkout in the workflow uses a ref taken from an input or computed in a
step; every one checks out `github.sha`, which cannot move. This is what CodeQL's
"Cache poisoning via execution of untrusted code" check asks for, since the
build installs packages with pip and npm. So a tag is never checked out; it is
checked against the commit the run started on:

- **Release workflow.** `docs.yml` runs at the commit the publish job tagged,
  which is `master`'s HEAD when you started `release.yml`.
  The build asserts that `refs/tags/<tag>` resolves to exactly that commit and
  fails otherwise.
- **Manual promote.** There is no tag input. Start the run from the tag with
  the GitHub CLI or the REST API. The web UI's *Run workflow* picker lists
  branches, so use the CLI or API:

    ```sh
    gh workflow run docs.yml --ref vX.Y.Z
    ```

    The equivalent REST call:

    ```sh
    gh api -X POST repos/greenblacked/ops-toolbox/actions/workflows/docs.yml/dispatches -f ref=vX.Y.Z
    ```

    Watch the run with `gh run list --workflow docs.yml --limit 1`, then
    `gh run watch`. Starting from a branch fails with a message that names
    the `gh` command. The workflow file that runs is the one on that tag, so an
    old tag redeploys with its own version of the workflow.

Either way the tag must match `v1.2.3` and its commit must be on `master`.

## One-time setup

### Cloudflare

1. Add the `szolotov.com` zone to the Cloudflare account.
2. Create the deploy token: an **Account API token** from the "Edit
   Cloudflare Workers" template, scoped to this one account and, for
   its zone permissions, to the `szolotov.com` zone only (**Zone > Workers
   Routes > Write** on `szolotov.com`), because the deploy manages the Custom
   Domain. The first deploy creates the Worker, which needs
   Workers Admin (account-wide Workers edit; the template gives it). Custom Domains cannot
   be limited to one Worker, so this token can edit any Worker in the account.
   Make sure no CNAME record already exists at `ops.szolotov.com`; a Custom
   Domain cannot be created on a hostname that has one. Permission names
   change, so verify them against
   <https://developers.cloudflare.com/workers/authorization/workers/>.
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

A production run has one of two refs: `master`, for the release workflow (you
run it by hand from `master`), or a `v*` tag, for a manual promote. The
`production` environment's deployment rules must therefore allow the branch
`master` and the tag pattern `v*`. Without the tag rule a manual run fails when
it asks for the environment.

Allowing tags means a workflow file on any pushed `v*` tag can reach the token,
so also protect the tags with a tag ruleset (*Settings, Rules, Rulesets*) for
`v*` that restricts who may create them, blocks update, deletion and force
push, and keep required reviewers on `production`. The release workflow pushes
the `v*` tag itself (its publish job) with `GITHUB_TOKEN`, so the ruleset must list **GitHub
Actions** in its bypass list, or the release fails at
`git push origin refs/tags/vX.Y.Z`. Keep repository admins in the bypass list
too. The GitHub Actions bypass covers every workflow that runs with a
`contents: write` token, not only `release.yml` (`routeros-version.yml` is one,
and a collaborator with write access can push a workflow that asks for it), so
the ruleset narrows who can make a tag but does not stop a workflow from
making one. The required reviewers on `production` are the real gate: a
reviewer approves each production deploy before the token is released. As an
extra guard, set the repository's default workflow permissions to read, and
review any workflow that asks for `contents: write`.

### Setup with the GitHub CLI

Run these once with the `gh` CLI, logged in as a repository admin. The
heredocs work in zsh and bash.

```sh
REPO=greenblacked/ops-toolbox
CF_ACCOUNT_ID='REPLACE_WITH_ACCOUNT_ID'
: "${CF_ACCOUNT_ID:?set your Cloudflare account ID}"

# Environments, each limited to the branch master.
gh api -X PUT "repos/$REPO/environments/staging" --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON

# Your numeric user ID, for the production required reviewer.
MY_ID=$(gh api user --jq .id)

gh api -X PUT "repos/$REPO/environments/production" --input - <<JSON
{"reviewers": [{"type": "User", "id": $MY_ID}],
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON

gh api -X POST "repos/$REPO/environments/staging/deployment-branch-policies" \
  -f name=master -f type=branch
gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" \
  -f name=master -f type=branch
gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" \
  -f 'name=v*' -f type=tag

# Secret and variable, once per environment.
for ENV in staging production; do
  gh secret set CLOUDFLARE_API_TOKEN --env "$ENV" --repo "$REPO"
  gh variable set CLOUDFLARE_ACCOUNT_ID --env "$ENV" --repo "$REPO" --body "$CF_ACCOUNT_ID"
done

# Tag ruleset for v*.
gh api -X POST "repos/$REPO/rulesets" --input - <<'JSON'
{
  "name": "Protect release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [
    {"type": "creation"},
    {"type": "update"},
    {"type": "deletion"},
    {"type": "non_fast_forward"}
  ],
  "bypass_actors": [
    {"actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "always"},
    {"actor_type": "Integration", "actor_id": 15368, "bypass_mode": "always"}
  ]
}
JSON
```

`gh api user --jq .id` prints the numeric ID that the `reviewers` entry needs.
`gh secret set` asks for the token value on stdin; paste it there rather
than putting it on the command line.

The two numeric bypass IDs (`5` for the repository admin role, `15368` for
GitHub Actions) are the values GitHub documents, but verify them with
`gh api repos/greenblacked/ops-toolbox/rulesets` after creating the ruleset, or
pick the bypass actors in the UI instead.

### First deploy

1. Merge to `master`. Stage will not answer until production has deployed once,
   because the preview wildcard and certificate come from that deploy. Until
   then a push to `master` skips the stage deploy with a notice and stays green.
2. Prepare the first release: `gh workflow run release-prepare.yml -f version=0.1.0`.
3. Open the pull request from the pushed `release/0.1.0` branch (the run's
   summary has the link), and merge it once its checks are green.
4. Cut it: `gh workflow run release.yml -f version=0.1.0`. Approve the `production` deployment when GitHub asks.
5. Check <https://ops.szolotov.com/version.txt>, then
   <https://stage.ops.szolotov.com> after the next push to `master`.

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
curl -sSI https://stage.ops.szolotov.com/ \
  | grep -i 'x-robots-tag\|x-frame-options\|content-security-policy\|permissions-policy'
curl -sS https://stage.ops.szolotov.com/version.txt
curl -sSI https://ops.szolotov.com/
curl -sS https://ops.szolotov.com/version.txt
curl -sSI https://stage.ops.szolotov.com/version.txt | grep -i 'cache-control'
curl -sSI "https://stage.ops.szolotov.com/$(curl -sS https://stage.ops.szolotov.com/ \
  | grep -o 'assets/javascripts/bundle\.[0-9a-f]*\.min\.js' | head -n 1)" | grep -i 'cache-control'
```

- `version.txt` holds the SHA of the deployed commit.
- `X-Robots-Tag: noindex` appears on stage and not on production.
- Both answer with `X-Content-Type-Options`, `Referrer-Policy`,
  `X-Frame-Options`, `Content-Security-Policy` (only `base-uri`,
  `form-action`, `frame-ancestors` and `object-src`), `Permissions-Policy`,
  `Cross-Origin-Opener-Policy`, `X-Permitted-Cross-Domain-Policies` and
  `Strict-Transport-Security`. The full list and the reasons are in the
  [Worker README](https://github.com/greenblacked/ops-toolbox/blob/master/worker/README.md#notes).
- An unknown path answers 404 with the site's 404 page.
- The footer of every page ends with "Build" and the first seven characters
  of the deployed SHA, linked to the commit. On stage, "Preview build" comes
  before it (see below).
- `version.txt` answers `Cache-Control: no-store`, and Material's hashed
  bundle answers `Cache-Control: public, max-age=31536000, immutable`. Pages
  carry no `Cache-Control` from the Worker (the rules are in the
  [Worker README](https://github.com/greenblacked/ops-toolbox/blob/master/worker/README.md#caching)).

The footer stamp is read in the browser:
`overrides/assets/javascripts/rpt-build-stamp.js` fetches the site's own
`version.txt` and shows the SHA it holds, and marks the page as a preview
build when that response carries `X-Robots-Tag: noindex`, which only stage
sends. It stays empty in three cases, all expected: under `mkdocs serve` or
a local `mkdocs build` (only the workflow writes `version.txt`), when the
file does not hold exactly one 40-character SHA, and with JavaScript off or
the request failing.

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

    Or run the workflow again from an older `v*` tag with
    `gh workflow run docs.yml --ref vX.Y.Z`, which rebuilds and redeploys that
    release.
- **Stage.** A preview takes no production traffic. Push the fix: a re-run
  of an older push run deploys nothing when stage already serves a newer
  commit, because stage never goes back.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "set the CLOUDFLARE_API_TOKEN secret" | The secret or variable is missing from the environment. A called workflow gets a secret only if the caller passes it, so `release.yml` passes both by name to `docs.yml`; an environment secret not passed resolves to an empty string. Keep the values on the environments. |
| Nothing deploys after a release | The tag already existed, so the release workflow skipped the call. Run `gh workflow run docs.yml --ref vX.Y.Z` (or the REST call under Manual promote). A tag or release created with `GITHUB_TOKEN` starts no workflow of its own. |
| "start a manual run from dev ... or from a release tag" | A manual run was started from a branch other than `dev`, or from a tag that does not match `v1.2.3`. Run `gh workflow run docs.yml --ref dev` for a site preview or `gh workflow run docs.yml --ref vX.Y.Z` for production (or the REST API call above); there is no tag input. |
| A manual run is rejected by the environment | The `production` environment does not allow tags. Add the tag pattern `v*` to its deployment rules. |
| "tag vX.Y.Z is ..., not the commit this run started on" | The release workflow called the deploy for a tag that points elsewhere: it was moved or deleted and recreated. Restore the tag and run again from it. |
| The custom domain fails to attach | A DNS record already exists at `ops.szolotov.com`. A CI deploy replaces it; otherwise delete it in the dashboard. |
| The stage address does not answer | The first production deploy has not run yet, so the preview wildcard and certificate do not exist; pushes to `master` skip stage until then. Deploy production once. |
| "stage does not exist yet" notice, or `curl` exit 6 ("Could not resolve host") in the freshness check | Observed: before the first production deploy the stage hostname has no DNS record, and the Worker may not exist yet. The freshness check treats a host that fails to resolve on every attempt, with a DNS lookup confirming no address (NXDOMAIN, or NODATA, which is how Cloudflare-hosted DNSSEC zones answer a nonexistent name, RFC 9824), as "stage does not exist yet": it skips the stage deploy (no `deploy` job, no token, no preview, no smoke test) and the run stays green. Deploy production first (`release.yml`, or `gh workflow run docs.yml --ref vX.Y.Z`); the next push to `master` then deploys stage. The skip applies until GitHub records a production deployment with a success status: once one exists, a stage host without DNS fails the check (see the next row). A resolver failure (SERVFAIL, REFUSED, a timeout), or NOERROR with an A or AAAA answer while `curl` cannot resolve, or a failed deployments or statuses lookup, fails the check instead. If stage keeps failing after production exists, run `curl -sSI https://stage.ops.szolotov.com/version.txt`: any status other than 200 or 404 (or a connection, TLS or timeout error) stays a failure by design. |
| `production was deployed (deployment ...) but ... has no DNS record` error in the freshness check | GitHub has a production deployment with a success status, but the stage host has no address (NXDOMAIN or NODATA), so the Worker's Custom Domain or its preview wildcard was lost. Nothing was deployed, and every run fails until it is fixed. Check the Worker's Custom Domain and `previews_enabled` in Cloudflare, then re-run the workflow. |
| Stage shows an older commit, or a run skipped its stage deploy | Stage already served a commit that includes the run's own, so it deployed nothing. If stage still shows an older commit than you expect, re-run the workflow for the commit you want. A run that cannot read or compare stage's version fails instead (next row). |
| "stage freshness check failed" | The run could not read stage's `version.txt` or compare it with the build's commit after several retries (a network error, a GitHub API error, or a live commit unknown to the repository), so it deployed nothing. Re-run the failed jobs later; if it keeps failing, check what `curl -sS https://stage.ops.szolotov.com/version.txt` returns. |
| "wrangler reported no workers.dev address" | Bot Fight Mode on the `szolotov.com` zone answers GitHub runners with 403 for pages. Production is smoke-tested on its `workers.dev` address, so keep `workers_dev` `true` in `worker/wrangler.jsonc` and the account's workers.dev subdomain registered; do not point the check back at `ops.szolotov.com`. A 403 from the custom-domain probe is only a notice. The failure happens after the upload, so the run rolls back to the recorded previous version. Fix the cause and run `gh workflow run docs.yml --ref vX.Y.Z` again. |
| "Last updated" dates on every page are equal | A shallow clone. The workflow fetches full history; a local build needs `git fetch --unshallow`. |
| "this tag's commit is not on master" | Only tags whose commit is on `master` reach production. |

## Risks

- The Cloudflare token can deploy any Worker in the account and attach Custom
  Domains and routes on `szolotov.com`, which creates DNS records for those
  hostnames. Keep it in the two
  environments only, restrict `production` to `master`, `v*` tags (protected by a tag ruleset) and required reviewers, and give it
  no more permissions than the scope in the Cloudflare step.
- The production deploy runs inside the release run, which holds the `release`
  concurrency group. A production approval left pending keeps that group, and
  GitHub keeps only one pending run per group, so a later `CHANGELOG.md` push
  can cancel an earlier pending run, which may be the one that should tag the
  next release. Approve or reject the deploy promptly.
- A deploy replaces the Worker's Custom Domains and any DNS record already at
  the name.
- The `Content-Security-Policy` header restricts only `base-uri`,
  `form-action`, `frame-ancestors` and `object-src`, not scripts or styles:
  Material for MkDocs uses inline scripts and styles, and a static site
  cannot hand out nonces. The fonts are self-hosted, so they no longer
  stand in the way.
- `Strict-Transport-Security` is sent by the Worker for one year, on this
  host only. A browser that has seen it will refuse plain http for the site
  until it expires, so it cannot be undone quickly; it is safe because the
  site is served only over https.
- The automatic rollback needs a recorded earlier version. The first
  production deploy has none and fails without one to go back to.
- Live Cloudflare behaviour, such as Worker Previews (an open beta feature at
  the time of writing), is not tested in CI beyond the smoke test after a
  deploy.

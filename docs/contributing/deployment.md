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
| `gh workflow run docs.yml --ref vX.Y.Z` (or the REST API) | The same production deploy, to promote or redeploy a release by hand. | <https://ops.szolotov.com> | `production` |

"Touching the site" means `docs/`, `mkdocs.yml`, `worker/`, `ROADMAP.md`,
`CHANGELOG.md`, `docs.yml` itself or `.github/scripts/stage-stale.sh`.

Every build writes `site/version.txt` holding the commit SHA. After a deploy
the workflow fetches `version.txt` from the live address and waits until it
matches, so the new version is told from the old one. The stage preview must
answer `X-Robots-Tag: noindex`, and production must not. Before it deploys
stage, a run reads the commit stage serves; if that commit already includes the
run's own, the run succeeds without deploying, so an older build that finishes
last never replaces newer content on stage. The check fails closed: only a
stage with nothing deployed yet (`version.txt` answers HTTP 404) counts
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
    to production; promote the tag by hand then with
    `gh workflow run docs.yml --ref vX.Y.Z` (see Manual promote below).

No checkout in the workflow uses a ref taken from an input or computed in a
step; every one checks out `github.sha`, which cannot move. This is what CodeQL's
"Cache poisoning via execution of untrusted code" check asks for, since the
build installs packages with pip and npm. So a tag is never checked out; it is
checked against the commit the run started on:

- **Release workflow.** `docs.yml` runs at the commit the publish job tagged.
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

A production run has one of two refs: `master`, for the release workflow (it
runs on a push to `master`), or a `v*` tag, for a manual promote. The
`production` environment's deployment rules must therefore allow the branch
`master` and the tag pattern `v*`. Without the tag rule a manual run fails when
it asks for the environment.

Allowing tags means a workflow file on any pushed `v*` tag can reach the token,
so also protect the tags with a tag ruleset (*Settings, Rules, Rulesets*) for
`v*` that restricts who may create them, blocks update, deletion and force
push, and keep required reviewers on `production`. The release workflow pushes
the `v*` tag itself with `GITHUB_TOKEN`, so the ruleset must list **GitHub
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
   because the preview wildcard and certificate come from that deploy.
2. Cut the first release: `gh workflow run release.yml -f version=0.1.0`.
3. Merge the release PR it opens.
4. Approve the `production` deployment when GitHub asks.
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
| "start a manual run from a release tag" | A manual run was started from a branch, or from a tag that does not match `v1.2.3`. Run `gh workflow run docs.yml --ref vX.Y.Z` (or the REST API call above); there is no tag input. |
| A manual run is rejected by the environment | The `production` environment does not allow tags. Add the tag pattern `v*` to its deployment rules. |
| "tag vX.Y.Z is ..., not the commit this run started on" | The release workflow called the deploy for a tag that points elsewhere: it was moved or deleted and recreated. Restore the tag and run again from it. |
| The custom domain fails to attach | A DNS record already exists at `ops.szolotov.com`. A CI deploy replaces it; otherwise delete it in the dashboard. |
| The stage address does not answer | The first production deploy has not run yet, so the preview wildcard and certificate do not exist. Deploy production once. |
| Stage shows an older commit, or a run skipped its stage deploy | Stage already served a commit that includes the run's own, so it deployed nothing. If stage still shows an older commit than you expect, re-run the workflow for the commit you want. A run that cannot read or compare stage's version fails instead (next row). |
| "stage freshness check failed" | The run could not read stage's `version.txt` or compare it with the build's commit after several retries (a network error, a GitHub API error, or a live commit unknown to the repository), so it deployed nothing. Re-run the failed jobs later; if it keeps failing, check what `curl -sS https://stage.ops.szolotov.com/version.txt` returns. |
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
- There is no `Content-Security-Policy` header: Material for MkDocs uses
  inline scripts and loads fonts from Google Fonts.
- The automatic rollback needs a recorded earlier version. The first
  production deploy has none and fails without one to go back to.
- Live Cloudflare behaviour, such as Worker Previews (an open beta feature at
  the time of writing), is not tested in CI beyond the smoke test after a
  deploy.

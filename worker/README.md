# Worker

[Ops Toolbox](../README.md) / **Worker**

The Cloudflare Worker that serves the documentation site. It is not a script
you run on a machine: `.github/workflows/docs.yml` builds the site with MkDocs
and deploys it with wrangler. The setup, the runbook and the rollback steps
are in [Deployment](../docs/contributing/deployment.md).

| File | Purpose |
| --- | --- |
| `index.js` | The Worker. Serves the built site through the `ASSETS` binding and adds security headers to every response, and `X-Robots-Tag: noindex` when the `ROBOTS` variable is `noindex`. |
| `wrangler.jsonc` | The Worker's configuration: name `ops-toolbox`, the `../site` assets directory, the `ops.szolotov.com` Custom Domain and the `stage` Worker Preview's settings. |
| `package.json` | Pins wrangler to one exact version. |
| `package-lock.json` | The locked install, checked by `npm ci`. |

## Try it locally

Build the site first (`mkdocs build --strict` from the repository root, see
[Development](../docs/contributing/development.md)), then:

```bash
cd worker
npm ci --ignore-scripts
npx wrangler dev                     # serve ../site at http://localhost:8787
npx wrangler deploy --dry-run        # check the Worker; needs no Cloudflare account
```

Neither command uploads anything.

## Notes

- `run_worker_first` is on, so the Worker sees every request. Without it a
  request for a file that exists never reaches `index.js` and gets no headers.
- There is no `Content-Security-Policy`: Material for MkDocs uses inline
  scripts and styles and loads fonts from Google Fonts, so a policy that keeps
  the site working would protect little.
- Install with `--ignore-scripts`, and bump wrangler by editing
  `package.json` and `package-lock.json` together; Dependabot proposes it
  monthly.

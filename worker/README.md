# Worker

[Ops Toolbox](../README.md) / **Worker**

The Cloudflare Worker that serves the documentation site. It is not a script
you run on a machine: `.github/workflows/docs.yml` builds the site with MkDocs
and deploys it with wrangler. The setup, the runbook and the rollback steps
are in [Deployment](../docs/contributing/deployment.md).

| File | Purpose |
| --- | --- |
| `index.js` | The Worker. Serves the built site through the `ASSETS` binding and adds the security headers from `security.js` to every response, `X-Robots-Tag: noindex` when the `ROBOTS` variable is `noindex`, and `Cache-Control` from `cache.js`. |
| `security.js` | The security headers: `securityHeaders(requestUrl)` returns them as an object. No I/O. |
| `cache.js` | The caching rules: `cacheControl(pathname)` returns the `Cache-Control` value for a path, or `null` for the default. No I/O. |
| `wrangler.jsonc` | The Worker's configuration: name `ops-toolbox`, the `../site` assets directory, the `ops.szolotov.com` Custom Domain, `workers_dev` on and the `stage` Worker Preview's settings. |
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

## Caching

`index.js` sets `Cache-Control` from `cache.js`, and only when a `GET` or
`HEAD` was answered `200` or `304`: a `404` or an error is never cached as
long-lived. Everything the table does not name keeps the assets layer's
default, which revalidates with an ETag on every view.

| Path | `Cache-Control` | Why |
| --- | --- | --- |
| Under `/assets/javascripts/` or `/assets/stylesheets/`, named `<name>.<8 hex>.min.js` or `.min.css` | `public, max-age=31536000, immutable` | Material's bundle, stylesheets and search worker carry a content hash, so a new build is a new name. Source maps, the unhashed lunr files and the site's own stylesheets do not match. |
| `/assets/fonts/*.woff2` | `public, max-age=604800` | Not hashed, but they change only through the font update in `docs/assets/fonts/README.md`. |
| `/assets/images/*.svg`, `*.png` | `public, max-age=86400` | Not hashed; a changed logo shows within a day. |
| `/version.txt` | `no-store` | The deploy checks read it to tell a new deploy from the old one; no cache may answer for it. |
| Pages, `search/search_index.json`, `sitemap.xml`, anything else | (default) | Must show a new deploy at once. |

The rules are tested in `test-env/python/tests/test_docs_worker.py`, both on
their own and through `index.js` with a stand-in for the `ASSETS` binding.
Check a deploy with `curl -sSI` (see
[Deployment](../docs/contributing/deployment.md#check-a-deploy)).

## Notes

- `run_worker_first` is on, so the Worker sees every request. Without it a
  request for a file that exists never reaches `index.js` and gets no headers.
- `workers_dev` is `true` on purpose. Bot Fight Mode on the `szolotov.com` zone
  answers GitHub runners with a 403 for pages on `ops.szolotov.com`, so the
  production smoke test fetches the Worker's `workers.dev` address, which is
  outside the zone. Turning it off makes the production deploy fail its
  checks. `preview_urls` stays `false`: previews are served on the Custom
  Domain.
- The `Content-Security-Policy` is deliberately narrow:
  `base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'`.
  Material for MkDocs uses inline scripts and styles, and a static site
  cannot hand out nonces, so a script or style policy that keeps the site
  working would protect little. This one has no fetch directive at all, so it
  cannot block a script, style, font, image or connection; it stops an
  injected `<base>`, a form posting elsewhere, framing and plugins. The tests
  fail if a fetch directive is added. The site self-hosts its IBM Plex fonts
  (`theme.font: false`), so fonts are not an external dependency either.
- Every response, 404s included, carries `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: DENY`
  (for browsers older than `frame-ancestors`), the policy above,
  `Permissions-Policy` turning off accelerometer, camera, geolocation,
  gyroscope, magnetometer, microphone, payment and USB access (the site uses
  none; the copy button's clipboard is not in the list),
  `Cross-Origin-Opener-Policy: same-origin` and
  `X-Permitted-Cross-Domain-Policies: none`. Over https it also sends
  `Strict-Transport-Security: max-age=31536000`, for this host only (no
  `includeSubDomains`, no `preload`); if the Cloudflare zone already sets
  HSTS, remove it from `security.js` so it is not sent twice.
  `Cross-Origin-Resource-Policy` is left out on purpose: it would break a
  legitimate hot-link of the logo.
- Install with `--ignore-scripts`, and bump wrangler by editing
  `package.json` and `package-lock.json` together; Dependabot proposes it
  monthly.

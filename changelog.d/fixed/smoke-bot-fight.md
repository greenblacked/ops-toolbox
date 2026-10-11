- The documentation site's production deploy no longer fails its smoke test on
  Cloudflare Bot Fight Mode. The zone answers GitHub runners with HTTP 403 for
  pages on `ops.szolotov.com`, so the v0.1.0 deploy went live but was recorded
  as failed. The blocking checks now go to the Worker's `workers.dev` address
  and then confirm with `wrangler deployments status` that the deployed version
  serves 100% of traffic; the custom domain is only probed, and the stage
  preview treats a 403 as a notice.

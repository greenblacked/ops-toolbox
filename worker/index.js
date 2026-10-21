// Worker for the Ops Toolbox documentation site. Static files come from the
// ASSETS binding (the mkdocs build in ../site); this adds response headers.
//
// The security headers come from security.js and go on every response, 404s
// included. Its Content-Security-Policy is deliberately narrow: Material for
// MkDocs ships inline scripts and styles, so it sets no script, style or
// other fetch directive, only base-uri, form-action, frame-ancestors and
// object-src. Revisit that if the theme's inline scripts and styles are
// ever removed.
//
// Cache-Control comes from cache.js, and only on a successful read (GET or
// HEAD answered 200 or 304), so a missing file is never cached as
// long-lived.

import { cacheControl } from "./cache.js";
import { securityHeaders } from "./security.js";

export default {
  async fetch(request, env) {
    const upstream = await env.ASSETS.fetch(request);
    // Assets responses can have immutable headers; copy into a new response.
    const response = new Response(upstream.body, upstream);
    for (const [name, value] of Object.entries(securityHeaders(request.url))) {
      response.headers.set(name, value);
    }
    // Set in the config's previews block, so only the stage preview has it.
    if (env.ROBOTS === "noindex") {
      response.headers.set("X-Robots-Tag", "noindex");
    }
    const read = request.method === "GET" || request.method === "HEAD";
    if (read && (upstream.status === 200 || upstream.status === 304)) {
      const cc = cacheControl(new URL(request.url).pathname);
      if (cc) {
        response.headers.set("Cache-Control", cc);
      }
    }
    return response;
  },
};

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
//
// robots.txt and /.well-known/security.txt come from wellknown.js, and only
// when the assets layer has no such file (it answered 404), so a file the
// site ships always wins.

import { cacheControl } from "./cache.js";
import { securityHeaders } from "./security.js";
import { wellKnown } from "./wellknown.js";

// Adds the headers every response gets, in place.
function decorate(response, request, env, status) {
  for (const [name, value] of Object.entries(securityHeaders(request.url))) {
    response.headers.set(name, value);
  }
  // Set in the config's previews block, so only the stage preview has it.
  if (env.ROBOTS === "noindex") {
    response.headers.set("X-Robots-Tag", "noindex");
  }
  const read = request.method === "GET" || request.method === "HEAD";
  if (read && (status === 200 || status === 304)) {
    const cc = cacheControl(new URL(request.url).pathname);
    if (cc) {
      response.headers.set("Cache-Control", cc);
    }
  }
  return response;
}

export default {
  async fetch(request, env) {
    const upstream = await env.ASSETS.fetch(request);
    const read = request.method === "GET" || request.method === "HEAD";
    if (read && upstream.status === 404) {
      const file = wellKnown(request.url, env, new Date());
      if (file) {
        const synthesised = new Response(request.method === "HEAD" ? null : file.body, {
          status: 200,
          headers: { "Content-Type": file.contentType, "Cache-Control": file.cacheControl },
        });
        return decorate(synthesised, request, env, 200);
      }
    }
    // Assets responses can have immutable headers; copy into a new response.
    return decorate(new Response(upstream.body, upstream), request, env, upstream.status);
  },
};

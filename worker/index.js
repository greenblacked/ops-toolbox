// Worker for the Ops Toolbox documentation site. Static files come from the
// ASSETS binding (the mkdocs build in ../site); this adds response headers.
//
// No Content-Security-Policy: Material for MkDocs ships inline scripts and
// styles, so a policy loose enough to keep the site working would add little.
// The site self-hosts its IBM Plex fonts (theme.font: false), so fonts are not
// the obstacle. Revisit it if the theme's inline scripts and styles are ever
// removed.

const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "DENY",
};

export default {
  async fetch(request, env) {
    const upstream = await env.ASSETS.fetch(request);
    // Assets responses can have immutable headers; copy into a new response.
    const response = new Response(upstream.body, upstream);
    for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
      response.headers.set(name, value);
    }
    // Set in the config's previews block, so only the stage preview has it.
    if (env.ROBOTS === "noindex") {
      response.headers.set("X-Robots-Tag", "noindex");
    }
    return response;
  },
};

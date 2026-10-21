// Security headers for every response of the documentation site. Pure: no
// I/O, so the set can be tested on its own (test-env/python/tests/
// test_docs_worker.py).
//
// The Content-Security-Policy is deliberately narrow. Material for MkDocs
// ships inline scripts, inline styles and an inline JSON configuration, and
// a static site cannot hand out nonces, so any script-src, style-src or
// default-src would either break the site or be loose enough to mean
// nothing. The policy therefore has no fetch directives at all: it cannot
// block a script, style, font, image or connection. It only uses the
// directives that govern nothing the theme does:
//   base-uri 'self'        no injected <base> can repoint relative URLs
//   form-action 'self'     no form can be made to post elsewhere
//   frame-ancestors 'none' no framing (clickjacking); supersedes
//                          X-Frame-Options, which stays for old browsers
//   object-src 'none'      no plugins
// The tests pin the directive set, so a pasted-in policy that would break
// the theme fails before it ships.
const CSP = "base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'";

// Features the site never uses. The Clipboard API behind the code copy
// button is not in the list.
const PERMISSIONS_POLICY = [
  "accelerometer=()",
  "camera=()",
  "geolocation=()",
  "gyroscope=()",
  "magnetometer=()",
  "microphone=()",
  "payment=()",
  "usb=()",
].join(", ");

// One year, this host only: no includeSubDomains and no preload, so a
// mistake here cannot reach other hosts on the zone. Not sent over plain
// http (wrangler dev on http://localhost:8787), where browsers ignore it
// anyway. If the Cloudflare zone already sets HSTS, drop this one header to
// avoid sending it twice.
const HSTS = "max-age=31536000";

// Returns the headers for a response to requestUrl, as a plain object.
// Not added on purpose: Cross-Origin-Resource-Policy (it would break a
// legitimate hot-link of the logo) and any script or style policy (above).
export function securityHeaders(requestUrl) {
  const headers = {
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": CSP,
    "Permissions-Policy": PERMISSIONS_POLICY,
    "Cross-Origin-Opener-Policy": "same-origin",
    "X-Permitted-Cross-Domain-Policies": "none",
  };
  let https = false;
  try {
    https = new URL(requestUrl).protocol === "https:";
  } catch {
    https = false;
  }
  if (https) {
    headers["Strict-Transport-Security"] = HSTS;
  }
  return headers;
}

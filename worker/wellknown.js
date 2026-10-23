// robots.txt and /.well-known/security.txt for the documentation site, built
// from constants and the request URL. Pure: no I/O, and the clock is passed
// in, so the tests do not depend on the date (test-env/python/tests/
// test_docs_worker.py).
//
// index.js asks for these only after the assets layer answered 404, so a
// file the site ships itself always wins.

// The private advisory form and the policy SECURITY.md names. Kept here as
// constants on purpose, like REPO_URL in docs/hooks/repo_files.py: the
// Worker cannot read the repository.
const CONTACT = "https://github.com/greenblacked/ops-toolbox/security/advisories/new";
const POLICY = "https://github.com/greenblacked/ops-toolbox/blob/master/SECURITY.md";
// RFC 9116 asks for an Expires date, and recommends less than a year ahead.
// It rolls with every response, so the file states that the deployed site
// still stands behind it rather than when a person last reviewed it.
const EXPIRES_DAYS = 180;
const TEXT = "text/plain; charset=utf-8";
const ONE_HOUR = "public, max-age=3600";

// Stage (ROBOTS=noindex) and *.workers.dev allow crawling and name no
// sitemap. Stage is kept out of search engines by its X-Robots-Tag header,
// which a crawler sees only if it may fetch the page: a Disallow would stop
// it from ever reading the header while the bare URL could still be listed.
// The workers.dev address is the same deployment as production on an origin
// that is not the canonical one, so it names no sitemap either.
export function robotsTxt(requestUrl, env) {
  const url = new URL(requestUrl);
  const preview = (env && env.ROBOTS === "noindex") || url.hostname.endsWith(".workers.dev");
  if (preview) {
    return "User-agent: *\nDisallow:\n";
  }
  return "User-agent: *\nAllow: /\n\nSitemap: " + url.origin + "/sitemap.xml\n";
}

export function securityTxt(requestUrl, now) {
  const url = new URL(requestUrl);
  const expires = new Date(now.getTime() + EXPIRES_DAYS * 24 * 60 * 60 * 1000)
    .toISOString()
    .replace(/\.\d{3}Z$/, "Z");
  return [
    "Contact: " + CONTACT,
    "Expires: " + expires,
    "Policy: " + POLICY,
    "Preferred-Languages: en",
    "Canonical: " + url.origin + "/.well-known/security.txt",
    "",
  ].join("\n");
}

// The file for this request, as {body, contentType, cacheControl}, or null
// when the path is not one of the two.
export function wellKnown(requestUrl, env, now) {
  const { pathname } = new URL(requestUrl);
  if (pathname === "/robots.txt") {
    return { body: robotsTxt(requestUrl, env), contentType: TEXT, cacheControl: ONE_HOUR };
  }
  if (pathname === "/.well-known/security.txt") {
    return { body: securityTxt(requestUrl, now), contentType: TEXT, cacheControl: ONE_HOUR };
  }
  return null;
}

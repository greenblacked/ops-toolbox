// Cache-Control for the documentation site's responses, by path. Pure: no
// I/O, so the rules can be tested on their own (test-env/python/tests/
// test_docs_worker.py).
//
// Without a header of its own, every file carries the assets layer's
// default, which makes the browser revalidate on every view. Material names
// its bundle, stylesheets and search worker with a content hash
// (bundle.d7400e89.min.js), so a new release is a new name and the old one
// can be cached for a year. The immutable rule is deliberately narrow: an
// 8-hex hash, then .min.js or .min.css, under /assets/. Source maps, the
// unhashed lunr files and the site's own stylesheets never match, because a
// wrong match would pin a stale file in browsers for a year.

const HASHED = /^\/assets\/(?:javascripts|stylesheets)\/(?:[\w-]+\/)*[\w-]+\.[0-9a-f]{8}\.min\.(?:js|css)$/;
// Self-hosted fonts are not hashed; they change only through the documented
// font update (docs/assets/fonts/README.md), so a week is enough.
const FONT = /^\/assets\/fonts\/[\w.-]+\.woff2$/;
const IMAGE = /^\/assets\/images\/[\w.-]+\.(?:svg|png)$/;

// Returns the Cache-Control value for a request path, or null to keep the
// assets layer's default (HTML, search_index.json, sitemap.xml and anything
// else revalidate with their ETag).
export function cacheControl(pathname) {
  if (typeof pathname !== "string") {
    return null;
  }
  if (HASHED.test(pathname)) {
    return "public, max-age=31536000, immutable";
  }
  if (FONT.test(pathname)) {
    return "public, max-age=604800";
  }
  if (IMAGE.test(pathname)) {
    return "public, max-age=86400";
  }
  // The deployed commit. The deploy smoke tests and the stage freshness
  // check read it to tell a new deploy from the old one, so nothing between
  // them and the Worker may answer from a cache.
  if (pathname === "/version.txt") {
    return "no-store";
  }
  return null;
}

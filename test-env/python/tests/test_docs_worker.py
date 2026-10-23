"""Tests for the documentation site's Cloudflare Worker (worker/).

The Worker is ES modules with no test runner of its own, and the docs
workflow only proves that it bundles (wrangler deploy --dry-run). These run
its pure modules, and index.js itself with a stand-in for the ASSETS
binding, under node when it is installed. Node 18 and later have the
Request, Response and Headers classes the Worker uses, so no package is
installed and nothing touches the network.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKER = REPO_ROOT / "worker"
NODE = shutil.which("node")

# Loads the module named by MODULE as m; the caller's source follows and
# prints its result as JSON.
PRELUDE = """
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(process.env.MODULE).href);
"""

# A fake ASSETS binding that answers every request with the status in
# UPSTREAM_STATUS, and a helper that runs index.js for one request and
# returns its status, headers (lowercased names) and body.
FETCH_HELPER = """
const worker = m.default;
async function run(url, { method = "GET", status = 200, env = {} } = {}) {
  const assets = {
    async fetch() {
      const body = status === 304 ? null : "upstream " + status;
      return new Response(body, { status, headers: { "Content-Type": "text/plain" } });
    },
  };
  const response = await worker.fetch(new Request(url, { method }), { ...env, ASSETS: assets });
  const headers = {};
  for (const [name, value] of response.headers) headers[name.toLowerCase()] = value;
  const body = method === "HEAD" || response.status === 304 ? "" : await response.text();
  return { status: response.status, headers, body };
}
"""


def worker_eval(module: str, source: str, **env: str) -> object:
    """Import worker/<module> as m, run source (an ES module body that writes
    JSON to stdout) and return the parsed result."""
    assert NODE is not None
    result = subprocess.run(
        [NODE, "--input-type=module", "-e", PRELUDE + source],
        capture_output=True,
        text=True,
        timeout=30,
        cwd=WORKER,
        env={**os.environ, "MODULE": str(WORKER / module), **env},
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError("node exited %d: %s" % (result.returncode, result.stderr))
    return json.loads(result.stdout)


def cache_control(paths: list[str]) -> dict[str, str | None]:
    out = worker_eval(
        "cache.js",
        "const out = {};\n"
        "for (const p of JSON.parse(process.env.PATHS)) out[p] = m.cacheControl(p);\n"
        "process.stdout.write(JSON.stringify(out));",
        PATHS=json.dumps(paths),
    )
    assert isinstance(out, dict)
    return out


def fetch_through_worker(requests: list[dict[str, object]]) -> list[dict[str, object]]:
    """Run each request ({url, method, status, env}) through index.js."""
    out = worker_eval(
        "index.js",
        FETCH_HELPER
        + "const results = [];\n"
        "for (const r of JSON.parse(process.env.REQUESTS)) results.push(await run(r.url, r));\n"
        "process.stdout.write(JSON.stringify(results));",
        REQUESTS=json.dumps(requests),
    )
    assert isinstance(out, list)
    return out


@unittest.skipUnless(NODE, "node not installed")
class CachePolicyTests(unittest.TestCase):
    IMMUTABLE = "public, max-age=31536000, immutable"

    def assert_table(self, table: dict[str, str | None]) -> None:
        self.assertTrue(table, "empty table")
        result = cache_control(list(table))
        checked = 0
        for path, expected in table.items():
            with self.subTest(path=path):
                self.assertEqual(result[path], expected)
            checked += 1
        self.assertEqual(checked, len(table))

    def test_hashed_material_assets_are_immutable(self) -> None:
        self.assert_table({
            "/assets/javascripts/bundle.d7400e89.min.js": self.IMMUTABLE,
            "/assets/stylesheets/main.ec1eaa64.min.css": self.IMMUTABLE,
            "/assets/stylesheets/palette.ab4e12ef.min.css": self.IMMUTABLE,
            "/assets/javascripts/workers/search.2c215733.min.js": self.IMMUTABLE,
        })

    def test_source_maps_and_unhashed_files_are_not(self) -> None:
        self.assert_table({
            "/assets/javascripts/bundle.d7400e89.min.js.map": None,
            "/assets/javascripts/lunr/min/lunr.stemmer.support.min.js": None,
            "/assets/javascripts/lunr/tinyseg.js": None,
            "/assets/javascripts/rpt-table-filter.js": None,
            "/stylesheets/extra.css": None,
            "/stylesheets/theme/rpt-theme.css": None,
            "/assets/javascripts/bundle.D7400E89.min.js": None,
            "/assets/javascripts/bundle.d7400e8.min.js": None,
        })

    def test_fonts_and_images_get_short_lifetimes(self) -> None:
        self.assert_table({
            "/assets/fonts/ibm-plex-sans-latin-400-normal.woff2": "public, max-age=604800",
            "/assets/images/logo.svg": "public, max-age=86400",
            "/assets/images/favicon-32.png": "public, max-age=86400",
            "/assets/fonts/README.md": None,
        })

    def test_version_txt_is_no_store(self) -> None:
        self.assert_table({"/version.txt": "no-store", "/x/version.txt": None})

    def test_html_search_index_and_sitemap_keep_the_default(self) -> None:
        self.assert_table({
            "/": None,
            "/index.html": None,
            "/runbooks/": None,
            "/404.html": None,
            "/search/search_index.json": None,
            "/sitemap.xml": None,
            "/sitemap.xml.gz": None,
        })

    def test_path_traversal_lookalikes_do_not_match(self) -> None:
        self.assert_table({
            "/assets/../x.min.js": None,
            "/assets/javascripts/..%2fbundle.d7400e89.min.js": None,
            "/assets/javascripts/../bundle.d7400e89.min.js": None,
            "//assets/javascripts/bundle.d7400e89.min.js": None,
            "/assets/javascripts/bundle.d7400e89.min.js/": None,
        })


@unittest.skipUnless(NODE, "node not installed")
class WorkerFetchTests(unittest.TestCase):
    SECURITY = ["x-content-type-options", "referrer-policy", "x-frame-options"]

    def test_cache_control_only_on_successful_reads(self) -> None:
        base = "https://ops.szolotov.com"
        cases = [
            ({"url": base + "/assets/javascripts/bundle.d7400e89.min.js"},
             "public, max-age=31536000, immutable"),
            ({"url": base + "/assets/javascripts/bundle.d7400e89.min.js", "status": 304},
             "public, max-age=31536000, immutable"),
            ({"url": base + "/assets/javascripts/bundle.d7400e89.min.js", "method": "HEAD"},
             "public, max-age=31536000, immutable"),
            ({"url": base + "/assets/fonts/ibm-plex-mono-latin-400-normal.woff2"},
             "public, max-age=604800"),
            ({"url": base + "/assets/images/logo.svg"}, "public, max-age=86400"),
            ({"url": base + "/version.txt"}, "no-store"),
            ({"url": base + "/runbooks/"}, None),
            # A missing file is never cached as long-lived.
            ({"url": base + "/assets/javascripts/bundle.0badf00d.min.js", "status": 404}, None),
            ({"url": base + "/version.txt", "status": 500}, None),
            ({"url": base + "/version.txt", "method": "POST"}, None),
        ]
        self.assertTrue(cases)
        results = fetch_through_worker([request for request, _ in cases])
        self.assertEqual(len(results), len(cases))
        checked = 0
        for (request, expected), result in zip(cases, results):
            with self.subTest(request=request):
                headers = result["headers"]
                assert isinstance(headers, dict)
                self.assertEqual(headers.get("cache-control"), expected)
                for name in self.SECURITY:
                    self.assertIn(name, headers)
            checked += 1
        self.assertEqual(checked, len(cases))

    def test_status_and_body_pass_through(self) -> None:
        results = fetch_through_worker([
            {"url": "https://ops.szolotov.com/runbooks/"},
            {"url": "https://ops.szolotov.com/missing/", "status": 404},
        ])
        self.assertEqual([r["status"] for r in results], [200, 404])
        self.assertEqual([r["body"] for r in results], ["upstream 200", "upstream 404"])


def security_headers(url: str) -> dict[str, str]:
    out = worker_eval(
        "security.js",
        "process.stdout.write(JSON.stringify(m.securityHeaders(process.env.URL)));",
        URL=url,
    )
    assert isinstance(out, dict)
    return out


@unittest.skipUnless(NODE, "node not installed")
class SecurityHeaderTests(unittest.TestCase):
    HTTPS = "https://ops.szolotov.com/runbooks/"

    def test_csp_contains_only_non_fetch_directives(self) -> None:
        # The guard against a pasted-in policy that would break Material's
        # inline scripts, styles and configuration.
        csp = security_headers(self.HTTPS)["Content-Security-Policy"]
        directives = [part.strip().split()[0] for part in csp.split(";") if part.strip()]
        self.assertEqual(
            set(directives), {"base-uri", "form-action", "frame-ancestors", "object-src"}
        )
        self.assertEqual(len(directives), 4)
        for fetch_directive in ("default-src", "script-src", "style-src", "img-src",
                                "font-src", "connect-src", "worker-src", "frame-src"):
            with self.subTest(directive=fetch_directive):
                self.assertNotIn(fetch_directive, csp)
        self.assertIn("frame-ancestors 'none'", csp)
        self.assertIn("object-src 'none'", csp)

    def test_hsts_only_on_https(self) -> None:
        self.assertEqual(
            security_headers(self.HTTPS).get("Strict-Transport-Security"), "max-age=31536000"
        )
        for url in ("http://localhost:8787/", "http://ops.szolotov.com/", "not a url"):
            with self.subTest(url=url):
                self.assertNotIn("Strict-Transport-Security", security_headers(url))

    def test_hsts_has_no_include_subdomains_or_preload(self) -> None:
        value = security_headers(self.HTTPS)["Strict-Transport-Security"].lower()
        self.assertNotIn("includesubdomains", value)
        self.assertNotIn("preload", value)

    def test_values_have_no_line_breaks_or_non_ascii(self) -> None:
        # Headers.set throws on a value it cannot send.
        headers = security_headers(self.HTTPS)
        self.assertTrue(headers)
        for name, value in headers.items():
            with self.subTest(name=name):
                self.assertRegex(name, r"^[A-Za-z0-9-]+$")
                self.assertRegex(value, r"^[\x20-\x7e]+$")

    def test_permissions_policy_disables_the_listed_features(self) -> None:
        policy = security_headers(self.HTTPS)["Permissions-Policy"]
        entries = dict(part.strip().split("=", 1) for part in policy.split(","))
        features = ["accelerometer", "camera", "geolocation", "gyroscope", "magnetometer",
                    "microphone", "payment", "usb"]
        for feature in features:
            with self.subTest(feature=feature):
                self.assertEqual(entries.get(feature), "()")
        # The code copy button needs the clipboard.
        self.assertNotIn("clipboard-write", entries)
        self.assertEqual(len(entries), len(features))

    def test_existing_three_headers_are_unchanged(self) -> None:
        headers = security_headers(self.HTTPS)
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Referrer-Policy"], "strict-origin-when-cross-origin")
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertEqual(headers["Cross-Origin-Opener-Policy"], "same-origin")
        self.assertEqual(headers["X-Permitted-Cross-Domain-Policies"], "none")

    def test_headers_on_every_response_and_robots_only_on_stage(self) -> None:
        stage = {"ROBOTS": "noindex"}
        cases = [
            ({"url": self.HTTPS}, False),
            ({"url": "https://ops.szolotov.com/missing/", "status": 404}, False),
            ({"url": self.HTTPS, "method": "HEAD"}, False),
            ({"url": "https://stage.ops.szolotov.com/", "env": stage}, True),
            ({"url": "https://stage.ops.szolotov.com/x/", "status": 404, "env": stage}, True),
        ]
        results = fetch_through_worker([request for request, _ in cases])
        self.assertEqual(len(results), len(cases))
        checked = 0
        for (request, robots), result in zip(cases, results):
            with self.subTest(request=request):
                headers = result["headers"]
                assert isinstance(headers, dict)
                for name in ("content-security-policy", "permissions-policy",
                             "cross-origin-opener-policy", "strict-transport-security",
                             "x-frame-options", "x-content-type-options", "referrer-policy"):
                    self.assertIn(name, headers)
                if robots:
                    self.assertEqual(headers.get("x-robots-tag"), "noindex")
                else:
                    self.assertNotIn("x-robots-tag", headers)
            checked += 1
        self.assertEqual(checked, len(cases))


def well_known(calls: list[dict[str, object]]) -> list[object]:
    """Call wellknown.js for each {fn, url, env, now} and return the results.
    now is an ISO timestamp, so nothing depends on today's date."""
    out = worker_eval(
        "wellknown.js",
        "const out = [];\n"
        "for (const c of JSON.parse(process.env.CALLS)) {\n"
        "  const now = new Date(c.now || '2026-01-01T00:00:00Z');\n"
        "  if (c.fn === 'robots') out.push(m.robotsTxt(c.url, c.env || {}));\n"
        "  else if (c.fn === 'security') out.push(m.securityTxt(c.url, now));\n"
        "  else out.push(m.wellKnown(c.url, c.env || {}, now));\n"
        "}\n"
        "process.stdout.write(JSON.stringify(out));",
        CALLS=json.dumps(calls),
    )
    assert isinstance(out, list)
    return out


@unittest.skipUnless(NODE, "node not installed")
class WellKnownTests(unittest.TestCase):
    PROD = "https://ops.szolotov.com"
    STAGE = "https://stage.ops.szolotov.com"
    WORKERS_DEV = "https://ops-toolbox.example.workers.dev"
    NOINDEX = {"ROBOTS": "noindex"}

    def robots(self, origin: str, env: dict[str, str] | None = None) -> str:
        [body] = well_known([{"fn": "robots", "url": origin + "/robots.txt", "env": env or {}}])
        assert isinstance(body, str)
        return body

    def security(self, url: str, now: str) -> str:
        [body] = well_known([{"fn": "security", "url": url, "now": now}])
        assert isinstance(body, str)
        return body

    def test_robots_for_production_allows_and_names_the_sitemap(self) -> None:
        body = self.robots(self.PROD)
        self.assertEqual(
            body, "User-agent: *\nAllow: /\n\nSitemap: https://ops.szolotov.com/sitemap.xml\n"
        )

    def test_robots_for_stage_does_not_disallow(self) -> None:
        body = self.robots(self.STAGE, self.NOINDEX)
        self.assertIn("Disallow:\n", body)
        self.assertNotIn("Disallow: /", body)

    def test_robots_for_stage_has_no_sitemap_line(self) -> None:
        self.assertNotIn("Sitemap:", self.robots(self.STAGE, self.NOINDEX))

    def test_robots_on_workers_dev_has_no_sitemap_line(self) -> None:
        body = self.robots(self.WORKERS_DEV)
        self.assertNotIn("Sitemap:", body)
        self.assertNotIn("Disallow: /", body)

    def test_security_txt_has_required_fields_and_https_contact(self) -> None:
        body = self.security(self.PROD + "/.well-known/security.txt", "2026-03-01T12:34:56.789Z")
        fields = {}
        for line in body.splitlines():
            if line:
                name, _, value = line.partition(": ")
                fields[name] = value
        self.assertTrue(fields)
        self.assertTrue(fields["Contact"].startswith("https://"), fields["Contact"])
        self.assertTrue(fields["Contact"].endswith("/security/advisories/new"))
        self.assertTrue(fields["Policy"].endswith("/SECURITY.md"))
        self.assertEqual(fields["Preferred-Languages"], "en")
        expires = datetime.strptime(fields["Expires"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
        now = datetime(2026, 3, 1, 12, 34, 56, tzinfo=timezone.utc)
        self.assertEqual(expires - now, timedelta(days=180))
        self.assertTrue(body.endswith("\n"))

    def test_security_txt_canonical_uses_the_request_origin(self) -> None:
        for origin in (self.PROD, self.STAGE, "http://localhost:8787"):
            with self.subTest(origin=origin):
                body = self.security(origin + "/.well-known/security.txt", "2026-01-01T00:00:00Z")
                self.assertIn("Canonical: %s/.well-known/security.txt\n" % origin, body)

    def test_unrelated_paths_return_null(self) -> None:
        paths = ["/", "/robots.txt/", "/ROBOTS.TXT", "/security.txt",
                 "/.well-known/", "/x/robots.txt", "/sitemap.xml"]
        results = well_known([{"fn": "wellKnown", "url": self.PROD + p} for p in paths])
        self.assertEqual(len(results), len(paths))
        for path, result in zip(paths, results):
            with self.subTest(path=path):
                self.assertIsNone(result)
        found = well_known([{"fn": "wellKnown", "url": self.PROD + "/robots.txt"}])[0]
        self.assertIsInstance(found, dict)
        assert isinstance(found, dict)
        self.assertEqual(found["contentType"], "text/plain; charset=utf-8")

    def test_through_the_worker(self) -> None:
        cases = [
            # The site has no robots.txt: the Worker answers it.
            {"url": self.PROD + "/robots.txt", "status": 404},
            # The site ships its own: it is passed through untouched.
            {"url": self.PROD + "/robots.txt", "status": 200},
            {"url": self.PROD + "/.well-known/security.txt", "status": 404},
            # Only GET and HEAD are answered.
            {"url": self.PROD + "/robots.txt", "status": 404, "method": "POST"},
            {"url": self.PROD + "/robots.txt", "status": 404, "method": "HEAD"},
            {"url": self.STAGE + "/robots.txt", "status": 404, "env": self.NOINDEX},
            {"url": self.WORKERS_DEV + "/robots.txt", "status": 404},
        ]
        results = fetch_through_worker(cases)
        self.assertEqual(len(results), len(cases))
        made, passed, security, post, head, stage, workers_dev = results

        self.assertEqual(made["status"], 200)
        self.assertIn("Sitemap: https://ops.szolotov.com/sitemap.xml", str(made["body"]))
        self.assertEqual(passed["status"], 200)
        self.assertEqual(passed["body"], "upstream 200")
        self.assertEqual(security["status"], 200)
        self.assertIn("Contact: https://", str(security["body"]))
        self.assertEqual(post["status"], 404)
        self.assertEqual(post["body"], "upstream 404")
        self.assertEqual(head["status"], 200)
        self.assertEqual(stage["status"], 200)
        self.assertNotIn("Sitemap:", str(stage["body"]))
        self.assertEqual(workers_dev["status"], 200)

        checked = 0
        for result in (made, security, head, stage, workers_dev):
            headers = result["headers"]
            assert isinstance(headers, dict)
            self.assertEqual(headers.get("content-type"), "text/plain; charset=utf-8")
            self.assertEqual(headers.get("cache-control"), "public, max-age=3600")
            self.assertIn("content-security-policy", headers)
            self.assertIn("x-content-type-options", headers)
            checked += 1
        self.assertEqual(checked, 5)
        # The stage preview keeps its noindex header; production and the
        # workers.dev address never get one (the production smoke test fails
        # if workers.dev answers with it).
        stage_headers = stage["headers"]
        assert isinstance(stage_headers, dict)
        self.assertEqual(stage_headers.get("x-robots-tag"), "noindex")
        for result in (made, security, workers_dev):
            headers = result["headers"]
            assert isinstance(headers, dict)
            self.assertNotIn("x-robots-tag", headers)


if __name__ == "__main__":
    unittest.main()

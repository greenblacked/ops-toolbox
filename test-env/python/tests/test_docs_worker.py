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


if __name__ == "__main__":
    unittest.main()

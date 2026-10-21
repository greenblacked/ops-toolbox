"""Tests for the documentation site's search configuration and page scripts.

mkdocs is not a dependency of this suite, so nothing here builds the site.
The configuration and the theme files are read as text, and the pure
functions of the page scripts under overrides/assets/javascripts/ run under
node when it is installed. The browser wiring around those functions (the
DOM, storage and events) is not exercised here; the functions are where the
decisions are, which is why each script exports them.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
MKDOCS_YML = REPO_ROOT / "mkdocs.yml"
OVERRIDES = REPO_ROOT / "overrides"
SCRIPTS_DIR = OVERRIDES / "assets" / "javascripts"
THEME_CSS = REPO_ROOT / "docs" / "stylesheets" / "theme" / "rpt-theme.css"
NODE = shutil.which("node")


def node_json(source: str, **env: str) -> object:
    """Run a node script given as text and return its stdout parsed as JSON."""
    assert NODE is not None
    result = subprocess.run(
        [NODE, "-e", source],
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, **env},
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError("node exited %d: %s" % (result.returncode, result.stderr))
    return json.loads(result.stdout)


def script_json(script: Path, expression: str) -> object:
    """Load a page script as CommonJS (no package.json sits above it) and
    print one JavaScript expression over its exports, bound to m, as JSON."""
    source = (
        "const m = require(process.env.RPT_SCRIPT);\n"
        "process.stdout.write(JSON.stringify(%s));" % expression
    )
    return node_json(source, RPT_SCRIPT=str(script))


def search_separator() -> str | None:
    """The separator option of the search plugin in mkdocs.yml, unquoted."""
    text = MKDOCS_YML.read_text(encoding="utf-8")
    match = re.search(
        r"^  - search:[ \t]*\n(?:[ \t]*#.*\n)*[ \t]+separator:[ \t]*'((?:[^']|'')*)'[ \t]*$",
        text,
        re.MULTILINE,
    )
    return match.group(1).replace("''", "'") if match else None


def split_terms(separator: str, text: str) -> list[str]:
    return [term for term in re.split(separator, text) if term]


class SearchSeparatorTests(unittest.TestCase):
    """Material's default separator splits only at whitespace and hyphens, so
    disk_cleanup.sh was one token and 'cleanup' never found it. These pin the
    splits the site's search depends on."""

    def separator(self) -> str:
        value = search_separator()
        assert value is not None, "mkdocs.yml has no separator in the search plugin"
        return value

    def test_mkdocs_yml_sets_search_separator(self) -> None:
        self.assertIsNotNone(search_separator(), "the search plugin has no separator option")

    def test_separator_splits_script_names_and_flags(self) -> None:
        self.assertEqual(
            split_terms(self.separator(), "linux/disk_cleanup.sh --dry-run"),
            ["linux", "disk", "cleanup", "sh", "dry", "run"],
        )

    def test_separator_keeps_versions_whole(self) -> None:
        samples = ["7.24.6", "0.1.4"]
        self.assertTrue(samples)
        for version in samples:
            with self.subTest(version=version):
                self.assertEqual(split_terms(self.separator(), version), [version])

    def test_separator_splits_camel_case_globals(self) -> None:
        self.assertEqual(split_terms(self.separator(), "TgBotToken"), ["Tg", "Bot", "Token"])

    @unittest.skipUnless(NODE, "node not installed")
    def test_separator_is_a_valid_javascript_regexp(self) -> None:
        # The search worker compiles the separator with new RegExp(sep, "g")
        # and walks it with exec(), stepping past zero-width matches. This is
        # the same loop, so a pattern Python accepts but JavaScript does not,
        # or one that splits differently there, fails here.
        source = """
        const re = new RegExp(process.env.SEP, "g");
        const out = {};
        for (const sample of JSON.parse(process.env.SAMPLES)) {
          const terms = [];
          let start = 0;
          let match;
          re.lastIndex = 0;
          do {
            match = re.exec(sample);
            const end = match ? match.index : sample.length;
            if (start < end) terms.push(sample.slice(start, end));
            if (match) {
              start = match.index + match[0].length;
              if (match[0].length === 0) re.lastIndex = match.index + 1;
            }
          } while (match);
          out[sample] = terms;
        }
        process.stdout.write(JSON.stringify(out));
        """
        samples = [
            "RouterBackupPassword",
            "linux/disk_cleanup.sh --dry-run",
            "7.24.6",
            "ops.szolotov.com",
            "a &lt;b&gt; c",
        ]
        result = node_json(source, SEP=self.separator(), SAMPLES=json.dumps(samples))
        self.assertIsInstance(result, dict)
        self.assertEqual(result["RouterBackupPassword"], ["Router", "Backup", "Password"])
        checked = 0
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertEqual(result[sample], split_terms(self.separator(), sample))
                checked += 1
        self.assertEqual(checked, len(samples))


class TableFilterTests(unittest.TestCase):
    SCRIPT = SCRIPTS_DIR / "rpt-table-filter.js"

    def call(self, expression: str) -> object:
        return script_json(self.SCRIPT, expression)

    @unittest.skipUnless(NODE, "node not installed")
    def test_matches_requires_every_term(self) -> None:
        row = "linux/system_doctor.sh Linux Long read-only health report."
        cases = [("linux doctor", True), ("doctor linux", True), ("linux cleanup", False)]
        self.assertTrue(cases)
        for query, expected in cases:
            with self.subTest(query=query):
                self.assertIs(self.call("m.matches(%s, %s)" % (json.dumps(row), json.dumps(query))),
                              expected)

    @unittest.skipUnless(NODE, "node not installed")
    def test_matches_is_case_and_punctuation_tolerant(self) -> None:
        row = "linux/disk_cleanup.sh  Linux\n Frees space. --dry-run"
        self.assertIs(self.call("m.matches(%s, 'Dry Run')" % json.dumps(row)), True)
        self.assertIs(self.call("m.matches(%s, '  DISK_cleanup ')" % json.dumps(row)), True)

    @unittest.skipUnless(NODE, "node not installed")
    def test_matches_empty_query_matches_everything(self) -> None:
        queries = ["", "   ", "\t\n"]
        self.assertTrue(queries)
        for query in queries:
            with self.subTest(query=query):
                self.assertIs(self.call("m.matches('any row', %s)" % json.dumps(query)), True)

    @unittest.skipUnless(NODE, "node not installed")
    def test_count_label_singular_and_none(self) -> None:
        self.assertEqual(self.call("m.countLabel(12, 97, 'linux')"), "Showing 12 of 97 rows")
        self.assertEqual(self.call("m.countLabel(1, 97, 'linux')"), "Showing 1 of 97 rows")
        self.assertEqual(self.call("m.countLabel(1, 1, 'linux')"), "Showing 1 of 1 row")
        self.assertEqual(self.call("m.countLabel(0, 97, ' XYZ ')"), 'No rows match "xyz"')
        # No query, nothing to announce.
        self.assertEqual(self.call("m.countLabel(97, 97, '')"), "")

    @unittest.skipUnless(NODE, "node not installed")
    def test_read_query_decodes_plus_and_percent_and_caps_length(self) -> None:
        self.assertEqual(self.call("m.readQuery('?filter=dry+run')"), "dry run")
        self.assertEqual(self.call("m.readQuery('?a=1&filter=linux%20doctor&b=2')"), "linux doctor")
        self.assertEqual(self.call("m.readQuery('?filters=x')"), "")
        self.assertEqual(self.call("m.readQuery('')"), "")
        long_value = self.call("m.readQuery('?filter=' + 'a'.repeat(500))")
        self.assertEqual(long_value, "a" * 100)

    @unittest.skipUnless(NODE, "node not installed")
    def test_read_query_survives_bad_percent_encoding(self) -> None:
        self.assertEqual(self.call("m.readQuery('?filter=%E0%A4%A')"), "%E0%A4%A")

    def test_main_html_loads_the_script(self) -> None:
        main = (OVERRIDES / "main.html").read_text(encoding="utf-8")
        self.assertIn("{% block scripts %}", main)
        self.assertIn("{{ super() }}", main)
        self.assertIn("'assets/javascripts/rpt-table-filter.js' | url", main)

    def test_theme_css_defines_filter_and_print_override(self) -> None:
        css = THEME_CSS.read_text(encoding="utf-8")
        self.assertIn(".rpt-filter", css)
        print_blocks = re.findall(r"@media print \{(.*?)\n\}", css, re.DOTALL)
        self.assertTrue(print_blocks, "the theme has no print rules")
        self.assertTrue(
            any("tr[hidden]" in block for block in print_blocks),
            "no print rule shows the rows a filter hid",
        )


class ChecklistTests(unittest.TestCase):
    SCRIPT = SCRIPTS_DIR / "rpt-checklist.js"

    def call(self, expression: str) -> object:
        return script_json(self.SCRIPT, expression)

    def test_mkdocs_yml_enables_tasklist_with_clickable_checkbox(self) -> None:
        text = MKDOCS_YML.read_text(encoding="utf-8")
        block = re.search(r"^markdown_extensions:\n((?:[ #].*\n|\n)*)", text, re.MULTILINE)
        self.assertIsNotNone(block, "mkdocs.yml has no markdown_extensions block")
        assert block is not None
        tasklist = re.search(
            r"^  - pymdownx\.tasklist:\n((?:    .*\n)+)", block.group(1), re.MULTILINE
        )
        self.assertIsNotNone(tasklist, "pymdownx.tasklist is not enabled with options")
        assert tasklist is not None
        self.assertRegex(tasklist.group(1), r"(?m)^\s+custom_checkbox:\s*true\s*$")
        self.assertRegex(tasklist.group(1), r"(?m)^\s+clickable_checkbox:\s*true\s*$")

    def test_theme_restyles_task_list(self) -> None:
        css = THEME_CSS.read_text(encoding="utf-8")
        rule = re.search(r"\.task-list-indicator::?before\s*\{([^}]*)\}", css)
        self.assertIsNotNone(rule, "the theme does not restyle the task-list box")
        assert rule is not None
        self.assertIn("--rpt-control-border", rule.group(1))
        self.assertRegex(css, r":focus-visible\s*\+\s*\.task-list-indicator")

    def test_quick_start_has_a_checklist(self) -> None:
        page = REPO_ROOT / "docs" / "getting-started" / "quick-start.md"
        steps = [
            line
            for line in page.read_text(encoding="utf-8").splitlines()
            if line.startswith("- [ ] ")
        ]
        self.assertGreaterEqual(len(steps), 3, "the quick start lost its live checklist")

    @unittest.skipUnless(NODE, "node not installed")
    def test_item_key_includes_index_and_truncated_text(self) -> None:
        text = "Run   the preview\n and read " + "x" * 100
        key = self.call("m.itemKey(4, %s)" % json.dumps(text))
        self.assertIsInstance(key, str)
        assert isinstance(key, str)
        self.assertTrue(key.startswith("4:Run the preview and read x"), key)
        self.assertEqual(len(key), len("4:") + 60)

    @unittest.skipUnless(NODE, "node not installed")
    def test_item_key_distinguishes_identical_text_at_different_positions(self) -> None:
        keys = self.call("[m.itemKey(0, 'Apply'), m.itemKey(3, 'Apply')]")
        self.assertEqual(keys, ["0:Apply", "3:Apply"])

    @unittest.skipUnless(NODE, "node not installed")
    def test_parse_state_accepts_object_and_rejects_garbage(self) -> None:
        good = self.call("""m.parseState('{"0:a":1,"1:b":0,"2:c":"1","3:d":true}')""")
        self.assertEqual(good, {"0:a": 1})
        garbage = ["null", "'[]'", "'\"x\"'", "'{bad json'", "'5'", "5", "undefined", "'null'"]
        self.assertTrue(garbage)
        for raw in garbage:
            with self.subTest(raw=raw):
                self.assertEqual(self.call("m.parseState(%s)" % raw), {})

    @unittest.skipUnless(NODE, "node not installed")
    def test_serialize_drops_unticked_items(self) -> None:
        stored = self.call(
            "m.serialize([{key: '0:a', checked: true}, {key: '1:b', checked: false},"
            " {key: '2:c', checked: true}])"
        )
        self.assertIsInstance(stored, str)
        assert isinstance(stored, str)
        self.assertEqual(json.loads(stored), {"0:a": 1, "2:c": 1})

    @unittest.skipUnless(NODE, "node not installed")
    def test_progress_label_wording(self) -> None:
        cases = [((0, 3), "0 of 3 steps done"), ((1, 1), "1 of 1 step done"),
                 ((3, 7), "3 of 7 steps done")]
        self.assertTrue(cases)
        for (done, total), expected in cases:
            with self.subTest(done=done, total=total):
                self.assertEqual(self.call("m.progressLabel(%d, %d)" % (done, total)), expected)


class NotFoundSuggestionTests(unittest.TestCase):
    SCRIPT = SCRIPTS_DIR / "rpt-404.js"
    TEMPLATE = OVERRIDES / "404.html"

    # Shaped like the docs entries of Material's search/search_index.json: one
    # entry per page and one per section, the section's location carrying an
    # anchor.
    DOCS = [
        {"location": "", "title": "Ops Toolbox", "text": "home"},
        {"location": "runbooks/", "title": "Runbooks", "text": ""},
        {"location": "runbooks/#how-a-runbook-is-laid-out", "title": "Linux disk", "text": ""},
        {"location": "runbooks/linux-low-disk/", "title": "A Linux host is low on disk space",
         "text": ""},
        {"location": "runbooks/linux-low-disk/#report", "title": "Report", "text": ""},
        {"location": "platforms/linux/", "title": "Linux", "text": ""},
        {"location": "platforms/disk-tools/", "title": "Storage", "text": ""},
    ]

    def call(self, expression: str) -> object:
        return script_json(self.SCRIPT, expression)

    @unittest.skipUnless(NODE, "node not installed")
    def test_terms_from_path_splits_segments_and_words(self) -> None:
        self.assertEqual(
            self.call("m.termsFromPath('/runbooks/linux-low-disk-old/')"),
            ["runbooks", "linux", "low", "disk", "old"],
        )
        self.assertEqual(self.call("m.termsFromPath('/Platforms/Disk_Tools.v2/')"),
                         ["platforms", "disk", "tools", "v2"])

    @unittest.skipUnless(NODE, "node not installed")
    def test_terms_from_path_strips_html_and_md_extensions(self) -> None:
        cases = {
            "/platforms/linux.html": ["platforms", "linux"],
            "/platforms/linux.md": ["platforms", "linux"],
            "/runbooks/index.html": ["runbooks"],
            "/runbooks/index.md": ["runbooks"],
        }
        self.assertTrue(cases)
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(self.call("m.termsFromPath(%s)" % json.dumps(path)), expected)

    @unittest.skipUnless(NODE, "node not installed")
    def test_terms_from_path_survives_bad_encoding(self) -> None:
        terms = self.call("m.termsFromPath('/disk%E0%A4%A/cleanup/')")
        self.assertIsInstance(terms, list)
        self.assertIn("cleanup", terms)
        self.assertEqual(self.call("m.termsFromPath('/linux%20disk/')"), ["linux", "disk"])

    @unittest.skipUnless(NODE, "node not installed")
    def test_terms_are_capped_and_deduplicated(self) -> None:
        terms = self.call("m.termsFromPath('/a/disk/disk-disk/one-two-three-four-five-six-seven/')")
        self.assertEqual(terms, ["disk", "one", "two", "three", "four", "five", "six", "seven"])
        self.assertEqual(self.call("m.termsFromPath('/')"), [])

    def rank(self, terms: list[str], limit: int = 3) -> object:
        return self.call(
            "m.rank(%s, %s, %d)" % (json.dumps(self.DOCS), json.dumps(terms), limit)
        )

    @unittest.skipUnless(NODE, "node not installed")
    def test_rank_prefers_title_matches_over_location_matches(self) -> None:
        # "disk" is in the title of the runbook (3 + 1) but only in the
        # address of the disk-tools page (1).
        result = self.rank(["disk"])
        self.assertIsInstance(result, list)
        assert isinstance(result, list)
        self.assertEqual(
            [page["location"] for page in result],
            ["runbooks/linux-low-disk/", "platforms/disk-tools/"],
        )
        self.assertEqual(result[0]["title"], "A Linux host is low on disk space")

    @unittest.skipUnless(NODE, "node not installed")
    def test_rank_ignores_section_anchors_and_returns_each_page_once(self) -> None:
        docs = self.DOCS + [{"location": "runbooks/", "title": "Runbooks again", "text": ""}]
        result = self.call("m.rank(%s, ['runbooks', 'linux'], 10)" % json.dumps(docs))
        self.assertIsInstance(result, list)
        assert isinstance(result, list)
        locations = [page["location"] for page in result]
        self.assertTrue(locations)
        for location in locations:
            with self.subTest(location=location):
                self.assertNotIn("#", location)
        self.assertEqual(len(locations), len(set(locations)))
        self.assertEqual(locations[0], "runbooks/linux-low-disk/")

    @unittest.skipUnless(NODE, "node not installed")
    def test_rank_returns_nothing_when_no_term_matches(self) -> None:
        self.assertEqual(self.rank(["kubernetes"]), [])
        self.assertEqual(self.rank([]), [])

    @unittest.skipUnless(NODE, "node not installed")
    def test_rank_honours_the_limit(self) -> None:
        result = self.rank(["linux", "disk", "runbooks", "platforms"], limit=2)
        self.assertIsInstance(result, list)
        assert isinstance(result, list)
        self.assertEqual(len(result), 2)

    @unittest.skipUnless(NODE, "node not installed")
    def test_safe_location_rejects_scheme_and_protocol_relative(self) -> None:
        bad = ["javascript:alert(1)", "https://example.com/", "//example.com/",
               "/absolute/", "\\\\example.com/", "a\nb", None, 5]
        self.assertTrue(bad)
        for location in bad:
            with self.subTest(location=location):
                self.assertIsNone(self.call("m.safeLocation(%s)" % json.dumps(location)))
        good = ["", "runbooks/", "platforms/linux/"]
        for location in good:
            with self.subTest(location=location):
                self.assertEqual(self.call("m.safeLocation(%s)" % json.dumps(location)), location)

    def test_404_template_has_container_and_script(self) -> None:
        template = self.TEMPLATE.read_text(encoding="utf-8")
        self.assertIn('class="rpt-404__suggest" hidden', template)
        self.assertIn("'search/search_index.json' | url", template)
        self.assertIn("{{ super() }}", template)
        self.assertIn("'assets/javascripts/rpt-404.js' | url", template)

    def test_404_template_makes_no_external_request(self) -> None:
        template = self.TEMPLATE.read_text(encoding="utf-8")
        self.assertNotIn("http", template)
        self.assertNotIn("//", template)


class BuildStampTests(unittest.TestCase):
    SCRIPT = SCRIPTS_DIR / "rpt-build-stamp.js"
    SHA = "6a88b2e" + "0123456789abcdef0123456789abcdef0"

    def call(self, expression: str) -> object:
        return script_json(self.SCRIPT, expression)

    @unittest.skipUnless(NODE, "node not installed")
    def test_parse_sha_accepts_only_forty_hex(self) -> None:
        self.assertEqual(len(self.SHA), 40)
        self.assertEqual(self.call("m.parseSha(%s)" % json.dumps(self.SHA + "\n")), self.SHA)
        bad = [
            self.SHA[:39],
            self.SHA + "a",
            self.SHA.upper(),
            "<b>" + self.SHA[:33] + "</b>",
            "",
            self.SHA[:20] + "\n" + self.SHA[20:],
        ]
        self.assertTrue(bad)
        for text in bad:
            with self.subTest(text=text):
                self.assertIsNone(self.call("m.parseSha(%s)" % json.dumps(text)))
        self.assertIsNone(self.call("m.parseSha(null)"))

    @unittest.skipUnless(NODE, "node not installed")
    def test_commit_url_requires_the_github_repo_pattern(self) -> None:
        repo = "https://github.com/greenblacked/ops-toolbox"
        self.assertEqual(
            self.call("m.commitUrl(%s, %s)" % (json.dumps(repo), json.dumps(self.SHA))),
            repo + "/commit/" + self.SHA,
        )
        self.assertEqual(
            self.call("m.commitUrl(%s, %s)" % (json.dumps(repo + "/"), json.dumps(self.SHA))),
            repo + "/commit/" + self.SHA,
        )
        bad_repos = [
            "http://github.com/greenblacked/ops-toolbox",
            "https://gitlab.com/greenblacked/ops-toolbox",
            "https://github.com.evil.example/greenblacked/ops-toolbox",
            "https://github.com/greenblacked/ops-toolbox/tree/master",
            "javascript:alert(1)//https://github.com/a/b",
            "",
        ]
        self.assertTrue(bad_repos)
        for bad in bad_repos:
            with self.subTest(repo=bad):
                self.assertIsNone(
                    self.call("m.commitUrl(%s, %s)" % (json.dumps(bad), json.dumps(self.SHA)))
                )
        self.assertIsNone(self.call("m.commitUrl(%s, 'not-a-sha')" % json.dumps(repo)))

    @unittest.skipUnless(NODE, "node not installed")
    def test_is_preview_reads_noindex_case_insensitively(self) -> None:
        cases = [("null", False), ("''", False), ("'noindex'", True),
                 ("'NoIndex, nofollow'", True), ("'nofollow'", False), ("'noindexer'", False)]
        self.assertTrue(cases)
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertIs(self.call("m.isPreview(%s)" % value), expected)

    @unittest.skipUnless(NODE, "node not installed")
    def test_short_sha_is_seven_chars(self) -> None:
        self.assertEqual(self.call("m.shortSha(%s)" % json.dumps(self.SHA)), "6a88b2e")

    def test_copyright_partial_carries_repo_url_and_version_url(self) -> None:
        partial = (OVERRIDES / "partials" / "copyright.html").read_text(encoding="utf-8")
        self.assertIn('class="rpt-build" hidden', partial)
        self.assertIn('data-repo="{{ config.repo_url }}"', partial)
        self.assertIn("'version.txt' | url", partial)
        # The reason the override exists in the first place.
        self.assertIn("'credits/' | url", partial)

    def test_stamp_script_is_loaded_from_main_html(self) -> None:
        main = (OVERRIDES / "main.html").read_text(encoding="utf-8")
        self.assertIn("'assets/javascripts/rpt-build-stamp.js' | url", main)


class OsTabTests(unittest.TestCase):
    SCRIPT = SCRIPTS_DIR / "rpt-os-tab.js"

    MAC_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
    WIN_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    LINUX_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
    ANDROID_UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Mobile"
    IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15"
    CROS_UA = "Mozilla/5.0 (X11; CrOS x86_64 15633.69.0) AppleWebKit/537.36"

    def detect(self, nav: dict[str, object]) -> object:
        return script_json(self.SCRIPT, "m.detectOs(%s)" % json.dumps(nav))

    def assert_cases(self, cases: list[tuple[dict[str, object], str | None]]) -> None:
        self.assertTrue(cases)
        for nav, expected in cases:
            with self.subTest(nav=nav):
                self.assertEqual(self.detect(nav), expected)

    @unittest.skipUnless(NODE, "node not installed")
    def test_detect_os_from_user_agent_data(self) -> None:
        self.assert_cases([
            ({"userAgentData": {"platform": "macOS"}, "platform": "Win32"}, "macOS"),
            ({"userAgentData": {"platform": "Windows"}, "userAgent": self.LINUX_UA}, "Windows"),
            ({"userAgentData": {"platform": "Linux"}}, "Linux"),
            ({"userAgentData": {"platform": "Android"}, "userAgent": "Mozilla/5.0"}, None),
        ])

    @unittest.skipUnless(NODE, "node not installed")
    def test_detect_os_falls_back_to_platform_then_user_agent(self) -> None:
        self.assert_cases([
            ({"userAgentData": {"platform": ""}, "platform": "MacIntel"}, "macOS"),
            ({"platform": "Win32", "userAgent": self.WIN_UA}, "Windows"),
            ({"platform": "Linux x86_64", "userAgent": self.LINUX_UA}, "Linux"),
            ({"platform": "", "userAgent": self.MAC_UA, "maxTouchPoints": 0}, "macOS"),
            ({"userAgent": self.WIN_UA}, "Windows"),
            ({"userAgent": self.WIN_UA + " Microsoft"}, "Windows"),
            ({"userAgent": self.LINUX_UA}, "Linux"),
        ])

    @unittest.skipUnless(NODE, "node not installed")
    def test_android_is_not_linux(self) -> None:
        self.assert_cases([
            ({"platform": "Linux armv8l", "userAgent": self.ANDROID_UA, "maxTouchPoints": 5}, None),
            ({"userAgentData": {"platform": "Linux"}, "userAgent": self.ANDROID_UA}, None),
        ])

    @unittest.skipUnless(NODE, "node not installed")
    def test_ios_and_ipados_desktop_mode_are_not_macos(self) -> None:
        self.assert_cases([
            ({"platform": "iPhone", "userAgent": self.IPHONE_UA, "maxTouchPoints": 5}, None),
            ({"platform": "MacIntel", "userAgent": self.MAC_UA, "maxTouchPoints": 5}, None),
        ])

    @unittest.skipUnless(NODE, "node not installed")
    def test_chromeos_maps_to_linux(self) -> None:
        self.assert_cases([
            ({"userAgentData": {"platform": "Chrome OS"}, "userAgent": self.CROS_UA}, "Linux"),
            ({"platform": "Linux x86_64", "userAgent": self.CROS_UA}, "Linux"),
        ])

    @unittest.skipUnless(NODE, "node not installed")
    def test_unknown_returns_null(self) -> None:
        self.assert_cases([
            ({}, None),
            ({"platform": "PlayStation 5", "userAgent": "Mozilla/5.0 (PlayStation 5)"}, None),
            ({"userAgentData": {"platform": "Unknown"}, "platform": ""}, None),
        ])
        self.assertIsNone(script_json(self.SCRIPT, "m.detectOs(null)"))

    @unittest.skipUnless(NODE, "node not installed")
    def test_pick_label_matches_trimmed_text_exactly(self) -> None:
        labels = json.dumps([
            {"textContent": "macOS (Homebrew)"},
            {"textContent": " \n Linux \n"},
            {"textContent": "Windows"},
        ])
        found = script_json(self.SCRIPT, "m.pickLabel(%s, 'Linux')" % labels)
        self.assertEqual(found, {"textContent": " \n Linux \n"})
        self.assertIsNone(script_json(self.SCRIPT, "m.pickLabel(%s, 'macOS')" % labels))
        self.assertIsNone(script_json(self.SCRIPT, "m.pickLabel(%s, 'linux')" % labels))

    @unittest.skipUnless(NODE, "node not installed")
    def test_saved_tab_choice_is_detected(self) -> None:
        # A stand-in for localStorage holding the given entries.
        fake = (
            "(function (entries) { var keys = Object.keys(entries); return {"
            " length: keys.length, key: function (i) { return keys[i]; },"
            " getItem: function (k) { return entries[k]; } }; })(%s)"
        )
        cases = [
            ({"/.__tabs": '["Linux"]'}, True),
            ({"/.__tabs": "[]"}, False),
            ({"/.__tabs": "{bad"}, False),
            ({"/.__palette": '{"index":1}', "rpt.os-tab": "1"}, False),
            ({}, False),
        ]
        self.assertTrue(cases)
        for entries, expected in cases:
            with self.subTest(entries=entries):
                expression = "m.hasSavedTabChoice(%s)" % (fake % json.dumps(entries))
                self.assertIs(script_json(self.SCRIPT, expression), expected)

    def test_quick_start_tab_labels_are_the_os_names(self) -> None:
        page = REPO_ROOT / "docs" / "getting-started" / "quick-start.md"
        lines = set(page.read_text(encoding="utf-8").splitlines())
        for label in ("macOS", "Linux", "Windows"):
            with self.subTest(label=label):
                self.assertIn('=== "%s"' % label, lines)

    def test_script_never_reads_materials_private_functions(self) -> None:
        text = self.SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("__md_get", text)
        self.assertNotIn("__md_set", text)
        self.assertIn("__tabs", text)

    def test_script_is_loaded_from_main_html(self) -> None:
        main = (OVERRIDES / "main.html").read_text(encoding="utf-8")
        self.assertIn("'assets/javascripts/rpt-os-tab.js' | url", main)


class PageScriptContractTests(unittest.TestCase):
    """The page scripts read text an attacker controls: the query string of a
    link (?filter=) and the path of a missing page. So no script may parse
    HTML from a string, evaluate code or talk to another origin. Every file
    in the folder is checked, so a new script is covered by the commit that
    adds it."""

    FORBIDDEN = [
        "innerHTML",
        "outerHTML",
        "insertAdjacentHTML",
        "document.write",
        "eval(",
        "new Function",
        "sendBeacon",
        "XMLHttpRequest",
        "importScripts",
    ]

    def scripts(self) -> list[Path]:
        found = sorted(SCRIPTS_DIR.glob("*.js"))
        self.assertTrue(found, "no page scripts found in %s" % SCRIPTS_DIR)
        return found

    def test_no_html_parsing_eval_or_beacons(self) -> None:
        checked = 0
        for script in self.scripts():
            text = script.read_text(encoding="utf-8")
            for token in self.FORBIDDEN:
                with self.subTest(script=script.name, token=token):
                    self.assertNotIn(token, text)
            checked += 1
        self.assertGreater(checked, 0)

    def test_fetch_never_targets_an_absolute_url(self) -> None:
        checked = 0
        for script in self.scripts():
            text = script.read_text(encoding="utf-8")
            with self.subTest(script=script.name):
                self.assertIsNone(
                    re.search(r"fetch\(\s*['\"`]\s*(?:https?:)?//", text),
                    "fetch() of an absolute or protocol-relative URL",
                )
            checked += 1
        self.assertGreater(checked, 0)


if __name__ == "__main__":
    unittest.main()

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


if __name__ == "__main__":
    unittest.main()

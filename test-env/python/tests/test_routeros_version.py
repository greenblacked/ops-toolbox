"""Tests for the RouterOS release resolver and version bumper."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPO_ROOT / "mikrotik" / "tests" / "routeros_version.py"
SPEC = importlib.util.spec_from_file_location("routeros_version", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
routeros_version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(routeros_version)


class RouterOSVersionTests(unittest.TestCase):
    def test_parse_stable_release_feed(self) -> None:
        payload = b"""<?xml version='1.0'?>
        <rss><channel><item><title>RouterOS 7.23.3 [stable]</title></item></channel></rss>
        """
        self.assertEqual(
            routeros_version.parse_release_feed(payload, "stable"),
            "7.23.3",
        )

    def test_parse_release_feed_rejects_wrong_channel(self) -> None:
        payload = b"""<rss><channel><item>
        <title>RouterOS 7.23.3 [stable]</title>
        </item></channel></rss>"""
        with self.assertRaises(routeros_version.ReleaseError):
            routeros_version.parse_release_feed(payload, "long-term")

    def test_version_comparison_handles_patchless_releases(self) -> None:
        self.assertLess(
            routeros_version.version_key("7.22"),
            routeros_version.version_key("7.22.1"),
        )
        self.assertEqual(
            routeros_version.version_key("7.22"),
            (7, 22, 0),
        )

    def test_only_stable_channel_can_replace_canonical_pin(self) -> None:
        routeros_version.require_promotable_channel("stable")
        with self.assertRaisesRegex(routeros_version.ReleaseError, "check-only"):
            routeros_version.require_promotable_channel("long-term")

    def test_bump_updates_canonical_docs_and_changelog(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            version_file = root / "mikrotik/tests/routeros-version.env"
            version_file.parent.mkdir(parents=True)
            version_file.write_text("# canonical\nROUTEROS_VERSION=7.22\n", encoding="utf-8")
            for relative in routeros_version.DOCUMENTATION_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("tested on RouterOS 7.22\n", encoding="utf-8")
            (root / "CHANGELOG.md").write_text(
                "# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- Existing.\n",
                encoding="utf-8",
            )

            routeros_version.bump_version("7.23.3", root)

            self.assertIn("ROUTEROS_VERSION=7.23.3", version_file.read_text())
            for relative in routeros_version.DOCUMENTATION_FILES:
                text = (root / relative).read_text(encoding="utf-8")
                self.assertIn("RouterOS 7.23.3", text)
                self.assertNotIn("7.22", text)
            changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
            self.assertIn("bumped from 7.22 to 7.23.3", changelog)

    def test_bump_rejects_same_or_older_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            version_file = root / "mikrotik/tests/routeros-version.env"
            version_file.parent.mkdir(parents=True)
            version_file.write_text("ROUTEROS_VERSION=7.22\n", encoding="utf-8")
            with self.assertRaises(routeros_version.ReleaseError):
                routeros_version.bump_version("7.22", root)


if __name__ == "__main__":
    unittest.main()

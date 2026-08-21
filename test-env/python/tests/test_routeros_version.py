"""Tests for the RouterOS release resolver and version bumper."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPO_ROOT / "mikrotik" / "tests" / "routeros_version.py"
SPEC = importlib.util.spec_from_file_location("routeros_version", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
routeros_version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(routeros_version)

# Any valid-shaped digest; these tests never touch the network.
DIGEST = "a" * 64


class RouterOSVersionTests(unittest.TestCase):
    def test_parse_stable_release_feed(self) -> None:
        payload = b"""<?xml version='1.0'?>
        <rss><channel><item><title>RouterOS 7.23.3 [stable]</title></item></channel></rss>
        """
        self.assertEqual(
            routeros_version.parse_release_feed(payload, "stable"),
            "7.23.3",
        )

    def test_parse_release_feed_accepts_multiple_channels(self) -> None:
        # A release sits in every channel it has been promoted through, so the
        # title carries a list rather than one name. 7.24 shipped as
        # "[stable, testing, development]" and the single-token pattern that
        # preceded this failed the scheduled workflow at its first step, before
        # any version was resolved.
        payload = (
            b"<rss><channel><item>"
            b"<title>RouterOS 7.24 [stable, testing, development]</title>"
            b"</item></channel></rss>"
        )
        self.assertEqual(routeros_version.parse_release_feed(payload, "stable"), "7.24")

    def test_parse_release_feed_accepts_channels_without_spaces(self) -> None:
        payload = (
            b"<rss><channel><item>"
            b"<title>RouterOS 7.24 [stable,testing]</title>"
            b"</item></channel></rss>"
        )
        self.assertEqual(routeros_version.parse_release_feed(payload, "stable"), "7.24")

    def test_parse_release_feed_rejects_channel_absent_from_the_list(self) -> None:
        # Widening the pattern must not widen what counts as a match: a release
        # that is not in the requested channel is still refused.
        payload = (
            b"<rss><channel><item>"
            b"<title>RouterOS 7.24 [testing, development]</title>"
            b"</item></channel></rss>"
        )
        with self.assertRaises(routeros_version.ReleaseError):
            routeros_version.parse_release_feed(payload, "stable")

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

            routeros_version.bump_version("7.23.3", root, digest=DIGEST)

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
                routeros_version.bump_version("7.22", root, digest=DIGEST)

    def test_documented_version_replacement_is_anchored(self) -> None:
        """A two-part pin must not rewrite the longer versions around it.

        An unanchored str.replace of "7.23" also turns "7.23.3" into "7.24.3"
        and "17.23" into "17.24" — silent corruption in four documents.
        """
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doc = root / "doc.md"
            doc.write_text("CHR 7.23, CHR 7.23.3, build 17.23\n", encoding="utf-8")
            routeros_version._replace_documented_version(
                root, "7.23", "7.24", files=[Path("doc.md")]
            )
            self.assertEqual(doc.read_text(encoding="utf-8").strip(),
                             "CHR 7.24, CHR 7.23.3, build 17.23")

    def test_validate_sha256(self) -> None:
        self.assertEqual(routeros_version.validate_sha256("A" * 64), "a" * 64)
        for bad in ("", "abc", "z" * 64, "a" * 63, "a" * 65):
            with self.assertRaises(routeros_version.ReleaseError):
                routeros_version.validate_sha256(bad)

    def test_sha256_round_trip_leaves_version_alone(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            env = Path(temp_dir) / "routeros-version.env"
            env.write_text("ROUTEROS_VERSION=7.23.3\nROUTEROS_SHA256=\n", encoding="utf-8")
            self.assertEqual(routeros_version.read_pinned_sha256(env), "")
            routeros_version._write_pinned_sha256(DIGEST, env)
            self.assertEqual(routeros_version.read_pinned_sha256(env), DIGEST)
            self.assertEqual(routeros_version.read_pinned_version(env), "7.23.3")

    def test_bump_records_the_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            version_file = root / "mikrotik/tests/routeros-version.env"
            version_file.parent.mkdir(parents=True)
            version_file.write_text(
                "ROUTEROS_VERSION=7.22\nROUTEROS_SHA256=" + ("b" * 64) + "\n",
                encoding="utf-8",
            )
            for relative in routeros_version.DOCUMENTATION_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("RouterOS 7.22\n", encoding="utf-8")
            (root / "CHANGELOG.md").write_text(
                "## [Unreleased]\n\n### Changed\n\n", encoding="utf-8"
            )
            routeros_version.bump_version("7.23.3", root, digest=DIGEST)
            self.assertEqual(routeros_version.read_pinned_sha256(version_file), DIGEST)


class RecordHashCliTests(unittest.TestCase):
    """--print must resolve a digest without touching the pin.

    The candidate test needs the digest of a version this repository has never
    pinned. Before --print existed the workflow had no way to get one, so it
    built the candidate against the *previous* version's digest and the
    download failed its checksum every time.

    These patch _write_pinned_sha256 rather than VERSION_FILE. That is not a
    style preference: the path is a default argument bound at import, so
    patching the module attribute does not reach it and the write lands on the
    real repository file. Writing this test the obvious way overwrote the live
    pin with a dummy digest.
    """

    CANDIDATE = "c" * 64

    def test_print_emits_the_digest_and_writes_nothing(self) -> None:
        with mock.patch.object(
            routeros_version, "compute_sha256", return_value=self.CANDIDATE
        ), mock.patch.object(routeros_version, "_write_pinned_sha256") as writer:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = routeros_version.main(
                    ["record-hash", "--version", "7.24", "--print"]
                )

        self.assertEqual(rc, 0)
        # Bare digest on stdout, so a shell can assign it directly.
        self.assertEqual(out.getvalue().strip(), self.CANDIDATE)
        writer.assert_not_called()

    def test_without_print_the_digest_is_written(self) -> None:
        # The negative half. Without it the test above would pass even if
        # --print had no effect and nothing ever wrote.
        with mock.patch.object(
            routeros_version, "compute_sha256", return_value=self.CANDIDATE
        ), mock.patch.object(
            routeros_version, "_write_pinned_sha256"
        ) as writer, contextlib.redirect_stdout(io.StringIO()):
            rc = routeros_version.main(["record-hash", "--version", "7.24"])

        self.assertEqual(rc, 0)
        writer.assert_called_once_with(self.CANDIDATE)

    def test_bump_with_a_digest_does_not_download(self) -> None:
        # The bump pins what the candidate test ran against rather than
        # re-downloading, so a republished artifact cannot pin bytes that
        # nothing has booted.
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            version_file = root / "mikrotik/tests/routeros-version.env"
            version_file.parent.mkdir(parents=True)
            version_file.write_text(
                "ROUTEROS_VERSION=7.22\nROUTEROS_SHA256=" + ("b" * 64) + "\n",
                encoding="utf-8",
            )
            for relative in routeros_version.DOCUMENTATION_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("RouterOS 7.22\n", encoding="utf-8")
            (root / "CHANGELOG.md").write_text(
                "## [Unreleased]\n\n### Changed\n\n", encoding="utf-8"
            )

            with mock.patch.object(
                routeros_version,
                "compute_sha256",
                side_effect=AssertionError("bump re-downloaded despite --digest"),
            ):
                routeros_version.bump_version("7.24", root, digest=self.CANDIDATE)

            self.assertEqual(
                routeros_version.read_pinned_sha256(version_file), self.CANDIDATE
            )


class ChangelogInsertionTests(unittest.TestCase):
    """The bump must find "### Changed" wherever it sits, and not corrupt it.

    The original required the literal "## [Unreleased]\\n\\n### Changed\\n\\n", so
    Changed had to be the *first* subsection. This repository's changelog has
    never been shaped that way, which means the bump step could not have
    succeeded even once the candidate test was fixed - any ordinary "### Added"
    entry above it was enough to break the release automation.
    """

    HEADER = "# Changelog\n\nblurb\n\n"
    FOOTER = "\n## [2026-08-01]\n\n### Fixed\n\n- old\n"
    SHAPES = {
        "added_only": "## [Unreleased]\n\n### Added\n\n- a\n",
        "changed_first": "## [Unreleased]\n\n### Changed\n\n- existing\n",
        "changed_empty": "## [Unreleased]\n\n### Changed\n\n### Fixed\n\n- y\n",
        "added_then_fixed": "## [Unreleased]\n\n### Added\n\n- x\n\n### Fixed\n\n- y\n",
        "unreleased_empty": "## [Unreleased]\n",
    }

    def _bump_into(self, shape: str) -> str:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "CHANGELOG.md").write_text(
                self.HEADER + shape + self.FOOTER, encoding="utf-8"
            )
            routeros_version._add_changelog_entry(root, "7.23.3", "7.24")
            return (root / "CHANGELOG.md").read_text(encoding="utf-8")

    def test_entry_lands_in_every_shape(self) -> None:
        for name, shape in self.SHAPES.items():
            with self.subTest(shape=name):
                self.assertIn("bumped from 7.23.3 to 7.24", self._bump_into(shape))

    def test_no_double_blank_lines(self) -> None:
        # markdownlint MD012. A bump that turns the repository red on the
        # commit it just made is not a working bump, and two of the three
        # regexes here produced exactly that by using \s* where the newlines
        # had to be preserved.
        for name, shape in self.SHAPES.items():
            with self.subTest(shape=name):
                self.assertNotIn("\n\n\n", self._bump_into(shape))

    def test_the_entry_joins_the_existing_list(self) -> None:
        # Not separated from it by a blank line, which would split one list
        # into two.
        out = self._bump_into(self.SHAPES["changed_first"])
        self.assertIn(
            "- RouterOS CHR compatibility was bumped from 7.23.3 to 7.24 after "
            "the full Docker integration suite passed.\n- existing\n",
            out,
        )

    def test_changed_is_created_in_keep_a_changelog_order(self) -> None:
        out = self._bump_into(self.SHAPES["added_then_fixed"])
        body = out[out.index("## [Unreleased]") : out.index("## [2026-08-01]")]
        self.assertEqual(
            [line[4:] for line in body.splitlines() if line.startswith("### ")],
            ["Added", "Changed", "Fixed"],
        )

    def test_missing_unreleased_heading_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "CHANGELOG.md").write_text(
                "# Changelog\n\n## [2026-08-01]\n\n### Fixed\n\n- old\n",
                encoding="utf-8",
            )
            with self.assertRaises(routeros_version.ReleaseError):
                routeros_version._add_changelog_entry(root, "7.23.3", "7.24")


class BumpablePathsTests(unittest.TestCase):
    """The bump must never need to rewrite a workflow file.

    GITHUB_TOKEN is refused when it pushes a branch touching .github/workflows -
    "refusing to allow a GitHub App to create or update workflow ... without
    `workflows` permission" - and that permission cannot be granted from a
    workflow's own permissions block. One version number in a chr.yml comment
    was enough to stop the bump branch from being pushed at all, after the CHR
    suite had already passed.
    """

    def test_no_workflow_file_is_rewritten_by_a_bump(self) -> None:
        offenders = [
            str(path)
            for path in routeros_version.DOCUMENTATION_FILES
            if str(path).startswith(".github/workflows/")
        ]
        self.assertEqual(
            offenders,
            [],
            "GITHUB_TOKEN cannot push a branch that edits these; keep the "
            "version out of workflow files",
        )

    def test_no_workflow_file_names_the_pinned_version(self) -> None:
        # The other half: the list above can only stay empty if nothing under
        # .github/workflows/ mentions the pin in the first place.
        workflows = REPO_ROOT / ".github" / "workflows"
        pinned = routeros_version.read_pinned_version()
        naming = [
            path.name
            for path in sorted(workflows.glob("*.yml"))
            if pinned in path.read_text(encoding="utf-8")
        ]
        self.assertEqual(
            naming,
            [],
            f"{naming} name RouterOS {pinned}; the bump would have to rewrite "
            "them and its push would be rejected",
        )


if __name__ == "__main__":
    unittest.main()

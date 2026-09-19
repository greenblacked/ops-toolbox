"""Installed application mapping preserves non-cache data and unknown owners."""

import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "macos-initial-setup/lib"))
import app_cache_inventory as ac


class AppCacheInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="app cache home ")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.apps = self.home / "Applications"
        self.apps.mkdir()

    def app(self, name="Example", bundle="org.example.app", executable="Example"):
        path = self.apps / (name + ".app") / "Contents"
        path.mkdir(parents=True)
        (path / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle, "CFBundleExecutable": executable,
        }))
        return path.parent

    def directory(self, relative):
        path = self.home / relative
        path.mkdir(parents=True, exist_ok=True)
        return path

    def scan(self):
        return ac.classify(str(self.home), [str(self.apps)])

    def test_exact_bundle_cache_and_sandbox_only(self):
        self.app()
        paths = [self.directory("Library/Caches/org.example.app"),
                 self.directory("Library/Containers/org.example.app/Data/Library/Caches")]
        self.directory("Library/Caches/org.example.app.Other")
        self.directory("Library/Containers/org.example.app/Data/Documents/Cache")
        self.directory("Library/Application Support/Example/Session Storage/Cache")
        self.assertEqual({r[3] for r in self.scan()}, {str(p) for p in paths})

    def test_uninstalled_and_apple_and_jetbrains_and_models_kept(self):
        for name, bundle in [("Safari", "com.apple.Safari"), ("PyCharm", "com.jetbrains.pycharm"),
                             ("LM Studio", "ai.elementlabs.lmstudio")]:
            self.app(name, bundle)
            self.directory("Library/Caches/" + bundle)
        self.directory("Library/Caches/uninstalled.app")
        self.assertEqual(self.scan(), [])

    def test_symlinked_cache_ancestor_is_not_followed(self):
        self.app()
        target = self.directory("elsewhere/org.example.app")
        library = self.directory("Library")
        (library / "Caches").symlink_to(target.parent)
        self.assertEqual(self.scan(), [])

    def test_foreign_owner_or_mount_or_writable_directory_kept(self):
        self.app()
        target = self.directory("Library/Caches/org.example.app")
        original = os.lstat
        for index in (2, 4):
            def altered(path, index=index):
                value = original(path)
                if Path(path) == target:
                    fields = list(value)
                    fields[index] += 1
                    return os.stat_result(fields)
                return value
            with patch.object(ac.os, "lstat", side_effect=altered):
                self.assertEqual(self.scan(), [])
        target.chmod(0o777)
        self.assertEqual(self.scan(), [])

    def test_malformed_or_missing_metadata_does_not_map_cache(self):
        app = self.app()
        self.directory("Library/Caches/org.example.app")
        (app / "Contents/Info.plist").write_text("bad")
        self.assertEqual(self.scan(), [])
        (app / "Contents/Info.plist").unlink()
        self.assertEqual(self.scan(), [])

    def test_bundle_identifier_cannot_escape_cache_root(self):
        self.app(bundle="../../Documents")
        self.directory("Documents")
        self.assertEqual(self.scan(), [])

    def test_duplicate_bundles_guard_all_executables_and_paths(self):
        self.app()
        self.app("Other copy", executable="Other")
        self.directory("Library/Caches/org.example.app")
        records = self.scan()
        self.assertEqual(len(records), 1)
        self.assertIn("Other", records[0][1])
        self.assertIn("Example", records[0][2])
        self.assertIn("Other", records[0][2])

    def test_teams_webview_cache_leaves_only(self):
        self.app("Microsoft Teams", "com.microsoft.teams2", "MSTeams")
        base = ("Library/Containers/com.microsoft.teams2/Data/Library/"
                "Application Support/Microsoft/MSTeams/EBWebView")
        wanted = self.directory(base + "/WV2Profile_tfw/GPUCache")
        for relative in ["WV2Profile_tfw/IndexedDB", "WV2Profile_tfl/Service Worker",
                         "WV2Profile_tfl/Session Storage/Cache", "Unknown/GPUCache"]:
            self.directory(base + "/" + relative)
        self.assertEqual([r[3] for r in self.scan()], [str(wanted)])

    def test_failed_root_scan_is_not_successful_empty_inventory(self):
        with patch.object(ac.os, "listdir", side_effect=PermissionError), \
                self.assertRaises(PermissionError):
            self.scan()

    def test_unsafe_home_rejected(self):
        for home in ("/", "relative", str(self.home) + "/../", str(self.home) + "\n"):
            with self.subTest(home=home), self.assertRaises(ac.Unsafe):
                ac.classify(home, [])


if __name__ == "__main__":
    unittest.main()

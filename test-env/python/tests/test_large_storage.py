"""Conservative classification of extra large disposable macOS caches."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[3] / "macos-initial-setup" / "lib"
sys.path.insert(0, str(LIB))
import large_storage


class LargeStorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)

    def scan(self, scope="all", deep_clean=False):
        return large_storage.classify(str(self.home), scope, deep_clean)

    def paths(self, records, status=large_storage.DISPOSABLE):
        return [path for rec_status, _family, path, _reason in records if rec_status == status]

    def test_claude_renderer_cache_is_disposable(self):
        cache = self.home / "Library" / "Application Support" / "Claude" / "Cache"
        cache.mkdir(parents=True)
        (cache / "blob").write_text("x")
        self.assertEqual(self.paths(self.scan("ai")), [str(cache)])

    def test_claude_vm_and_session_state_are_kept(self):
        root = self.home / "Library" / "Application Support" / "Claude"
        vm = root / "vm_bundles" / "claudevm.bundle"
        session = root / "Session Storage"
        nested = root / "vm_bundles" / "Cache"
        vm.mkdir(parents=True)
        session.mkdir(parents=True)
        nested.mkdir(parents=True)
        (vm / "image").write_text("vm")
        (session / "state").write_text("keep")
        (nested / "blob").write_text("inside-vm")
        records = self.scan("ai")
        self.assertEqual(self.paths(records), [])
        self.assertIn(str(root / "vm_bundles"), self.paths(records, large_storage.KEPT))
        self.assertTrue(vm.exists())
        self.assertTrue(session.exists())
        self.assertTrue(nested.exists())

    def test_models_telegram_orbstack_imovie_are_not_targets(self):
        targets = [
            self.home / ".lmstudio" / "models" / "prism-ml",
            self.home / "Library" / "Group Containers" / "6N38VWS5BX.ru.keepcoder.Telegram",
            self.home / "Library" / "Group Containers" / "HUAQ24HBR6.dev.orbstack" / "data",
            self.home / "Movies" / "iMovie Library.imovielibrary",
            self.home / "Movies" / "TV" / "Media.localized",
            self.home / "Library" / "Containers" / "app.locallyai.Locally" / "Data",
            self.home / "Library" / "Application Support" / "JetBrains" / "PyCharm2026.2",
        ]
        for path in targets:
            path.mkdir(parents=True)
            (path / "payload").write_text("keep")
        self.assertEqual(self.scan("all"), [])
        for path in targets:
            self.assertTrue((path / "payload").exists())

    def test_geforce_now_is_kept(self):
        for name in ("GeForceNOW", "GeForce NOW"):
            root = self.home / "Movies" / "NVIDIA" / name
            root.mkdir(parents=True)
            (root / "recording.mp4").write_text("recording")
        records = self.scan("app")
        self.assertEqual(self.paths(records), [])
        self.assertEqual(len(records), 2)

    def test_jetbrains_caches_not_application_support(self):
        cache = self.home / "Library" / "Caches" / "JetBrains" / "PyCharm2026.2"
        config = self.home / "Library" / "Application Support" / "JetBrains" / "PyCharm2026.2"
        cache.mkdir(parents=True)
        config.mkdir(parents=True)
        (cache / "index").write_text("cache")
        (config / "options").write_text("keep")
        records = self.scan("app")
        self.assertEqual(self.paths(records), [])
        self.assertTrue((config / "options").exists())

    def test_chrome_optguide_kept_even_with_deep_clean(self):
        optguide = (
            self.home / "Library" / "Application Support" / "Google" / "Chrome"
            / "OptGuideOnDeviceModel"
        )
        optguide.mkdir(parents=True)
        (optguide / "model").write_text("weights")
        kept = self.scan("app", deep_clean=False)
        self.assertEqual(self.paths(kept), [])
        self.assertEqual(self.paths(kept, large_storage.KEPT), [str(optguide)])
        self.assertEqual(self.paths(self.scan("app", deep_clean=True)), [])

    def test_scope_isolates_families(self):
        claude = self.home / "Library" / "Application Support" / "Claude" / "Cache"
        geforce = self.home / "Movies" / "NVIDIA" / "GeForceNOW"
        claude.mkdir(parents=True)
        geforce.mkdir(parents=True)
        self.assertEqual(self.paths(self.scan("ai")), [str(claude)])
        self.assertEqual(self.paths(self.scan("app")), [])

    def test_symlinked_root_is_not_disposable(self):
        real = self.home / "elsewhere"
        real.mkdir()
        (real / "blob").write_text("keep")
        parent = self.home / "Library" / "Application Support"
        parent.mkdir(parents=True)
        (parent / "Claude").symlink_to(real)
        self.assertEqual(self.scan("ai"), [])
        self.assertTrue((real / "blob").exists())

    def test_only_direct_renderer_caches_are_disposable(self):
        root = self.home / "Library" / "Application Support" / "Claude"
        kept = ["Service Worker/Database", "Service Worker/CacheStorage",
                "blob_storage", "Session Storage/Cache", "User/Cache",
                "Default/Session Storage/GPUCache"]
        disposable = ["Cache", "Default/GPUCache", "Profile 2/Code Cache"]
        for name in kept + disposable:
            (root / name).mkdir(parents=True)
        self.assertEqual(set(self.paths(self.scan("ai"))),
                         {str(root / name) for name in disposable})

    def test_symlinked_ancestor_is_not_disposable(self):
        real = self.home / "elsewhere"
        (real / "Application Support" / "Claude" / "Cache").mkdir(parents=True)
        (self.home / "Library").symlink_to(real)
        self.assertEqual(self.paths(self.scan("ai")), [])

    def test_control_char_home_rejected(self):
        with self.assertRaises(large_storage.Unsafe):
            large_storage.classify(str(self.home) + "\n", "all", False)

    def test_relative_home_rejected(self):
        with self.assertRaises(large_storage.Unsafe):
            large_storage.classify("relative", "all", False)

    def test_mount_boundary_on_cache_root_is_unsafe(self):
        claude = self.home / "Library" / "Application Support" / "Claude"
        claude.mkdir(parents=True)
        original = large_storage.os.lstat

        def other_device(path):
            value = original(path)
            if Path(path) == claude:
                values = list(value)
                values[2] += 1
                return os.stat_result(values)
            return value

        with patch.object(large_storage.os, "lstat", side_effect=other_device), \
                self.assertRaises(large_storage.Unsafe):
            self.scan("ai")


if __name__ == "__main__":
    unittest.main()

"""Conservative npx cache classification; all fixtures are disposable."""

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[3] / "macos-initial-setup" / "lib"
sys.path.insert(0, str(LIB))
import npx_cache


class NpxCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # realpath, because safe_root walks the ancestry with lstat and refuses
        # a symlinked component - the guard that stops a redirected ancestor
        # aiming the sweep elsewhere. On macOS tempfile hands back a path under
        # /var/folders and /var is a symlink to /private/var, so every test here
        # raised Unsafe("cache ancestry is not a real directory") and the fault
        # was the fixture's, not the code's. Linux has a real /tmp, which is why
        # CI stayed green while the suite could not run on a Mac at all.
        self.home = Path(os.path.realpath(self.tmp.name))
        self.root = self.home / ".npm" / "_npx"
        self.entry = self.root / "0123456789abcdef"
        (self.entry / "node_modules").mkdir(parents=True)
        (self.entry / "package.json").write_text('{"dependencies":{"tool":"1.0"}}')
        self.now = time.time()
        self.age()

    def age(self):
        paths = [self.root]
        for base, dirs, files in os.walk(self.root):
            paths.extend(Path(base) / name for name in dirs + files)
        for path in paths:
            os.utime(path, (self.now - 9 * 86400,) * 2, follow_symlinks=False)

    def scan(self):
        return npx_cache.classify(str(self.home), {}, self.now)

    def test_custom_retention_and_exact_boundary(self):
        self.assertEqual(npx_cache.classify(str(self.home), {}, self.now, 10), [])
        self.assertEqual(npx_cache.classify(str(self.home), {}, self.now, 9),
                         [str(self.entry)])

    def test_invalid_retention_is_rejected(self):
        for days in (0, -1, 36501, "7", True):
            with self.subTest(days=days), self.assertRaises(ValueError):
                npx_cache.classify(str(self.home), {}, self.now, days)

    def test_writable_ancestry_is_rejected(self):
        for directory in (self.home, self.root.parent, self.root):
            original = directory.stat().st_mode
            try:
                directory.chmod(0o777)
                with self.subTest(directory=directory), self.assertRaises(npx_cache.Unsafe):
                    self.scan()
            finally:
                directory.chmod(original)

    def test_writable_contents_are_preserved(self):
        (self.entry / "package.json").chmod(0o666)
        self.assertEqual(self.scan(), [])

    def test_foreign_owner_is_preserved(self):
        with patch.object(npx_cache.os, "geteuid", return_value=os.geteuid() + 1), \
                self.assertRaises(npx_cache.Unsafe):
            self.scan()

    def test_selected_entry_revalidation_refuses_new_node_process(self):
        with patch.dict(os.environ, {"HOME": str(self.home)}, clear=True), \
                patch.object(npx_cache, "probe_processes", side_effect=[True, False]):
            self.assertEqual(npx_cache.main(["--check-entry", str(self.entry)]), 4)
        self.assertTrue(self.entry.exists())

    def test_selected_entry_revalidation_refuses_recent_change(self):
        (self.entry / "package.json").touch()
        with patch.dict(os.environ, {"HOME": str(self.home)}, clear=True), \
                patch.object(npx_cache, "probe_processes", return_value=True):
            self.assertEqual(npx_cache.main(["--check-entry", str(self.entry)]), 1)
        self.assertTrue(self.entry.exists())

    def test_missing_root_rejects_final_check_but_allows_empty_discovery(self):
        self.root.rename(self.root.with_name("moved"))
        with patch.dict(os.environ, {"HOME": str(self.home)}, clear=True), \
                patch.object(npx_cache, "probe_processes") as probe:
            self.assertEqual(npx_cache.main(["--check-entry", str(self.entry)]), 1)
            self.assertEqual(npx_cache.main([]), 0)
            probe.assert_not_called()

    @unittest.skipUnless(sys.platform == "darwin", "native macOS process contract")
    def test_native_process_listing_is_understood(self):
        self.assertIsInstance(npx_cache.probe_processes(), bool)

    def test_old_cache_is_eligible(self):
        self.assertEqual(self.scan(), [str(self.entry)])

    def test_recent_child_preserves_entire_entry(self):
        (self.entry / "node_modules" / "recent").write_text("keep")
        self.assertEqual(self.scan(), [])

    def test_preview_access_does_not_change_modification_retention(self):
        os.utime(self.entry, (self.now, self.now - 9 * 86400))
        self.assertEqual(self.scan(), [str(self.entry)])
        self.assertEqual(self.scan(), [str(self.entry)])

    def test_noncache_and_credentials_survive(self):
        self.entry.rename(self.root / "project")
        (self.root / "credentials").write_text("secret")
        self.assertEqual(self.scan(), [])
        self.assertTrue((self.root / "credentials").exists())

    def test_bad_manifest_is_preserved(self):
        (self.entry / "package.json").write_text("{}")
        self.age()
        self.assertEqual(self.scan(), [])

    def test_internal_symlink_allowed_external_preserved(self):
        (self.entry / "link").symlink_to("package.json")
        self.age()
        os.utime(self.entry / "link", (self.now - 9 * 86400,) * 2, follow_symlinks=False)
        self.assertEqual(self.scan(), [str(self.entry)])
        (self.entry / "link").unlink()
        (self.entry / "link").symlink_to(self.home)
        self.age()
        self.assertEqual(self.scan(), [])

    def test_symlink_root_rejected(self):
        self.root.rename(self.home / "other")
        self.root.symlink_to(self.home / "other")
        with self.assertRaises(npx_cache.Unsafe):
            self.scan()

    def test_config_overrides_rejected(self):
        for env in ({"npm_config_cache": "relative"}, {"NPM_CONFIG_CACHE": "/"},
                    {"NPM_CONFIG_USERCONFIG": "/missing"}):
            with self.subTest(env=env), self.assertRaises(npx_cache.Unsafe):
                npx_cache.classify(str(self.home), env, self.now)
        (self.home / ".npmrc").write_text("cache=elsewhere")
        with self.assertRaises(npx_cache.Unsafe):
            self.scan()

    def test_control_char_home_rejected(self):
        with self.assertRaises(npx_cache.Unsafe):
            npx_cache.classify(str(self.home) + "\n", {}, self.now)

    def test_process_probe_requires_valid_self_row(self):
        for output in ("", "   ", "PID COMMAND\n", "Fehler\n", "1 /sbin/init\n",
                       "12 python\nbroken", "0 python\n"):
            with self.subTest(output=output), self.assertRaises(npx_cache.Unsafe):
                npx_cache.processes_idle(output, 12)
        self.assertTrue(npx_cache.processes_idle("1 /sbin/init\n12 /usr/bin/python3\n", 12))

    def test_active_node_npm_npx_preserved(self):
        for name in ("node", "/opt/homebrew/bin/node", "npm exec foo", "npx", "nodejs"):
            with self.subTest(name=name):
                self.assertFalse(npx_cache.processes_idle("12 python3\n15 " + name, 12))

    def test_missing_failed_silent_process_probe_preserves(self):
        for failure in (FileNotFoundError(), PermissionError()):
            with patch.object(npx_cache.subprocess, "run", side_effect=failure), \
                    self.assertRaises(npx_cache.Unsafe):
                npx_cache.probe_processes()
        for rc, out in ((1, ""), (0, ""), (0, "localized output")):
            result = npx_cache.subprocess.CompletedProcess([], rc, out, "")
            with patch.object(npx_cache.subprocess, "run", return_value=result), \
                    self.assertRaises(npx_cache.Unsafe):
                npx_cache.probe_processes()

    def test_mount_boundary_preserved(self):
        original = npx_cache.os.lstat

        def other_device(path):
            value = original(path)
            if str(path).endswith("node_modules"):
                values = list(value)
                values[2] += 1
                return os.stat_result(values)
            return value

        with patch.object(npx_cache.os, "lstat", side_effect=other_device):
            self.assertEqual(self.scan(), [])


if __name__ == "__main__":
    unittest.main()

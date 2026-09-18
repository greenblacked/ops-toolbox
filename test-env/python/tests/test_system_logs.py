"""Rotated system-log safety contracts, using disposable Docker fixtures."""

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[3] / "macos-initial-setup" / "lib"
sys.path.insert(0, str(LIB))
import system_logs


@unittest.skipUnless(os.geteuid() == 0, "secure root-owned fixtures require Docker root")
class SystemLogsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "logs"
        self.root.mkdir()
        self.now = time.time()
        self.old = self.make("system.log.0.gz")

    def make(self, name, days=40):
        path = self.root / name
        path.write_bytes(b"compressed fixture")
        os.utime(path, (self.now - days * 86400,) * 2)
        return path

    def clean(self, apply=False, probe=None):
        return system_logs.clean(str(self.root), apply, self.now, probe or (lambda _: set()))

    def test_preview_preserves_files_and_reports_allocated_size(self):
        before = self.old.stat()
        result = self.clean()
        self.assertTrue(self.old.exists())
        self.assertEqual(result["eligible"], 1)
        self.assertEqual(result["eligible_bytes"], before.st_blocks * 512)
        self.assertEqual(result["freed_bytes"], 0)
        self.assertEqual(result["errors"], [])

    def test_apply_only_removes_old_allowlisted_top_level_files(self):
        keeps = [self.make(n) for n in ("system.log", "system.log.0", "auth.log.0.gz",
                 "install.log.gz", "wifi.log.1.zip", "database", "system.log.1.gz.tmp")]
        keeps.append(self.make("install.log.1.gz", days=3))
        (self.root / "nested").mkdir()
        (self.root / "nested" / "system.log.1.gz").write_bytes(b"keep")
        result = self.clean(apply=True)
        self.assertFalse(self.old.exists())
        self.assertEqual(result["removed"], 1)
        self.assertGreater(result["freed_bytes"], 0)
        self.assertTrue(all(p.exists() for p in keeps))
        self.assertTrue((self.root / "nested" / "system.log.1.gz").exists())

    def test_open_files_preserved(self):
        result = self.clean(apply=True, probe=lambda _: {str(self.old)})
        self.assertTrue(self.old.exists())
        self.assertEqual(result["removed"], 0)

    def test_failed_unknown_and_missing_probe_preserves_everything(self):
        for exc in (system_logs.Unsafe("silent"), FileNotFoundError(), PermissionError()):
            with patch.object(system_logs, "open_files", side_effect=exc):
                result = system_logs.clean(str(self.root), True, self.now)
            self.assertTrue(self.old.exists())
            self.assertTrue(result["errors"])

    def test_symlinks_hardlinks_wrong_owner_and_recent_files_preserved(self):
        self.old.unlink()
        outside = Path(self.tmp.name) / "outside"
        outside.write_text("keep")
        self.old.symlink_to(outside)
        self.assertEqual(self.clean(apply=True)["removed"], 0)
        self.old.unlink()
        self.old = self.make("system.log.0.gz")
        os.link(self.old, self.root / "keep")
        self.assertEqual(self.clean(apply=True)["removed"], 0)
        (self.root / "keep").unlink()
        os.chown(self.old, 123, 123)
        self.assertEqual(self.clean(apply=True)["removed"], 0)
        self.assertTrue(outside.exists())

    def test_insecure_or_symlink_root_refused(self):
        self.root.chmod(0o777)
        self.assertTrue(self.clean(apply=True)["errors"])
        self.root.chmod(0o755)
        relocated = self.root.with_name("moved")
        self.root.rename(relocated)
        self.root.symlink_to(relocated)
        self.assertTrue(self.clean(apply=True)["errors"])
        self.assertTrue((relocated / self.old.name).exists())

    def test_changed_file_preserved(self):
        def change(_):
            self.old.write_text("recent replacement")
            return set()
        self.assertEqual(self.clean(apply=True, probe=change)["removed"], 0)
        self.assertTrue(self.old.exists())

    def test_replaced_root_preserved(self):
        def change(_):
            self.root.rename(self.root.with_name("moved"))
            self.root.mkdir()
            return set()
        result = self.clean(apply=True, probe=change)
        self.assertTrue(result["errors"])
        self.assertTrue((self.root.with_name("moved") / self.old.name).exists())

    def test_partial_delete_only_accounts_successful_unlinks(self):
        removed = self.make("install.log.1.gz")
        expected = removed.stat().st_blocks * 512
        unlink = system_logs.os.unlink

        def deny_one(name, **kwargs):
            if name == self.old.name:
                raise PermissionError("fixture denial")
            return unlink(name, **kwargs)

        with patch.object(system_logs.os, "unlink", side_effect=deny_one):
            result = self.clean(apply=True)
        self.assertEqual(result["removed"], 1)
        self.assertEqual(result["freed_bytes"], expected)
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())
        self.assertFalse(removed.exists())

    def test_replaced_inode_preserved_even_with_old_timestamp(self):
        def replace(_):
            self.old.rename(self.root / "saved")
            self.make(self.old.name)
            return set()
        result = self.clean(apply=True, probe=replace)
        self.assertEqual(result["removed"], 0)
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())

    def test_mount_device_file_is_preserved(self):
        original_stat = system_logs.os.stat

        def different_device(path, **kwargs):
            metadata = original_stat(path, **kwargs)
            if path == self.old.name:
                values = list(metadata)
                values[2] += 1
                return os.stat_result(values)
            return metadata

        with patch.object(system_logs.os, "stat", side_effect=different_device):
            result = self.clean(apply=True)
        self.assertEqual(result["removed"], 0)
        self.assertTrue(self.old.exists())

    def test_symlink_ancestor_refused(self):
        nested = self.root / "nested"
        nested.mkdir()
        sentinel = nested / "system.log.0.gz"
        sentinel.write_bytes(b"eligible sentinel")
        os.utime(sentinel, (self.now - 40 * 86400,) * 2)
        self.assertEqual(system_logs.clean(str(nested), False, self.now)["eligible"], 1)
        link = Path(self.tmp.name) / "link"
        link.symlink_to(self.root)
        result = system_logs.clean(str(link / "nested"), True, self.now, lambda _: set())
        self.assertTrue(result["errors"])
        self.assertTrue(sentinel.exists())
        self.assertTrue(self.old.exists())

    def test_nonroot_apply_refused(self):
        with patch.object(system_logs.os, "geteuid", return_value=501):
            result = self.clean(apply=True)
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())


class OpenFileProbeTests(unittest.TestCase):
    def test_listing_must_include_own_open_directory(self):
        root = "/private/var/log"
        good = "p12\nn/private/var/log\np14\nn/private/var/log/system.log.0.gz\n"
        self.assertEqual(system_logs.parse_open_files(good, root, 12),
                         {root, root + "/system.log.0.gz"})
        for output in ("", "localized error", "p14\nn/private/var/log\n", "p12\nbroken\n"):
            with self.subTest(output=output), self.assertRaises(system_logs.Unsafe):
                system_logs.parse_open_files(output, root, 12)

    def test_missing_failed_silent_lsof_is_unknown(self):
        for failure in (FileNotFoundError(), PermissionError()):
            with patch.object(system_logs.subprocess, "run", side_effect=failure), \
                    self.assertRaises(system_logs.Unsafe):
                system_logs.open_files("/private/var/log")
        for rc, out in ((1, ""), (0, ""), (0, "permission denied")):
            result = system_logs.subprocess.CompletedProcess([], rc, out, "")
            with patch.object(system_logs.subprocess, "run", return_value=result), \
                    self.assertRaises(system_logs.Unsafe):
                system_logs.open_files("/private/var/log")


if __name__ == "__main__":
    unittest.main()

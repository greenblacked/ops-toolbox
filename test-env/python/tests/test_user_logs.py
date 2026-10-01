"""User-log deletion contracts; all paths are temporary fixtures."""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[3] / "macos-initial-setup" / "lib"
sys.path.insert(0, str(LIB))
import user_logs


class UserLogsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.root = self.home / "Library/Logs"
        self.root.mkdir(parents=True)
        self.now = time.time()
        self.old = self.make("old.log", 40)

    def make(self, name, days):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("log fixture")
        os.utime(path, (self.now - days * 86400,) * 2)
        return path

    def clean(self, apply=True, probe=None):
        return user_logs.clean(str(self.home), apply, self.now,
                               probe or (lambda _: set()))

    def test_verbose_candidate_explains_age_size_and_recoverability(self):
        result = user_logs.clean(str(self.home), False, self.now, verbose=True)
        item = result["candidates"][0]
        self.assertEqual(item["path"], str(self.old))
        self.assertEqual(item["age_days"], 40)
        self.assertEqual(item["bytes"], self.old.stat().st_blocks * 512)
        self.assertIn("cannot be recreated", item["reason"])

    def test_checkpoint_survives_interruption_after_unlink(self):
        checkpoints = []
        def progress(result):
            checkpoints.append(dict(result))
            raise KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            user_logs.clean(str(self.home), True, self.now, lambda _: set(), progress=progress)
        self.assertFalse(self.old.exists())
        self.assertEqual(checkpoints[-1]["removed"], 1)
        self.assertEqual(checkpoints[-1]["last_removed"]["path"], str(self.old))
        self.assertGreater(checkpoints[-1]["freed_bytes"], 0)

    def test_writable_ancestry_preserves_logs(self):
        for directory in (self.home, self.root.parent, self.root):
            original = directory.stat().st_mode
            try:
                directory.chmod(0o777)
                result = self.clean()
                self.assertTrue(result["errors"])
                self.assertTrue(self.old.exists())
            finally:
                directory.chmod(original)

    def test_symlink_ancestry_preserves_logs(self):
        library = self.root.parent
        library.rename(self.home / "real-library")
        library.symlink_to(self.home / "real-library")
        result = self.clean()
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())

    def test_foreign_ancestry_owner_preserves_logs(self):
        with patch.object(user_logs.os, "geteuid", return_value=os.geteuid() + 1):
            result = self.clean()
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())

    def test_directory_mount_boundary_preserves_logs(self):
        original = user_logs.os.fstat
        def different_device(fd):
            meta = original(fd)
            if meta.st_ino == self.root.stat().st_ino:
                values = list(meta)
                values[2] += 1
                return os.stat_result(values)
            return meta
        with patch.object(user_logs.os, "fstat", side_effect=different_device):
            result = self.clean()
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())

    def test_custom_retention_keeps_recent_files_and_removes_boundary(self):
        boundary = self.make("boundary.log", 61)
        result = user_logs.clean(str(self.home), True, self.now,
                                 lambda _: set(), keep_days=60)
        self.assertTrue(self.old.exists())
        self.assertFalse(boundary.exists())
        self.assertEqual(result["removed"], 1)

    def test_invalid_retention_is_rejected(self):
        for days in (0, -1, 36501, "30", True):
            with self.subTest(days=days), self.assertRaises(ValueError):
                user_logs.clean(str(self.home), keep_days=days)
        self.assertTrue(self.old.exists())

    @unittest.skipUnless(shutil.which("lsof"), "real lsof required")
    def test_real_open_file_probe_preserves_open_log_and_removes_idle_log(self):
        idle = self.make("idle.log", 40)
        with self.old.open("rb"):
            result = user_logs.clean(str(self.home), True, self.now)
        self.assertEqual(result["errors"], [])
        self.assertTrue(self.old.exists())
        self.assertFalse(idle.exists())
        self.assertEqual(result["kept_open"], 1)
        self.assertEqual(result["removed"], 1)

    def test_preview_preserves_and_does_not_probe(self):
        with patch.object(user_logs, "open_files", side_effect=AssertionError):
            result = user_logs.clean(str(self.home), False, self.now)
        self.assertEqual(result["eligible"], 1)
        self.assertEqual(result["removed"], 0)
        self.assertTrue(self.old.exists())

    def test_retention_and_protected_subtrees(self):
        recent = self.make("recent.log", 30.9)
        boundary = self.make("boundary.log", 31)
        crash = self.make("DiagnosticReports/old.ips", 90)
        history = self.make("stay_fresh/history.tsv", 90)
        expected = self.old.stat().st_blocks + boundary.stat().st_blocks
        result = self.clean()
        self.assertEqual(result["removed"], 2)
        self.assertEqual(result["freed_bytes"], expected * 512)
        self.assertFalse(boundary.exists())
        for path in (recent, crash, history):
            self.assertTrue(path.exists())

    def test_open_file_is_kept(self):
        result = self.clean(probe=lambda _: {str(self.old)})
        self.assertTrue(self.old.exists())
        self.assertEqual(result["kept_open"], 1)
        self.assertEqual(result["freed_bytes"], 0)

    def test_lsof_escaped_names_never_delete_open_logs(self):
        # lsof writes a literal backslash-n for a newline in a filename. A
        # string comparison against the original name would miss the open fd.
        unsafe = [self.make("open\nlog", 40), self.make("open\\nlog", 40),
                  self.make("caf\u00e9.log", 40)]
        idle = self.make("idle.log", 40)
        output = "p%s\nf4\nn%s\nf5\nn%s\n" % (
            os.getpid(), self.root, str(unsafe[0]).replace("\n", "\\n"))
        with unsafe[0].open("rb"), patch.object(user_logs.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, output, "")):
            result = user_logs.clean(str(self.home), True, self.now)
        self.assertEqual(result["errors"], [])
        self.assertFalse(self.old.exists())
        self.assertFalse(idle.exists())
        for path in unsafe:
            self.assertTrue(path.exists(), str(path))

    def test_refreshed_file_is_kept(self):
        def probe(_):
            self.old.write_text("new log contents")
            return set()
        result = self.clean(probe=probe)
        self.assertEqual(result["kept_changed"], 1)
        self.assertEqual(self.old.read_text(), "new log contents")

    def test_replaced_file_is_kept_even_with_old_timestamp(self):
        def probe(_):
            self.old.rename(self.root / "original")
            self.make("old.log", 40)
            return set()
        result = self.clean(probe=probe)
        self.assertTrue(self.old.exists())
        self.assertEqual(result["kept_changed"], 1)

    def test_directory_replacement_preserves_both_trees(self):
        def probe(_):
            self.root.rename(self.root.with_name("original"))
            self.root.mkdir()
            self.make("old.log", 40)
            return set()
        result = self.clean(probe=probe)
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())
        self.assertTrue((self.root.with_name("original") / "old.log").exists())

    def test_links_are_kept(self):
        (self.root / "alias.log").symlink_to(self.old)
        os.link(self.old, self.root / "hard.log")
        external = self.home / "outside"
        external.mkdir()
        (external / "keep").write_text("keep")
        (self.root / "redirect").symlink_to(external)
        result = self.clean()
        self.assertEqual(result["removed"], 0)
        self.assertTrue(self.old.exists())
        self.assertTrue((external / "keep").exists())

    def test_missing_open_file_probe_preserves_data(self):
        with patch.object(user_logs, "open_files", side_effect=user_logs.Unsafe("unavailable")):
            result = user_logs.clean(str(self.home), True, self.now)
        self.assertTrue(result["errors"])
        self.assertTrue(self.old.exists())

    def test_darwin_lsof_descriptor_fields(self):
        output = "p%s\nf4\nn%s\nf5\nn%s\n" % (os.getpid(), self.root, self.old)
        with patch.object(user_logs.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, output, "")):
            self.assertIn(str(self.old), user_logs.open_files(str(self.root)))
        for invalid in ("fBAD", "f-1", "f"):
            with patch.object(user_logs.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 0,
                        output.replace("f4", invalid), "")), self.assertRaises(user_logs.Unsafe):
                user_logs.open_files(str(self.root))

    def test_lsof_requires_own_directory_witness(self):
        for output in ("", "p1\nn/something\n", "malformed\n"):
            with self.subTest(output=output), patch.object(user_logs.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 0, output, "")), \
                    self.assertRaises(user_logs.Unsafe):
                user_logs.open_files(str(self.root))
        output = "p%s\nn%s\np1\nn%s\n" % (os.getpid(), self.root, self.old)
        with patch.object(user_logs.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, output, "")):
            self.assertIn(str(self.old), user_logs.open_files(str(self.root)))

    def test_lsof_errors_are_rejected_even_with_directory_witness(self):
        output = "p%s\nn%s\n" % (os.getpid(), self.root)
        for rc, stderr in ((2, ""), (1, "permission denied")):
            with self.subTest(rc=rc, stderr=stderr), patch.object(user_logs.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], rc, output, stderr)), \
                    self.assertRaises(user_logs.Unsafe):
                user_logs.open_files(str(self.root))

    def test_probe_failure_in_one_directory_preserves_other_cleanup(self):
        nested = self.make("other/old.log", 40)
        def probe(path):
            if path == str(self.root):
                raise user_logs.Unsafe("cannot inspect")
            return set()
        result = self.clean(probe=probe)
        self.assertTrue(self.old.exists())
        self.assertFalse(nested.exists())
        self.assertTrue(result["errors"])


if __name__ == "__main__":
    unittest.main()

"""Explicit old-version inventory; selected data only, fail closed."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "macos-initial-setup/lib"))
import jetbrains_versions as jv


class JetBrainsVersionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="jetbrains home ")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)

    def make(self, name, base="Application Support"):
        path = self.home / "Library" / base / "JetBrains" / name
        path.mkdir(parents=True, exist_ok=True)
        (path / "state").write_text("keep unless selected")
        return path

    def scan(self, *names):
        return jv.classify(str(self.home), names)

    def test_exact_selected_roots_and_deduplication(self):
        expected = [str(self.make("PyCharm2025.2", base)) for base in jv.ROOTS]
        self.make("PyCharm2026.1")
        self.make("PyCharm2026.2")
        self.assertEqual(self.scan("PyCharm2025.2", "PyCharm2025.2"), sorted(expected))

    def test_union_inventory_and_numeric_order(self):
        old = self.make("PyCharm2025.2", "Caches")
        self.make("PyCharm2025.10", "Logs")
        self.assertEqual(self.scan("PyCharm2025.2"), [str(old)])

    def test_newest_only_and_different_product_do_not_qualify(self):
        self.make("PyCharm2025.2")
        self.make("PyCharmCE2026.2")
        with self.assertRaises(jv.Unsafe):
            self.scan("PyCharm2025.2")

    def test_missing_selection_rejects_entire_batch(self):
        self.make("PyCharm2025.2")
        self.make("PyCharm2026.2")
        with self.assertRaises(jv.Unsafe):
            self.scan("PyCharm2025.2", "PyCharm2024.1")

    def test_reject_path_variants(self):
        for name in ("", "../PyCharm2025.2", "/PyCharm2025.2", "PyCharm2025.2/",
                     "PyCharm2025.2\n", "PyCharm2025.2-backup", "Unknown2025.2"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.scan(name)

    def test_backup_does_not_prove_newer_version(self):
        self.make("PyCharm2025.2")
        self.make("PyCharm2026.2-backup")
        with self.assertRaises(jv.Unsafe):
            self.scan("PyCharm2025.2")
        self.make("PyCharm2026.1")
        self.assertEqual(len(self.scan("PyCharm2025.2")), 1)

    def test_unrecognized_version_suffix_preserves_family(self):
        self.make("PyCharm2025.2")
        self.make("PyCharm2026.2")
        self.make("PyCharm2027.1-EAP")
        with self.assertRaises(jv.Unsafe):
            self.scan("PyCharm2025.2")

    def test_symlinked_version_cannot_prove_newer(self):
        old = self.make("PyCharm2025.2")
        (old.parent / "PyCharm2026.2").symlink_to(old, target_is_directory=True)
        with self.assertRaises(jv.Unsafe):
            self.scan("PyCharm2025.2")

    def test_symlinked_ancestor_refused(self):
        self.make("PyCharm2025.2")
        self.make("PyCharm2026.2")
        library = self.home / "Library"
        library.rename(self.home / "elsewhere")
        library.symlink_to(self.home / "elsewhere", target_is_directory=True)
        with self.assertRaises(jv.Unsafe):
            self.scan("PyCharm2025.2")

    def test_foreign_owner_or_device_refused(self):
        old = self.make("PyCharm2025.2")
        self.make("PyCharm2026.2")
        original = os.lstat
        for index in (2, 4):
            def changed(path, index=index):
                value = original(path)
                if Path(path) == old:
                    fields = list(value)
                    fields[index] += 1
                    return os.stat_result(fields)
                return value
            with self.subTest(index=index), patch.object(jv.os, "lstat", side_effect=changed), \
                    self.assertRaises(jv.Unsafe):
                self.scan("PyCharm2025.2")

    def test_failed_inventory_preserves_all(self):
        self.make("PyCharm2025.2")
        with patch.object(jv.os, "listdir", side_effect=PermissionError), \
                self.assertRaises(PermissionError):
            self.scan("PyCharm2025.2")

    def test_writable_ancestor_refused(self):
        self.make("PyCharm2025.2")
        self.make("PyCharm2026.2")
        (self.home / "Library").chmod(0o777)
        with self.assertRaises(jv.Unsafe):
            self.scan("PyCharm2025.2")


if __name__ == "__main__":
    unittest.main()

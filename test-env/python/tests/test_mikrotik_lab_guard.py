"""Regression tests: the MikroTik harness must fail before any destructive API call."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PATH = ROOT / "mikrotik" / "tests" / "lab_guard.py"
SPEC = importlib.util.spec_from_file_location("lab_guard", PATH)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)

ENV = {
    "OPSTOOLBOX_CHR_LAB": "isolated-qemu-only",
    "ROUTEROS_HOST": "chr",
    "ROUTEROS_PORT": "8728",
    "EXPECT_ROUTEROS_VERSION": "7.25",
}


class FakeResource:
    def __init__(self, rows):
        self.rows = rows

    def get(self):
        return list(self.rows)


class FakeAPI:
    def __init__(self, *, board="CHR", arch="x86_64", version="7.25 (stable)",
                 mac=guard.LAB_MAC, scripts=(), schedulers=(), files=()):
        self.reads = []
        self.writes = []
        self.tables = {
            "/system/resource": [{"board-name": board, "architecture-name": arch,
                                  "version": version}],
            "/interface/ethernet": [{"name": "ether1", "mac-address": mac}],
            "/system/script": list(scripts),
            "/system/scheduler": list(schedulers),
            "/file": list(files),
        }

    def get_binary_resource(self, path):
        self.reads.append(path)
        return FakeResource(self.tables[path])


class LabGuardTests(unittest.TestCase):
    def test_fresh_disposable_chr_is_accepted(self):
        api = FakeAPI()
        guard.assert_disposable_chr(api, ENV)
        self.assertEqual(api.writes, [])
        self.assertIn("/interface/ethernet", api.reads)

    def test_missing_lab_flag_stops_before_connecting(self):
        with self.assertRaises(guard.UnsafeLabTarget):
            guard.validate_lab_environment({**ENV, "OPSTOOLBOX_CHR_LAB": ""})

    def test_remote_router_endpoint_refused(self):
        for host in ("192.168.88.1", "router.lan", "127.0.0.1"):
            with self.subTest(host=host), self.assertRaises(guard.UnsafeLabTarget):
                guard.validate_lab_environment({**ENV, "ROUTEROS_HOST": host})

    def test_other_port_refused(self):
        with self.assertRaises(guard.UnsafeLabTarget):
            guard.validate_lab_environment({**ENV, "ROUTEROS_PORT": "8729"})

    def test_unexpected_platform_mac_or_version_refused_without_modifications(self):
        cases = [
            {"board": "hAP ax2", "arch": "arm64"},
            {"board": "CHR", "arch": "arm64"},
            {"mac": "52:54:00:00:00:00"},
            {"version": "7.24.5 (stable)"},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                api = FakeAPI(**changes)
                with self.assertRaises(guard.UnsafeLabTarget):
                    guard.assert_disposable_chr(api, ENV)
                self.assertEqual(api.writes, [])

    def test_existing_production_named_script_is_not_overwritten(self):
        api = FakeAPI(scripts=[{"name": "tg_send"}])
        with self.assertRaises(guard.UnsafeLabTarget):
            guard.assert_disposable_chr(api, ENV)
        self.assertEqual(api.writes, [])

    def test_any_existing_script_or_test_backup_refuses_cleanup(self):
        cases = [
            {"scripts": [{"name": "unrelated-production-script"}]},
            {"files": [{"name": "backup-previous.backup"}]},
            {"schedulers": [{"name": "pu_ut_leftover"}]},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                api = FakeAPI(**changes)
                with self.assertRaises(guard.UnsafeLabTarget):
                    guard.assert_disposable_chr(api, ENV)
                self.assertEqual(api.writes, [])


if __name__ == "__main__":
    unittest.main()

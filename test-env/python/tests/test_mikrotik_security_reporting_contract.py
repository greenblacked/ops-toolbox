from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
MIKROTIK = ROOT / "mikrotik"


class MikroTikSecurityReportingContracts(unittest.TestCase):
    def read(self, name: str) -> str:
        return (MIKROTIK / name).read_text(encoding="utf-8")

    def test_security_scan_does_not_guess_home_subnet(self) -> None:
        source = self.read("security_check.lua")
        self.assertNotIn("192.168.88.0/24", source)
        self.assertNotIn("allowed-interface-list=LAN", source)

    def test_local_dns_is_not_called_an_open_resolver(self) -> None:
        source = self.read("security_check.lua")
        self.assertIn("Local DNS resolver enabled", source)
        self.assertIn("reachability was not tested", source)

    def test_disabled_or_invalid_drops_do_not_count_as_protection(self) -> None:
        source = self.read("security_check.lua")
        self.assertIn('(($row->"disabled") != true)', source)
        self.assertIn('(($row->"invalid") != true)', source)
        self.assertIn("Rule order and actual reachability still require review", source)

    def test_failed_delivery_does_not_advance_delivered_fingerprint(self) -> None:
        source = self.read("security_check.lua")
        send = source.index("$Send MessageText=")
        delivered = source.index(":set SecDeliveredFp")
        self.assertGreater(delivered, send)
        self.assertIn("SecSendError", source)

    def test_update_available_is_not_automatically_required(self) -> None:
        source = self.read("backup_update_check.lua")
        self.assertIn("available for review", source)
        self.assertIn("availability alone does not prove security urgency", source)
        self.assertNotIn("RouterOS update is required.", source)

    def test_reviewed_update_reason_is_bound_to_exact_pair(self) -> None:
        source = self.read("backup_update_check.lua")
        self.assertIn("$RouterUpdateInstalled = $InstalledVersion", source)
        self.assertIn("$RouterUpdateTarget = $LatestVersion", source)
        self.assertIn("RouterUpdateReason", source)
        self.assertIn("RouterUpdatePriority", source)

    def test_telegram_delivery_is_acknowledged(self) -> None:
        source = self.read("tg_send.lua")
        self.assertIn("check-certificate=yes", source)
        self.assertIn('($reply->"ok") != true', source)
        self.assertIn(':if (!$sent) do={', source)
        self.assertIn(':error "tg_send: delivery failed after 3 attempts"', source)


if __name__ == "__main__":
    unittest.main()

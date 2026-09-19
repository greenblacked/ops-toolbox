from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
MIKROTIK = ROOT / "mikrotik"


class MikroTikSecurityReportingContracts(unittest.TestCase):
    def read(self, name: str) -> str:
        """The script with this filename, wherever in the package it lives.

        The scripts sit in core/ and features/ by whether the fleet runs them,
        so a flat MIKROTIK / name resolves to nothing. Exactly one match is
        required: zero means the check cannot run, and two would apply the
        assertions to whichever copy sorted first.
        """
        matches = [
            f
            for f in MIKROTIK.rglob(name)
            if f.is_file() and "tests" not in f.relative_to(MIKROTIK).parts
        ]
        self.assertEqual(
            len(matches), 1, f"{name} resolved to {[str(m) for m in matches]}"
        )
        return matches[0].read_text(encoding="utf-8")

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

    def test_the_headline_alarms_and_the_evidence_stays_separate(self) -> None:
        """Urgency is stated once, in the headline; the evidence is its own lines.

        The operator asked for a headline that reads "RouterOS update is
        required." with ALARM under it, because a nightly message nobody acts on
        is a message nobody reads. The evidence-aware half still holds: the
        script does not claim to have checked a vulnerability feed, so the
        Priority line defaults to review and only an operator-reviewed reason
        for the exact observed pair can say otherwise.
        """
        source = self.read("backup_update_check.lua")
        self.assertIn("</b> RouterOS update is required.", source)
        self.assertIn('"\\0AALARM"', source)
        self.assertIn("availability alone does not prove security urgency", source)
        self.assertIn(':local UpdatePriority "review"', source)

    def test_the_chr_suite_asserts_the_headlines_the_script_sends(self) -> None:
        """The integration suite's three headline constants must match the script.

        They are spelled in two files that a 6-minute CHR run apart: rewording
        the script left five of the suite's seven uses quietly matching nothing,
        so gates guarding real assertions were never taken and skips always
        fired. Comparing both here fails in seconds instead.
        """
        script = self.read("backup_update_check.lua")
        suite = (MIKROTIK / "tests" / "test_routeros_scripts.py").read_text(encoding="utf-8")
        found = 0
        for const in ("UPDATE_OFFERED", "UPDATE_NONE", "UPDATE_FAILED"):
            marker = f'{const} = "'
            self.assertIn(marker, suite, f"{const} is gone from the CHR suite")
            headline = suite.split(marker, 1)[1].split('"', 1)[0]
            self.assertIn(
                f"</b> {headline}",
                script,
                f"{const} is {headline!r}, which backup_update_check.lua never sends",
            )
            found += 1
        self.assertEqual(found, 3)
        # And the other way: every headline the script sends is one the suite knows.
        for line in script.splitlines():
            if "</b> RouterOS" in line:
                headline = line.split("</b> ", 1)[1].split('"', 1)[0]
                self.assertIn(
                    f'"{headline}"',
                    suite,
                    f"the script sends {headline!r} and the CHR suite has no constant",
                )

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

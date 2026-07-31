"""Tests for mikrotik/export_config.py.

Only normalisation is covered, and deliberately so: it is the part with a
judgement call in it. Strip too little and every export is a noisy diff; strip
too much and a real configuration change disappears into the filter. Everything
else in that script is ssh and git plumbing that would need a router to mean
anything.
"""

from __future__ import annotations

import os
import sys
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "mikrotik"))

import export_config  # noqa: E402

# Shape of a real RouterOS 7 export.
EXPORT_TEMPLATE = """\
# {date} by RouterOS 7.22
# software id = ABCD-1234
#
# model = RB5009UG+S+
# serial number = HJ80TESTTEST
/interface bridge
add admin-mac=48:A9:8A:00:00:00 auto-mac=no comment=defconf name=bridge
/ip firewall filter
add action=accept chain=input comment="defconf: accept established" \\
    connection-state=established,related
add action=drop chain=input comment="defconf: drop all not coming from LAN" \\
    in-interface-list=!LAN
"""


class NormaliseTestCase(unittest.TestCase):
    def test_two_exports_of_an_unchanged_router_are_identical(self):
        # The whole reason the function exists.
        first = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        second = export_config.normalise(EXPORT_TEMPLATE.format(date="aug/03/2026 09:12:47"))
        self.assertEqual(first, second)

    def test_iso_style_timestamp_is_also_stripped(self):
        a = export_config.normalise(EXPORT_TEMPLATE.format(date="2026-07-29 18:04:11"))
        b = export_config.normalise(EXPORT_TEMPLATE.format(date="2026-08-03 09:12:47"))
        self.assertEqual(a, b)

    def test_configuration_lines_survive(self):
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertIn("/interface bridge", out)
        self.assertIn("/ip firewall filter", out)
        self.assertIn("in-interface-list=!LAN", out)

    def test_a_real_change_still_shows(self):
        base = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        changed_src = EXPORT_TEMPLATE.format(date="jul/30/2026 10:00:00").replace(
            "in-interface-list=!LAN", "in-interface-list=!WAN"
        )
        changed = export_config.normalise(changed_src)
        self.assertNotEqual(base, changed)
        self.assertIn("!WAN", changed)

    def test_comments_that_are_configuration_are_kept(self):
        # comment= is part of a rule, not a header. Dropping it would hide a
        # meaningful edit.
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertIn('comment="defconf: accept established"', out)

    def test_hardware_identity_header_is_stripped(self):
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertNotIn("serial number", out)
        self.assertNotIn("software id", out)

    def test_trailing_blank_lines_collapse(self):
        out = export_config.normalise("/ip address\nadd address=10.0.0.1/24\n\n\n\n")
        self.assertTrue(out.endswith("add address=10.0.0.1/24\n"))
        self.assertFalse(out.endswith("\n\n"))

    def test_trailing_whitespace_does_not_create_a_diff(self):
        a = export_config.normalise("/ip address   \nadd address=10.0.0.1/24\n")
        b = export_config.normalise("/ip address\nadd address=10.0.0.1/24\n")
        self.assertEqual(a, b)

    def test_empty_input_does_not_crash(self):
        self.assertEqual(export_config.normalise(""), "\n")

    def test_output_always_ends_with_one_newline(self):
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertTrue(out.endswith("\n"))
        self.assertFalse(out.endswith("\n\n"))


class ArgumentGuardTestCase(unittest.TestCase):
    def test_sensitive_plus_commit_is_refused(self):
        # Writing router secrets into git history is not something to do by
        # accident, so it fails before it ever contacts the router.
        rc = export_config.main(
            ["--host", "192.0.2.1", "--show-sensitive", "--commit"]
        )
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()

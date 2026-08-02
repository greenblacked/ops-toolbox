"""Tests for git/git_signing_doctor.py.

Only the pure parts are covered: config parsing, gpg colon records, key
classification, expiry, allowed-signers parsing and PATH resolution. Anything
that shells out to gpg or ssh-keygen is left alone — it needs a real keyring,
and mocking it would only assert that the mock was called.

`now` and PATH are passed in as parameters rather than read from the clock and
the environment, which is what makes the expiry and program-lookup cases
testable at all.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "git"))

import git_signing_doctor as doctor  # noqa: E402

NOW = 1_700_000_000  # fixed point so fixtures never rot


def _config(*records):
    """Build `git config --list --show-origin --show-scope -z` output."""
    return "".join("%s\0%s\0%s\n%s\0" % (scope, origin, key, value)
                   for scope, origin, key, value in records)


class ParseGitConfigTestCase(unittest.TestCase):
    def test_parses_scope_origin_key_and_value(self):
        text = _config(("global", "file:/home/u/.gitconfig", "user.email", "u@example.com"))
        entries = doctor.parse_git_config(text)
        self.assertEqual(
            entries["user.email"], [("u@example.com", "file:/home/u/.gitconfig", "global")]
        )

    def test_last_value_wins_and_all_are_kept(self):
        text = _config(
            ("global", "file:/home/u/.gitconfig", "user.email", "global@example.com"),
            ("local", "file:.git/config", "user.email", "local@example.com"),
        )
        entries = doctor.parse_git_config(text)
        self.assertEqual(len(entries["user.email"]), 2)
        self.assertEqual(doctor.effective(entries, "user.email")[0], "local@example.com")
        # Reporting the origin is the point: a repo-local override beating a
        # global one is invisible otherwise.
        self.assertEqual(doctor.effective(entries, "user.email")[2], "local")

    def test_keys_are_case_insensitive(self):
        text = _config(("global", "file:x", "GPG.Format", "ssh"))
        entries = doctor.parse_git_config(text)
        self.assertEqual(doctor.effective(entries, "gpg.format")[0], "ssh")

    def test_valueless_key_does_not_crash(self):
        text = _config(("global", "file:x", "commit.gpgsign", ""))
        self.assertEqual(doctor.parse_git_config(text)["commit.gpgsign"][0][0], "")

    def test_empty_input(self):
        self.assertEqual(doctor.parse_git_config(""), {})

    def test_missing_key_is_none(self):
        self.assertIsNone(doctor.effective({}, "user.signingkey"))


SEC = "sec:%s:255:22:ABCD1234EF567890:1600000000:%s:::::scESC:::+:::23::0:\n"
FPR = "fpr:::::::::1111222233334444555566667777888899990000:\n"


class ParseGpgColonsTestCase(unittest.TestCase):
    def test_reads_fingerprint_and_uids(self):
        text = (SEC % ("u", "") + FPR
                + "uid:u::::1600000000::AAA::Real Name <person@example.com>::::::::::0:\n")
        records = doctor.parse_gpg_colons(text)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["fingerprint"],
                         "1111222233334444555566667777888899990000")
        self.assertEqual(doctor.uid_emails(records[0]), ["person@example.com"])

    def test_multiple_keys(self):
        text = SEC % ("u", "") + FPR + SEC % ("u", "") + FPR
        self.assertEqual(len(doctor.parse_gpg_colons(text)), 2)

    def test_no_secret_keys(self):
        self.assertEqual(doctor.parse_gpg_colons(""), [])

    def test_uid_without_email_yields_nothing(self):
        text = SEC % ("u", "") + "uid:u::::1600000000::AAA::No Email Here::::::::::0:\n"
        self.assertEqual(doctor.uid_emails(doctor.parse_gpg_colons(text)[0]), [])


class ExpiryStateTestCase(unittest.TestCase):
    def test_valid_key_far_from_expiry(self):
        record = {"validity": "u", "expires": str(NOW + 365 * 24 * 3600)}
        self.assertEqual(doctor.expiry_state(record, NOW), "valid")

    def test_expired_by_timestamp(self):
        record = {"validity": "u", "expires": str(NOW - 1)}
        self.assertEqual(doctor.expiry_state(record, NOW), "expired")

    def test_expiring_within_thirty_days(self):
        record = {"validity": "u", "expires": str(NOW + 5 * 24 * 3600)}
        self.assertEqual(doctor.expiry_state(record, NOW), "expiring")

    def test_revoked_beats_a_valid_timestamp(self):
        record = {"validity": "r", "expires": str(NOW + 365 * 24 * 3600)}
        self.assertEqual(doctor.expiry_state(record, NOW), "revoked")

    def test_expired_flag_without_timestamp(self):
        self.assertEqual(doctor.expiry_state({"validity": "e", "expires": ""}, NOW), "expired")

    def test_no_expiry_means_valid(self):
        self.assertEqual(doctor.expiry_state({"validity": "u", "expires": ""}, NOW), "valid")

    def test_unparsable_timestamp_does_not_crash(self):
        self.assertEqual(doctor.expiry_state({"validity": "u", "expires": "soon"}, NOW), "valid")


class ClassifySigningKeyTestCase(unittest.TestCase):
    def test_gpg_keyid_with_openpgp_is_fine(self):
        kind, problem = doctor.classify_signing_key("openpgp", "ABCD1234EF567890")
        self.assertEqual(kind, "gpg-keyid")
        self.assertIsNone(problem)

    def test_prefixed_gpg_keyid(self):
        kind, _ = doctor.classify_signing_key("openpgp", "0xABCD1234")
        self.assertEqual(kind, "gpg-keyid")

    def test_ssh_path_with_ssh_format_is_fine(self):
        kind, problem = doctor.classify_signing_key("ssh", "~/.ssh/id_ed25519.pub")
        self.assertEqual(kind, "ssh-path")
        self.assertIsNone(problem)

    def test_literal_public_key(self):
        kind, problem = doctor.classify_signing_key("ssh", "ssh-ed25519 AAAAC3Nza")
        self.assertEqual(kind, "ssh-literal")
        self.assertIsNone(problem)

    def test_gpg_keyid_with_ssh_format_is_the_classic_mismatch(self):
        kind, problem = doctor.classify_signing_key("ssh", "ABCD1234EF567890")
        self.assertEqual(kind, "gpg-keyid")
        self.assertIsNotNone(problem)
        self.assertIn("ssh", problem)

    def test_ssh_key_with_openpgp_format_is_the_reverse_mismatch(self):
        _, problem = doctor.classify_signing_key("openpgp", "~/.ssh/id_ed25519.pub")
        self.assertIsNotNone(problem)
        self.assertIn("openpgp", problem)

    def test_unset_signingkey_is_flagged_for_both_formats(self):
        for fmt in ("openpgp", "ssh"):
            kind, problem = doctor.classify_signing_key(fmt, "")
            self.assertEqual(kind, "unknown")
            self.assertIsNotNone(problem)

    def test_empty_format_defaults_to_openpgp(self):
        kind, problem = doctor.classify_signing_key("", "ABCD1234EF567890")
        self.assertEqual(kind, "gpg-keyid")
        self.assertIsNone(problem)


class ParseAllowedSignersTestCase(unittest.TestCase):
    def test_simple_entry(self):
        rows = doctor.parse_allowed_signers("me@example.com ssh-ed25519 AAAAC3Nza\n")
        self.assertEqual(rows, [(["me@example.com"], "ssh-ed25519", "AAAAC3Nza")])

    def test_namespace_option_between_principal_and_key(self):
        rows = doctor.parse_allowed_signers(
            'me@example.com namespaces="git" ssh-ed25519 AAAAC3Nza\n'
        )
        self.assertEqual(rows[0][0], ["me@example.com"])
        self.assertEqual(rows[0][1], "ssh-ed25519")

    def test_multiple_principals(self):
        rows = doctor.parse_allowed_signers("a@x.com,b@x.com ssh-rsa AAAA\n")
        self.assertEqual(rows[0][0], ["a@x.com", "b@x.com"])

    def test_comments_and_blank_lines_ignored(self):
        rows = doctor.parse_allowed_signers("# comment\n\nme@x.com ssh-ed25519 AAAA\n")
        self.assertEqual(len(rows), 1)

    def test_malformed_line_skipped(self):
        self.assertEqual(doctor.parse_allowed_signers("nonsense\n"), [])

    def test_principals_are_lowercased_for_comparison(self):
        rows = doctor.parse_allowed_signers("Me@Example.COM ssh-ed25519 AAAA\n")
        self.assertEqual(rows[0][0], ["me@example.com"])


class FindProgramTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.exe = os.path.join(self.tmp.name, "fakegpg")
        with open(self.exe, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n")
        os.chmod(self.exe, 0o755)

    def test_found_on_injected_path(self):
        self.assertEqual(doctor.find_program("fakegpg", self.tmp.name), self.exe)

    def test_absent_from_path(self):
        self.assertIsNone(doctor.find_program("definitely-not-here", self.tmp.name))

    def test_absolute_path_that_exists(self):
        self.assertEqual(doctor.find_program(self.exe, ""), self.exe)

    def test_absolute_path_that_does_not_exist(self):
        self.assertIsNone(doctor.find_program(os.path.join(self.tmp.name, "nope"), ""))

    def test_non_executable_file_is_not_a_program(self):
        plain = os.path.join(self.tmp.name, "plain")
        with open(plain, "w", encoding="utf-8") as handle:
            handle.write("x")
        os.chmod(plain, 0o644)
        self.assertIsNone(doctor.find_program("plain", self.tmp.name))

    def test_empty_name(self):
        self.assertIsNone(doctor.find_program("", self.tmp.name))


if __name__ == "__main__":
    unittest.main()

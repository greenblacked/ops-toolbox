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

import contextlib
import io
import json
import os
import subprocess
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

    def test_ssh_literal_with_openpgp_format_is_the_reverse_mismatch(self):
        kind, problem = doctor.classify_signing_key("openpgp", "ssh-ed25519 AAAAC3Nza")
        self.assertEqual(kind, "ssh-literal")
        self.assertIsNotNone(problem)
        self.assertIn("openpgp", problem)

    def test_email_is_a_gnupg_selector_under_openpgp(self):
        for fmt in ("openpgp", "", None):
            kind, problem = doctor.classify_signing_key(fmt, "me@example.com")
            self.assertEqual(kind, "gpg-selector")
            self.assertIsNone(problem)

    def test_user_id_and_path_like_value_are_selectors_under_openpgp(self):
        for value in ("Jane Doe", "~/keys/work"):
            kind, problem = doctor.classify_signing_key("openpgp", value)
            self.assertEqual(kind, "gpg-selector")
            self.assertIsNone(problem)

    def test_forced_subkey_is_a_gpg_keyid(self):
        kind, problem = doctor.classify_signing_key(
            "openpgp", "0123456789ABCDEF0123456789ABCDEF01234567!")
        self.assertEqual(kind, "gpg-keyid")
        self.assertIsNone(problem)

    def test_key_literal_is_ssh_only_with_ssh_format(self):
        kind, problem = doctor.classify_signing_key("ssh", "key::ssh-ed25519 AAAA")
        self.assertEqual(kind, "ssh-literal")
        self.assertIsNone(problem)
        kind, _ = doctor.classify_signing_key("openpgp", "key::ssh-ed25519 AAAA")
        self.assertEqual(kind, "gpg-selector")

    def test_ssh_format_forced_hex_is_still_a_mismatch(self):
        kind, problem = doctor.classify_signing_key("ssh", "ABCD1234EF567890!")
        self.assertEqual(kind, "gpg-keyid")
        self.assertIsNotNone(problem)

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


class RenderJsonTestCase(unittest.TestCase):
    """--json: the same report as data.

    EVENTS and SECTION are module state the printers write to, so each test
    starts from an empty list and puts both back afterwards.
    """

    def setUp(self):
        self._events = list(doctor.EVENTS)
        self._section = doctor.SECTION
        doctor.EVENTS.clear()
        doctor.SECTION = ""

    def tearDown(self):
        doctor.EVENTS[:] = self._events
        doctor.SECTION = self._section

    def quietly(self, fn, *args):
        with contextlib.redirect_stdout(io.StringIO()):
            fn(*args)

    def test_shape(self):
        data = json.loads(doctor.render_json("x_doctor.py", [("ok", "s", "m")], 0))
        self.assertEqual(
            sorted(data), ["events", "exit_code", "problems", "schema", "tool"]
        )
        self.assertEqual(data["tool"], "x_doctor.py")
        self.assertEqual(data["schema"], 1)
        self.assertEqual(data["exit_code"], 0)
        self.assertEqual(
            data["events"], [{"level": "ok", "section": "s", "message": "m"}]
        )

    def test_problems_counts_only_fail_events(self):
        events = [
            ("fail", "a", "one"),
            ("warn", "a", "two"),
            ("info", "a", "three"),
            ("detail", "b", "four"),
            ("fail", "b", "five"),
        ]
        data = json.loads(doctor.render_json("t", events, 1))
        self.assertEqual(data["problems"], 2)
        self.assertEqual(data["exit_code"], 1)

    def test_empty_events(self):
        data = json.loads(doctor.render_json("t", [], 0))
        self.assertEqual(data["events"], [])
        self.assertEqual(data["problems"], 0)

    def test_unicode_message_survives(self):
        message = "not ignored — the file is tracked"
        data = json.loads(doctor.render_json("t", [("fail", "s", message)], 1))
        self.assertEqual(data["events"][0]["message"], message)

    def test_output_is_one_line(self):
        out = doctor.render_json("t", [("info", "s", "a\nb")], 0)
        self.assertNotIn("\n", out)

    def test_ansi_is_not_in_the_message(self):
        self.quietly(doctor.raw, "        \x1b[2mpath\x1b[0m  (rule)")
        self.assertEqual(doctor.EVENTS, [("detail", "", "path  (rule)")])
        self.assertNotIn("\x1b", doctor.EVENTS[0][2])

    def test_head_sets_the_section_of_following_events(self):
        self.quietly(doctor.head, "remotes")
        self.quietly(doctor.bad, "broken")
        self.quietly(doctor.info, "fix: something")
        self.assertEqual(
            doctor.EVENTS,
            [("fail", "remotes", "broken"), ("info", "remotes", "fix: something")],
        )

    def test_printers_record_their_level(self):
        for fn, level in ((doctor.ok, "ok"), (doctor.warn, "warn"),
                          (doctor.bad, "fail"), (doctor.info, "info")):
            self.quietly(fn, "m")
            self.assertEqual(doctor.EVENTS[-1][0], level)


def log_record(sha="a" * 40, status="G", signer="", key="", author="me@example.com",
               committer="me@example.com", subject="a subject"):
    """One record as `git log --format=LOG_FORMAT` prints it."""
    return "\x1f".join([sha, status, signer, key, author, committer, subject]) + "\x1e"


class ParseSignatureLogTestCase(unittest.TestCase):
    TWO = (
        log_record(sha="1" * 40, status="G", signer="Me <me@example.com>", key="ABCD",
                   subject="feat: a thing: with a colon")
        + "\n"
        + log_record(sha="2" * 40, status="N", subject="fix two words")
    )

    def test_two_records(self):
        commits = doctor.parse_signature_log(self.TWO)
        self.assertEqual([c.sha for c in commits], ["1" * 40, "2" * 40])
        self.assertEqual(commits[0].status, "G")
        self.assertEqual(commits[0].key, "ABCD")

    def test_a_subject_with_spaces_and_a_colon_stays_whole(self):
        self.assertEqual(
            doctor.parse_signature_log(self.TWO)[0].subject, "feat: a thing: with a colon"
        )

    def test_an_unsigned_commit_has_an_empty_signer(self):
        self.assertEqual(doctor.parse_signature_log(self.TWO)[1].signer, "")

    def test_a_truncated_final_record_is_dropped(self):
        cut = self.TWO + "\n" + "3" * 40 + "\x1fG\x1f"
        self.assertEqual(len(doctor.parse_signature_log(cut)), 2)

    def test_empty_text(self):
        self.assertEqual(doctor.parse_signature_log(""), [])


class AuthorFilterTestCase(unittest.TestCase):
    def commit(self, repo, email, subject):
        subprocess.run(
            ["git", "-C", repo, "-c", "user.name=T", "-c", "user.email=" + email,
             "commit", "-q", "--allow-empty", "-m", subject],
            check=True, capture_output=True,
        )

    def last(self, repo, n, email):
        out = subprocess.run(
            ["git", "-C", repo, "log", "-n", str(n), *doctor.author_filter_args(email),
             "--format=%s"],
            check=True, capture_output=True, text=True,
        ).stdout
        return out.split()

    def test_no_email_adds_no_option(self):
        self.assertEqual(doctor.author_filter_args(""), [])

    def test_n_counts_only_the_users_commits_under_teammate_commits(self):
        with tempfile.TemporaryDirectory() as repo:
            subprocess.run(["git", "init", "-q", repo], check=True)
            self.commit(repo, "me+dev@x.io", "mine-old")
            self.commit(repo, "me+dev@x.io", "mine-new")
            for i in range(3):
                self.commit(repo, "mate@x.io", "mate%d" % i)
            self.assertEqual(self.last(repo, 2, "me+dev@x.io"), ["mine-new", "mine-old"])
            self.assertEqual(self.last(repo, 2, "ME+dev@X.io"), ["mine-new", "mine-old"])

    def test_the_address_is_matched_whole_and_literally(self):
        with tempfile.TemporaryDirectory() as repo:
            subprocess.run(["git", "init", "-q", repo], check=True)
            self.commit(repo, "a.b@x.io", "mine")
            self.commit(repo, "aXb@x.io", "dot")
            self.commit(repo, "a.b@x.io.uk", "suffix")
            self.commit(repo, "xa.b@x.io", "prefix")
            self.assertEqual(self.last(repo, 5, "a.b@x.io"), ["mine"])


class SummariseSignaturesTestCase(unittest.TestCase):
    def summarise(self, records, signing_expected=False, user_email=""):
        return doctor.summarise_signatures(
            doctor.parse_signature_log("".join(records)), signing_expected, user_email
        )

    def levels(self, findings):
        return [level for level, _, _ in findings]

    def test_all_good_has_nothing_to_say(self):
        counts, findings = self.summarise([log_record(status="G")] * 3, True)
        self.assertEqual(counts, {"G": 3})
        self.assertEqual(findings, [])

    def test_a_bad_signature_fails_and_names_the_commit(self):
        _, findings = self.summarise([log_record(sha="b" * 40, status="B")])
        self.assertEqual(self.levels(findings), ["fail"])
        self.assertIn("bbbbbbb", findings[0][1])

    def test_expired_and_revoked_fail(self):
        for status in ("X", "Y", "R"):
            _, findings = self.summarise([log_record(status=status)])
            self.assertEqual(self.levels(findings), ["fail"], status)

    def test_unverifiable_fails_with_a_pointer(self):
        _, findings = self.summarise([log_record(status="E")])
        self.assertEqual(self.levels(findings), ["fail"])
        self.assertIn("allowed-signers", findings[0][2])

    def test_unsigned_is_information_when_signing_is_off(self):
        counts, findings = self.summarise([log_record(status="N")] * 2, False)
        self.assertEqual(counts, {"N": 2})
        self.assertEqual(self.levels(findings), ["info"])
        self.assertIn("2 unsigned commit(s)", findings[0][1])

    def test_unsigned_fails_when_signing_is_on(self):
        _, findings = self.summarise([log_record(status="N")], True)
        self.assertEqual(self.levels(findings), ["fail"])
        self.assertIn("is not signed", findings[0][1])

    def test_unknown_validity_is_information(self):
        _, findings = self.summarise([log_record(status="U")])
        self.assertEqual(self.levels(findings), ["info"])

    def test_a_signer_address_that_differs_from_the_committer_warns(self):
        _, findings = self.summarise(
            [log_record(status="G", signer="Other <other@example.org>")]
        )
        self.assertEqual(self.levels(findings), ["warn"])
        self.assertIn("other@example.org", findings[0][1])

    def test_the_same_address_in_another_case_is_not_a_mismatch(self):
        _, findings = self.summarise([log_record(status="G", signer="Me <ME@Example.com>")])
        self.assertEqual(findings, [])

    def test_an_ssh_principal_without_an_address_is_not_a_mismatch(self):
        _, findings = self.summarise([log_record(status="G", signer="deploy-key")])
        self.assertEqual(findings, [])

    def test_only_the_users_own_commits_are_judged(self):
        counts, findings = self.summarise(
            [log_record(status="B", author="someone@example.org"), log_record(status="G")],
            user_email="ME@example.com",
        )
        self.assertEqual(counts, {"G": 1})
        self.assertEqual(findings, [])

    def test_the_summary_line(self):
        self.assertEqual(
            doctor.summary_line(50, False, {"G": 47, "N": 2, "Y": 1}),
            "last 50 commits (yours): 47 good, 2 unsigned, 1 expired key",
        )
        self.assertEqual(
            doctor.summary_line(1, True, {"G": 1}), "last 1 commit (all authors): 1 good"
        )


if __name__ == "__main__":
    unittest.main()

"""Tests for git/git_ssh_doctor.py.

Only the pure parts are covered here: URL parsing, Include resolution and key
detection. Anything that shells out to ssh is left alone — it needs a network
and a remote account, and mocking it would only assert that the mock was called.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "git"))

import git_ssh_doctor as doctor  # noqa: E402


class SshHostOfTestCase(unittest.TestCase):
    def test_scp_like_url(self):
        self.assertEqual(
            doctor.ssh_host_of("git@github.com:owner/repo.git"), "github.com"
        )

    def test_scp_like_without_user(self):
        self.assertEqual(doctor.ssh_host_of("github.com:owner/repo.git"), "github.com")

    def test_ssh_scheme_url(self):
        self.assertEqual(
            doctor.ssh_host_of("ssh://git@gitlab.example.com/group/repo.git"),
            "gitlab.example.com",
        )

    def test_ssh_scheme_with_port(self):
        self.assertEqual(
            doctor.ssh_host_of("ssh://git@example.com:2222/repo.git"), "example.com"
        )

    def test_https_is_not_ssh(self):
        self.assertIsNone(doctor.ssh_host_of("https://github.com/owner/repo.git"))

    def test_plain_local_path_is_not_ssh(self):
        self.assertIsNone(doctor.ssh_host_of("/srv/git/repo.git"))


class IncludeTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ssh_dir = os.path.join(self._tmp.name, ".ssh")
        os.makedirs(self.ssh_dir)
        # parse_includes resolves relative Include paths against SSH_DIR.
        self._orig_ssh_dir = doctor.SSH_DIR
        doctor.SSH_DIR = self.ssh_dir

    def tearDown(self):
        doctor.SSH_DIR = self._orig_ssh_dir
        self._tmp.cleanup()

    def write(self, relpath, content):
        path = os.path.join(self.ssh_dir, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(content)
        return path

    def test_plain_config_loads(self):
        cfg = self.write("config", "Host example\n  User me\n")
        loaded, problems = doctor.parse_includes(cfg)
        self.assertEqual(loaded, [cfg])
        self.assertEqual(problems, [])

    def test_include_of_a_file_is_followed(self):
        self.write("extra/hosts", "Host inner\n")
        cfg = self.write("config", "Include extra/hosts\n")
        loaded, problems = doctor.parse_includes(cfg)
        self.assertEqual(len(loaded), 2)
        self.assertEqual(problems, [])

    def test_include_glob_matching_only_directories_is_reported(self):
        # The real-world failure: `Include keys/projects/*` where every match is
        # a directory. ssh skips them without a word, so the configs one level
        # deeper are never read.
        os.makedirs(os.path.join(self.ssh_dir, "keys", "projects", "personal"))
        os.makedirs(os.path.join(self.ssh_dir, "keys", "projects", "work"))
        self.write("keys/projects/work/gitlab", "Host gitlab\n")
        cfg = self.write("config", "Include keys/projects/*\n")

        loaded, problems = doctor.parse_includes(cfg)
        self.assertEqual(loaded, [cfg], "no nested config should have been loaded")
        self.assertEqual(len(problems), 1)
        pattern, kind, detail = problems[0]
        self.assertEqual(kind, "directories")
        self.assertIn("personal", detail)
        self.assertIn("work", detail)

    def test_deeper_glob_loads_the_nested_configs(self):
        # The fix the tool recommends.
        os.makedirs(os.path.join(self.ssh_dir, "keys", "projects", "work"))
        self.write("keys/projects/work/gitlab", "Host gitlab\n")
        cfg = self.write("config", "Include keys/projects/*/*\n")

        loaded, problems = doctor.parse_includes(cfg)
        self.assertEqual(len(loaded), 2)
        self.assertEqual(problems, [])

    def test_include_matching_nothing_is_reported(self):
        cfg = self.write("config", "Include does/not/exist/*\n")
        _, problems = doctor.parse_includes(cfg)
        self.assertEqual(len(problems), 1)
        self.assertEqual(problems[0][1], "no-match")

    def test_commented_include_is_ignored(self):
        cfg = self.write("config", "# Include nope/*\nHost x\n")
        _, problems = doctor.parse_includes(cfg)
        self.assertEqual(problems, [])

    def test_include_cycle_terminates(self):
        a = self.write("a", "Include b\n")
        self.write("b", "Include a\n")
        loaded, _ = doctor.parse_includes(a)
        self.assertEqual(len(loaded), 2)

    def test_multiple_patterns_on_one_line(self):
        self.write("one", "Host one\n")
        self.write("two", "Host two\n")
        cfg = self.write("config", "Include one two\n")
        loaded, problems = doctor.parse_includes(cfg)
        self.assertEqual(len(loaded), 3)
        self.assertEqual(problems, [])


class KeyDetectionTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ssh_dir = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, name, content, mode=0o600):
        path = os.path.join(self.ssh_dir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(content)
        os.chmod(path, mode)
        return path

    def test_finds_keys_at_any_depth(self):
        self.write("id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n")
        self.write("nested/deep/work_key", "-----BEGIN RSA PRIVATE KEY-----\nx\n")
        keys = doctor.discover_keys(self.ssh_dir)
        self.assertEqual(len(keys), 2)

    def test_skips_public_keys_and_known_files(self):
        self.write("id_ed25519.pub", "ssh-ed25519 AAAA...")
        self.write("known_hosts", "github.com ssh-rsa AAAA...")
        self.write("config", "Host x\n")
        self.assertEqual(doctor.discover_keys(self.ssh_dir), [])

    def test_skips_files_that_are_not_keys(self):
        self.write("notes.txt", "just some text")
        self.assertEqual(doctor.discover_keys(self.ssh_dir), [])

    def test_loose_permissions_are_flagged(self):
        key = self.write("loose", "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n", mode=0o644)
        self.assertEqual(doctor.permissions_problem(key), "0o644")

    def test_correct_permissions_are_not_flagged(self):
        key = self.write("tight", "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n", mode=0o600)
        self.assertIsNone(doctor.permissions_problem(key))


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


if __name__ == "__main__":
    unittest.main()

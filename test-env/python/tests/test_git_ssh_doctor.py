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
import subprocess
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

    def test_ssh_scheme_port_is_kept_in_the_target(self):
        self.assertEqual(
            doctor.ssh_target_of("ssh://git@example.com:2222/repo.git"),
            ("example.com", "2222"),
        )

    def test_target_without_a_port_has_an_empty_one(self):
        self.assertEqual(
            doctor.ssh_target_of("ssh://git@example.com/repo.git"), ("example.com", "")
        )
        self.assertEqual(
            doctor.ssh_target_of("git@github.com:owner/repo.git"), ("github.com", "")
        )

    def test_bracketed_ipv6_host_with_a_port(self):
        self.assertEqual(
            doctor.ssh_target_of("ssh://git@[::1]:2222/repo.git"), ("::1", "2222")
        )

    def test_https_is_not_ssh(self):
        self.assertIsNone(doctor.ssh_target_of("https://github.com/o/r.git"))

    def test_https_url_is_not_ssh(self):
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


SSH_G = """user git
hostname github.com
port 22
identityfile ~/.ssh/id_rsa
identityfile ~/.ssh/id_ed25519
userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2
globalknownhostsfile /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2
stricthostkeychecking ask
Port 2222

malformed
"""


class ParseSshGTestCase(unittest.TestCase):
    def test_identity_files_stay_a_list_in_order(self):
        self.assertEqual(
            doctor.parse_ssh_g(SSH_G)["identityfile"], ["~/.ssh/id_rsa", "~/.ssh/id_ed25519"]
        )

    def test_known_hosts_files_are_split(self):
        self.assertEqual(
            doctor.parse_ssh_g(SSH_G)["userknownhostsfile"],
            ["~/.ssh/known_hosts", "~/.ssh/known_hosts2"],
        )

    def test_a_quoted_path_with_a_space_stays_one_entry(self):
        cfg = doctor.parse_ssh_g('userknownhostsfile "/a b/known" /c\n')
        self.assertEqual(cfg["userknownhostsfile"], ["/a b/known", "/c"])

    def test_keys_are_lower_cased_and_the_first_wins(self):
        cfg = doctor.parse_ssh_g(SSH_G)
        self.assertEqual(cfg["port"], "22")
        self.assertEqual(cfg["stricthostkeychecking"], "ask")

    def test_blank_and_malformed_lines_are_ignored(self):
        self.assertNotIn("malformed", doctor.parse_ssh_g(SSH_G))

    def test_empty_text(self):
        self.assertEqual(doctor.parse_ssh_g(""), {"identityfile": []})


class KnownHostsSpecTestCase(unittest.TestCase):
    def test_default_port_is_the_bare_host(self):
        self.assertEqual(doctor.known_hosts_spec("github.com", "22"), "github.com")
        self.assertEqual(doctor.known_hosts_spec("github.com", ""), "github.com")

    def test_other_ports_are_bracketed(self):
        self.assertEqual(
            doctor.known_hosts_spec("git.example.com", "2222"), "[git.example.com]:2222"
        )

    def test_an_alias_replaces_the_host(self):
        self.assertEqual(doctor.known_hosts_spec("git.example.com", "2222", "gh"), "gh")
        self.assertEqual(
            doctor.known_hosts_spec("git.example.com", "2222", "none"),
            "[git.example.com]:2222",
        )

    def test_ipv6_literals(self):
        self.assertEqual(doctor.known_hosts_spec("2001:db8::1", "22"), "2001:db8::1")
        self.assertEqual(doctor.known_hosts_spec("2001:db8::1", "2222"), "[2001:db8::1]:2222")


class HostKeyFindingsTestCase(unittest.TestCase):
    FILES = ["~/.ssh/known_hosts"]

    def levels(self, findings):
        return [level for level, _, _ in findings]

    def test_a_known_key_is_information_only(self):
        findings = doctor.host_key_findings("h", "22", "ask", self.FILES, self.FILES, False)
        self.assertEqual(self.levels(findings), ["info"])

    def test_an_unknown_key_warns_about_non_interactive_runs(self):
        [(level, message, fix)] = doctor.host_key_findings("h", "22", "ask", [], self.FILES,
                                                          False)
        self.assertEqual(level, "warn")
        self.assertIn("non-interactive", message)
        # The verification step is the point of the fix; piping ssh-keyscan
        # straight into known_hosts would trust whoever answered.
        self.assertIn("ssh-keygen -lf", fix)
        self.assertIn("ssh-keyscan -t ed25519 -p 22 h", fix)

    def test_strict_yes_as_ssh_g_prints_it(self):
        self.assertEqual(
            self.levels(doctor.host_key_findings("h", "22", "true", [], self.FILES, False)),
            ["warn"],
        )

    def test_require_turns_the_warning_into_a_failure(self):
        findings = doctor.host_key_findings("h", "22", "ask", [], self.FILES, False,
                                            require=True)
        self.assertEqual(self.levels(findings), ["fail"])

    def test_strict_off_warns_about_a_man_in_the_middle_even_when_known(self):
        for value in ("no", "false", "off"):
            findings = doctor.host_key_findings("h", "22", value, self.FILES, self.FILES,
                                                False)
            self.assertEqual(findings[0][0], "warn", value)
            self.assertIn("man-in-the-middle", findings[0][1])

    def test_accept_new_with_an_unknown_key_is_information(self):
        findings = doctor.host_key_findings("h", "22", "accept-new", [], self.FILES, False)
        self.assertEqual(self.levels(findings), ["info"])

    def test_require_fails_an_unknown_key_under_accept_new(self):
        # accept-new would trust whatever key the runner's first connection
        # sees, which is the case the CI preflight exists to catch.
        [(level, message, fix)] = doctor.host_key_findings(
            "h", "22", "accept-new", [], self.FILES, False, require=True)
        self.assertEqual(level, "fail")
        self.assertIn("accept-new", message)
        self.assertIn("ssh-keygen -lf", fix)

    def test_require_fails_an_unknown_key_with_strict_off(self):
        findings = doctor.host_key_findings("h", "22", "no", [], self.FILES, False,
                                            require=True)
        self.assertEqual(self.levels(findings), ["warn", "fail"])
        self.assertIn("StrictHostKeyChecking no", findings[1][1])

    def test_strict_off_with_an_unknown_key_only_warns_without_require(self):
        findings = doctor.host_key_findings("h", "22", "no", [], self.FILES, False)
        self.assertEqual(self.levels(findings), ["warn"])

    def test_hashed_entries_are_information(self):
        findings = doctor.host_key_findings("h", "22", "ask", self.FILES, self.FILES, True)
        self.assertEqual(self.levels(findings), ["info", "info"])

    def test_a_non_default_port_is_named(self):
        [(_, message, fix)] = doctor.host_key_findings("h", "2222", "ask", [], [], False)
        self.assertIn("h port 2222", message)
        self.assertIn("-p 2222 h", fix)

    def test_a_host_key_alias_is_what_the_fix_records(self):
        [(_, _, fix)] = doctor.host_key_findings("h", "22", "ask", [], [], False,
                                                 alias="my alias")
        self.assertIn("awk -v a='my alias'", fix)
        self.assertIn(">> ~/.ssh/known_hosts", fix)

    def test_no_alias_keeps_the_plain_fix(self):
        [(_, _, fix)] = doctor.host_key_findings("h", "22", "ask", [], [], False, alias="none")
        self.assertIn("cat /tmp/hostkey >> ~/.ssh/known_hosts", fix)


class CheckHostKeyTests(unittest.TestCase):
    def _check(self, cfg, require, which):
        saved = (doctor.shutil.which, doctor.run, list(doctor.EVENTS))
        calls = []
        doctor.shutil.which = lambda name: which
        doctor.run = lambda cmd, timeout=15: calls.append(cmd) or (1, "", "")
        del doctor.EVENTS[:]
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                result = doctor.check_host_key("h", cfg, require)
        finally:
            doctor.shutil.which, doctor.run = saved[0], saved[1]
            doctor.EVENTS[:] = saved[2]
        return result, out.getvalue(), calls

    def test_require_fails_closed_without_ssh_keygen(self):
        result, out, _ = self._check({"hostname": "h"}, True, None)
        self.assertEqual(result, (False, False))
        self.assertIn("cannot check: ssh-keygen not found", out)

    def test_without_require_a_missing_ssh_keygen_only_informs(self):
        result, out, _ = self._check({"hostname": "h"}, False, None)
        self.assertEqual(result, (True, True))
        self.assertNotIn("[fail]", out)

    def test_known_hosts_command_is_reported_and_not_failed(self):
        with tempfile.TemporaryDirectory() as d:
            kh = os.path.join(d, "known_hosts")
            open(kh, "w").close()
            cfg = doctor.parse_ssh_g(
                "hostname h\nport 22\nknownhostscommand /bin/true %h\n"
                "userknownhostsfile " + kh + "\nglobalknownhostsfile none\n")
            result, out, calls = self._check(cfg, True, "/usr/bin/ssh-keygen")
        self.assertTrue(result[0])
        self.assertIn("KnownHostsCommand (not checked)", out)
        self.assertNotIn("[fail]", out)
        self.assertEqual([c[0] for c in calls], ["ssh-keygen"])

    def test_known_hosts_command_none_does_not_mask_a_missing_key(self):
        cfg = doctor.parse_ssh_g("hostname h\nknownhostscommand none\n")
        result, out, _ = self._check(cfg, True, "/usr/bin/ssh-keygen")
        self.assertFalse(result[0])
        self.assertIn("[fail]", out)


class AuthStrictnessThroughMainTests(unittest.TestCase):
    """main() with stub ssh, ssh-keygen and ssh-add programs on PATH.

    The stub ssh answers `ssh -G` with a KnownHostsCommand and records the
    arguments of every other call, so the auth command line is asserted as
    it is really built.
    """

    def setUp(self):
        if os.name == "nt":
            self.skipTest("POSIX shell stubs cannot run on Windows")
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.bin = os.path.join(self._tmp.name, "bin")
        self.ssh_dir = os.path.join(self._tmp.name, "ssh")
        self.log = os.path.join(self._tmp.name, "ssh-args.log")
        os.makedirs(self.bin)
        os.makedirs(self.ssh_dir)
        self._stub("ssh", 'if [ "$1" = "-G" ]; then\n'
                   '  echo "hostname h"; echo "port 22"\n'
                   '  echo "knownhostscommand /bin/true %h"\n'
                   '  echo "userknownhostsfile none"\n'
                   '  echo "globalknownhostsfile none"\n'
                   '  exit 0\nfi\n'
                   'echo "$*" >> "' + self.log + '"\n'
                   'echo "successfully authenticated" >&2\nexit 1\n')
        self._stub("ssh-add", 'echo "256 SHA256:x key (ED25519)"\nexit 0\n')

    def _stub(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def _main(self, argv):
        saved = (os.environ["PATH"], list(doctor.EVENTS))
        os.environ["PATH"] = self.bin
        del doctor.EVENTS[:]
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = doctor.main(["--ssh-dir", self.ssh_dir, "--host", "h"] + argv)
        finally:
            os.environ["PATH"] = saved[0]
            doctor.EVENTS[:] = saved[1]
        calls = []
        if os.path.exists(self.log):
            with open(self.log) as fh:
                calls = fh.read().splitlines()
        return rc, out.getvalue(), calls

    def test_require_known_host_never_uses_accept_new(self):
        self._stub("ssh-keygen", "exit 1\n")
        rc, out, calls = self._main(["--require-known-host", "--test-auth"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(calls), 1)
        self.assertIn("StrictHostKeyChecking=yes", calls[0])
        self.assertNotIn("accept-new", calls[0])
        self.assertIn("UpdateHostKeys=no", calls[0])
        self.assertIn("CheckHostIP=no", calls[0])

    def test_without_require_the_auth_attempt_uses_accept_new(self):
        self._stub("ssh-keygen", "exit 1\n")
        rc, out, calls = self._main(["--test-auth"])
        self.assertEqual(len(calls), 1)
        self.assertIn("StrictHostKeyChecking=accept-new", calls[0])
        self.assertNotIn("UpdateHostKeys", calls[0])
        self.assertNotIn("CheckHostIP", calls[0])

    def test_no_authentication_without_test_auth(self):
        self._stub("ssh-keygen", "exit 1\n")
        for argv in ([], ["--quiet"], ["--json"], ["--require-known-host"]):
            rc, out, calls = self._main(argv)
            self.assertEqual(calls, [], argv)
            self.assertEqual(rc, 0, argv)
        _, out, _ = self._main([])
        self.assertIn("authentication not attempted", out)

    def test_quiet_with_test_auth_still_authenticates(self):
        self._stub("ssh-keygen", "exit 1\n")
        rc, out, calls = self._main(["--quiet", "--test-auth"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(out, "")

    def test_missing_ssh_keygen_with_require_says_unchecked_and_skips_auth(self):
        rc, out, calls = self._main(["--require-known-host", "--test-auth"])
        self.assertEqual(rc, 1)
        self.assertEqual(calls, [])
        self.assertIn("the host key could not be checked", out)
        self.assertNotIn("would record the unknown host key", out)


class RemotePortThroughMainTests(unittest.TestCase):
    """A port in an ssh:// remote URL reaches `ssh -G -p`, the known_hosts
    lookup ([host]:port) and the authentication attempt.

    Stub ssh and ssh-keygen sit first on PATH: the ssh stub echoes the port it
    was given, and the ssh-keygen stub matches its -F name against the first
    field of the known_hosts file it is pointed at.
    """

    def setUp(self):
        if os.name == "nt":
            self.skipTest("POSIX shell stubs cannot run on Windows")
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = self._tmp.name
        self.bin = os.path.join(root, "bin")
        self.ssh_dir = os.path.join(root, "ssh")
        self.log = os.path.join(root, "ssh-args.log")
        self.known = os.path.join(root, "known_hosts")
        self.repo = os.path.join(root, "repo")
        for d in (self.bin, self.ssh_dir, self.repo):
            os.makedirs(d)
        self._stub("ssh", 'echo "$*" >> "' + self.log + '"\n'
                   'if [ "$1" = "-G" ]; then\n'
                   '  port=22; [ "$2" = "-p" ] && port="$3"\n'
                   '  echo "hostname example.com"; echo "port $port"\n'
                   '  echo "stricthostkeychecking ask"\n'
                   '  echo "userknownhostsfile ' + self.known + '"\n'
                   '  echo "globalknownhostsfile none"\n'
                   '  exit 0\nfi\n'
                   'echo "successfully authenticated" >&2\nexit 1\n')
        self._stub("ssh-keygen", 'while read -r name rest; do\n'
                   '  [ "$name" = "$2" ] && exit 0\ndone < "$4"\nexit 1\n')
        self._stub("ssh-add", 'echo "256 SHA256:x key (ED25519)"\nexit 0\n')
        for cmd in (["git", "init", "-q"],
                    ["git", "remote", "add", "origin",
                     "ssh://git@example.com:2222/owner/repo.git"]):
            subprocess.run(cmd, cwd=self.repo, check=True, capture_output=True)

    def _stub(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def _main(self, known_line):
        with open(self.known, "w") as fh:
            fh.write(known_line + "\n")
        saved = (os.environ["PATH"], os.getcwd(), list(doctor.EVENTS))
        os.environ["PATH"] = self.bin + os.pathsep + saved[0]
        os.chdir(self.repo)
        del doctor.EVENTS[:]
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = doctor.main(["--ssh-dir", self.ssh_dir, "--require-known-host",
                                  "--test-auth"])
        finally:
            os.environ["PATH"] = saved[0]
            os.chdir(saved[1])
            doctor.EVENTS[:] = saved[2]
        with open(self.log) as fh:
            calls = fh.read().splitlines()
        return rc, out.getvalue(), calls

    def test_a_pinned_bracketed_entry_satisfies_require_known_host(self):
        rc, out, calls = self._main("[example.com]:2222 ssh-ed25519 AAAA")
        self.assertEqual(rc, 0, out)
        self.assertEqual(calls[0], "-G -p 2222 example.com")
        self.assertIn("port 2222", out)
        self.assertIn("host key present", out)
        auth = [c for c in calls if "-T" in c.split()]
        self.assertEqual(len(auth), 1)
        self.assertIn("-p 2222", auth[0])
        self.assertIn("StrictHostKeyChecking=yes", auth[0])

    def test_an_entry_for_the_default_port_does_not_pin_the_custom_port(self):
        rc, out, calls = self._main("example.com ssh-ed25519 AAAA")
        self.assertEqual(rc, 1)
        self.assertIn("example.com port 2222 is not in", out)
        self.assertEqual([c for c in calls if "-T" in c.split()], [])


class SshCommandAndUserThroughMainTests(unittest.TestCase):
    """The user git would use reaches the authentication attempt. Stub ssh logs every call; ssh -G answers with a
    configured user that the tests must not see win over a user in the URL."""

    def setUp(self):
        if os.name == "nt":
            self.skipTest("POSIX shell stubs cannot run on Windows")
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = self._tmp.name
        self.bin = os.path.join(root, "bin")
        self.ssh_dir = os.path.join(root, "ssh")
        self.log = os.path.join(root, "ssh-args.log")
        self.known = os.path.join(root, "known_hosts")
        self.userfile = os.path.join(root, "ssh-g-user")
        self.repo = os.path.join(root, "repo")
        for d in (self.bin, self.ssh_dir, self.repo):
            os.makedirs(d)
        with open(self.known, "w") as fh:
            fh.write("example.com ssh-ed25519 AAAA\n")
        self._set_g_user("cfguser")
        self._stub("ssh", 'echo "$*" >> "' + self.log + '"\n'
                   'if [ "$1" = "-G" ]; then\n'
                   '  echo "hostname example.com"; echo "port 22"\n'
                   '  echo "user $(cat "' + self.userfile + '")"\n'
                   '  echo "stricthostkeychecking ask"\n'
                   '  echo "userknownhostsfile ' + self.known + '"\n'
                   '  echo "globalknownhostsfile none"\n'
                   '  exit 0\nfi\n'
                   'echo "successfully authenticated" >&2\nexit 1\n')
        self._stub("ssh-keygen", 'while read -r name rest; do\n'
                   '  [ "$name" = "$2" ] && exit 0\ndone < "$4"\nexit 1\n')
        self._stub("ssh-add", 'echo "256 SHA256:x key (ED25519)"\nexit 0\n')
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True,
                       capture_output=True)

    def _set_g_user(self, name):
        with open(self.userfile, "w") as fh:
            fh.write(name + "\n")

    def _stub(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def _git(self, *args):
        subprocess.run(["git"] + list(args), cwd=self.repo, check=True,
                       capture_output=True)

    def _main(self, url, argv=("--test-auth",)):
        subprocess.run(["git", "remote", "remove", "origin"], cwd=self.repo,
                       capture_output=True)
        if os.path.exists(self.log):
            os.remove(self.log)
        self._git("remote", "add", "origin", url)
        names = ("PATH", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")
        saved = {n: os.environ.get(n) for n in names}
        saved_state = (os.getcwd(), list(doctor.EVENTS))
        os.environ["PATH"] = self.bin + os.pathsep + saved["PATH"]
        os.environ["GIT_CONFIG_GLOBAL"] = os.devnull
        os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
        os.chdir(self.repo)
        del doctor.EVENTS[:]
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                rc = doctor.main(["--ssh-dir", self.ssh_dir] + list(argv))
        finally:
            for n, v in saved.items():
                if v is None:
                    os.environ.pop(n, None)
                else:
                    os.environ[n] = v
            os.chdir(saved_state[0])
            doctor.EVENTS[:] = saved_state[1]
        calls = []
        if os.path.exists(self.log):
            with open(self.log) as fh:
                calls = fh.read().splitlines()
        return rc, out.getvalue(), calls

    @staticmethod
    def _auth(calls):
        return [c for c in calls if "-T" in c.split()]

    def test_user_in_an_ssh_url_is_the_one_probed(self):
        rc, out, calls = self._main("ssh://alice@example.com/o/r.git")
        auth = self._auth(calls)
        self.assertEqual(len(auth), 1, out)
        self.assertTrue(auth[0].endswith("-T alice@example.com"), auth[0])

    def test_user_in_an_scp_like_url_is_the_one_probed(self):
        rc, out, calls = self._main("bob@example.com:o/r.git")
        auth = self._auth(calls)
        self.assertTrue(auth[0].endswith("-T bob@example.com"), auth[0])

    def test_without_a_url_user_the_ssh_g_user_is_probed(self):
        rc, out, calls = self._main("example.com:o/r.git")
        auth = self._auth(calls)
        self.assertTrue(auth[0].endswith("-T cfguser@example.com"), auth[0])

    def test_without_a_url_user_the_local_account_is_not_probed(self):
        for local in sorted(doctor.local_accounts()) or ["nobody-here"]:
            self._set_g_user(local)
            rc, out, calls = self._main("example.com:o/r.git")
            self.assertTrue(self._auth(calls)[0].endswith("-T git@example.com"),
                            self._auth(calls))

    def test_host_flag_probes_git_when_ssh_g_only_reports_the_local_account(self):
        self._set_g_user(sorted(doctor.local_accounts())[0]
                         if doctor.local_accounts() else "nobody-here")
        rc, out, calls = self._main(
            "ssh://alice@example.com/o/r.git",
            argv=("--test-auth", "--host", "example.com"))
        self.assertTrue(self._auth(calls)[0].endswith("-T git@example.com"))

    def test_host_flag_accepts_user_at_host(self):
        rc, out, calls = self._main(
            "ssh://alice@example.com/o/r.git",
            argv=("--test-auth", "--host", "deploy@example.com"))
        self.assertEqual(calls[0], "-G example.com")
        self.assertTrue(self._auth(calls)[0].endswith("-T deploy@example.com"))


class SshUserOfTestCase(unittest.TestCase):
    def test_user_of_ssh_and_scp_urls(self):
        self.assertEqual(doctor.ssh_user_of("ssh://a@h:22/r"), "a")
        self.assertEqual(doctor.ssh_user_of("b@h:r"), "b")
        self.assertEqual(doctor.ssh_user_of("ssh://h/r"), "")
        self.assertEqual(doctor.ssh_user_of("h:r"), "")
        self.assertEqual(doctor.ssh_user_of("https://u@h/r"), "")

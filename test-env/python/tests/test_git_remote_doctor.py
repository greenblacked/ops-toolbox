"""Tests for git/git_remote_doctor.py.

Only the pure parts are covered: URL parsing, insteadOf resolution, credential
helper accumulation and redaction. Nothing here runs git, opens a socket or
looks at the machine's own configuration — the functions all take their input
as a string, which is why they can be tested at all.
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

import git_remote_doctor as doctor  # noqa: E402


def config(*records):
    """Build `git config --list --show-origin --show-scope -z` output.

    Each record is (scope, origin, key, value), in the order git printed them.
    """
    out = ""
    for scope, origin, key, value in records:
        out += "%s\0%s\0%s\n%s\0" % (scope, origin, key, value)
    return out


class ParseGitConfigTestCase(unittest.TestCase):
    def test_records_are_kept_in_order(self):
        entries = doctor.parse_git_config(
            config(
                ("global", "file:/home/x/.gitconfig", "credential.helper", "cache"),
                ("local", "file:.git/config", "credential.helper", "store"),
            )
        )
        self.assertEqual(
            [value for value, _, _ in entries["credential.helper"]], ["cache", "store"]
        )

    def test_empty_input(self):
        self.assertEqual(doctor.parse_git_config(""), {})

    def test_value_containing_a_newline(self):
        entries = doctor.parse_git_config(
            config(("local", "file:.git/config", "alias.l", "log --oneline\n--graph"))
        )
        self.assertEqual(entries["alias.l"][0][0], "log --oneline\n--graph")

    def test_subsection_case_is_preserved(self):
        # git lower-cases the section and the variable but not the middle: a
        # remote called Upstream is not the same as one called upstream, and a
        # rewrite base is a URL.
        entries = doctor.parse_git_config(
            config(("local", "file:.git/config", "remote.Upstream.URL", "git@h:o/r"))
        )
        self.assertIn("remote.Upstream.url", entries)

    def test_effective_takes_the_last_value(self):
        entries = doctor.parse_git_config(
            config(
                ("global", "file:~/.gitconfig", "user.email", "old@example.com"),
                ("local", "file:.git/config", "user.email", "new@example.com"),
            )
        )
        self.assertEqual(doctor.effective(entries, "user.email")[0], "new@example.com")

    def test_effective_is_case_insensitive_on_the_variable(self):
        entries = doctor.parse_git_config(
            config(("global", "file:~/.gitconfig", "user.email", "me@example.com"))
        )
        self.assertEqual(doctor.effective(entries, "USER.Email")[0], "me@example.com")

    def test_missing_key(self):
        self.assertIsNone(doctor.effective({}, "user.email"))


class ParseUrlTestCase(unittest.TestCase):
    def test_scp_like(self):
        parts = doctor.parse_url("git@github.com:owner/repo.git")
        self.assertEqual(parts["kind"], "scp")
        self.assertEqual(parts["user"], "git")
        self.assertEqual(parts["host"], "github.com")
        self.assertEqual(parts["path"], "owner/repo.git")

    def test_ssh_scheme_with_port(self):
        parts = doctor.parse_url("ssh://git@example.com:2222/owner/repo.git")
        self.assertEqual(parts["kind"], "ssh")
        self.assertEqual(parts["host"], "example.com")
        self.assertEqual(parts["port"], "2222")
        self.assertEqual(parts["path"], "owner/repo.git")

    def test_https(self):
        parts = doctor.parse_url("https://github.com/owner/repo.git")
        self.assertEqual(parts["kind"], "https")
        self.assertEqual(parts["host"], "github.com")
        self.assertEqual(parts["user"], "")

    def test_https_with_userinfo(self):
        parts = doctor.parse_url("https://user:secret@git.example.com/repo.git")
        self.assertEqual(parts["host"], "git.example.com")
        self.assertEqual(parts["user"], "user:secret")

    def test_ipv6_literal(self):
        parts = doctor.parse_url("ssh://git@[2001:db8::1]:22/repo.git")
        self.assertEqual(parts["host"], "2001:db8::1")
        self.assertEqual(parts["port"], "22")

    def test_git_protocol(self):
        self.assertEqual(doctor.parse_url("git://example.com/repo.git")["kind"], "git")

    def test_file_url(self):
        parts = doctor.parse_url("file:///srv/git/repo.git")
        self.assertEqual(parts["kind"], "file")
        self.assertEqual(parts["path"], "/srv/git/repo.git")

    def test_absolute_path_is_local(self):
        self.assertEqual(doctor.parse_url("/srv/git/repo.git")["kind"], "local")

    def test_relative_path_is_local(self):
        self.assertEqual(doctor.parse_url("../sibling.git")["kind"], "local")

    def test_empty(self):
        self.assertEqual(doctor.parse_url("")["kind"], "unknown")

    def test_unknown_scheme(self):
        self.assertEqual(doctor.parse_url("rsync://host/repo")["kind"], "unknown")


class UrlProblemsTestCase(unittest.TestCase):
    def levels(self, url):
        return [level for level, _, _ in doctor.url_problems(doctor.parse_url(url))]

    def messages(self, url):
        return " ".join(msg for _, msg, _ in doctor.url_problems(doctor.parse_url(url)))

    def test_https_is_clean(self):
        self.assertEqual(self.levels("https://github.com/owner/repo.git"), [])

    def test_ssh_is_clean(self):
        self.assertEqual(self.levels("git@github.com:owner/repo.git"), [])

    def test_git_protocol_fails(self):
        self.assertIn("fail", self.levels("git://example.com/repo.git"))

    def test_plain_http_warns(self):
        self.assertEqual(self.levels("http://example.com/repo.git"), ["warn"])

    def test_scp_port_mistake_is_caught(self):
        # The one that produces "repository not found" and sends people looking
        # at permissions: in scp syntax the colon starts a path, not a port.
        problems = doctor.url_problems(doctor.parse_url("git@example.com:2222/o/r.git"))
        self.assertEqual([level for level, _, _ in problems], ["fail"])
        self.assertIn("ssh://git@example.com:2222/o/r.git", problems[0][2])

    def test_a_numeric_directory_is_only_flagged_at_the_front(self):
        self.assertEqual(self.levels("git@example.com:owner/2222/repo.git"), [])

    def test_url_in_a_problem_message_is_redacted(self):
        self.assertNotIn(
            "sekrit", self.messages("rsync://user:sekrit@example.com/repo.git")
        )


class RedactTestCase(unittest.TestCase):
    def test_password_is_removed(self):
        self.assertEqual(
            doctor.redact_url("https://x-access-token:ghp_abcdef@github.com/o/r.git"),
            "https://x-access-token:***@github.com/o/r.git",
        )

    def test_short_username_is_kept(self):
        self.assertEqual(
            doctor.redact_url("https://sergey@github.com/o/r.git"),
            "https://sergey@github.com/o/r.git",
        )

    def test_long_userinfo_is_treated_as_a_token(self):
        self.assertEqual(
            doctor.redact_url("https://github_pat_11ABCDEFG0123456789@github.com/o/r"),
            "https://***@github.com/o/r",
        )

    def test_scp_url_is_untouched(self):
        self.assertEqual(
            doctor.redact_url("git@github.com:o/r.git"), "git@github.com:o/r.git"
        )

    def test_url_without_userinfo_is_untouched(self):
        self.assertEqual(
            doctor.redact_url("https://github.com/o/r.git"), "https://github.com/o/r.git"
        )

    def test_shell_helper_password_is_redacted(self):
        raw = "!f() { echo username=bot; echo password=super-secret-token; }; f"
        shown = doctor.redact_helper(raw)
        self.assertNotIn("super-secret-token", shown)
        self.assertIn("password=***", shown)

    def test_named_helper_is_untouched(self):
        self.assertEqual(doctor.redact_helper("osxkeychain"), "osxkeychain")


class CollectRemotesTestCase(unittest.TestCase):
    def test_url_and_pushurl(self):
        entries = doctor.parse_git_config(
            config(
                ("local", "file:.git/config", "remote.origin.url",
                 "https://github.com/o/r.git"),
                ("local", "file:.git/config", "remote.origin.pushurl",
                 "git@github.com:o/r.git"),
                ("local", "file:.git/config", "remote.origin.fetch",
                 "+refs/heads/*:refs/remotes/origin/*"),
            )
        )
        remotes = doctor.collect_remotes(entries)
        self.assertEqual(remotes["origin"]["fetch"], ["https://github.com/o/r.git"])
        self.assertEqual(remotes["origin"]["push"], ["git@github.com:o/r.git"])

    def test_push_defaults_to_the_fetch_url(self):
        entries = doctor.parse_git_config(
            config(("local", "file:.git/config", "remote.origin.url", "git@h:o/r.git"))
        )
        remotes = doctor.collect_remotes(entries)
        self.assertEqual(remotes["origin"]["push"], ["git@h:o/r.git"])

    def test_a_remote_name_containing_a_dot(self):
        entries = doctor.parse_git_config(
            config(("local", "file:.git/config", "remote.my.fork.url", "git@h:o/r.git"))
        )
        self.assertIn("my.fork", doctor.collect_remotes(entries))

    def test_refspecs_alone_make_no_remote(self):
        entries = doctor.parse_git_config(
            config(("local", "file:.git/config", "remote.origin.fetch", "+a:b"))
        )
        self.assertEqual(doctor.collect_remotes(entries), {})


class RewriteTestCase(unittest.TestCase):
    def test_collect_both_directions(self):
        entries = doctor.parse_git_config(
            config(
                ("global", "file:~/.gitconfig", "url.git@github.com:.insteadOf",
                 "https://github.com/"),
                ("global", "file:~/.gitconfig", "url.git@github.com:.pushInsteadOf",
                 "https://github.com/"),
            )
        )
        kinds = sorted(kind for _, _, kind in doctor.collect_rewrites(entries))
        self.assertEqual(kinds, ["insteadOf", "pushInsteadOf"])

    def test_rewrite_is_applied(self):
        rewrites = [("git@github.com:", "https://github.com/", "insteadOf")]
        dialled, pattern, base = doctor.apply_rewrites(
            "https://github.com/owner/repo.git", rewrites
        )
        self.assertEqual(dialled, "git@github.com:owner/repo.git")
        self.assertEqual(pattern, "https://github.com/")
        self.assertEqual(base, "git@github.com:")

    def test_longest_pattern_wins(self):
        rewrites = [
            ("git@github.com:", "https://github.com/", "insteadOf"),
            ("git@internal:", "https://github.com/acme/", "insteadOf"),
        ]
        dialled, pattern, _ = doctor.apply_rewrites(
            "https://github.com/acme/repo.git", rewrites
        )
        self.assertEqual(dialled, "git@internal:repo.git")
        self.assertEqual(pattern, "https://github.com/acme/")

    def test_no_match_returns_the_url_unchanged(self):
        rewrites = [("git@github.com:", "https://github.com/", "insteadOf")]
        dialled, pattern, _ = doctor.apply_rewrites("git@gitlab.com:o/r.git", rewrites)
        self.assertEqual(dialled, "git@gitlab.com:o/r.git")
        self.assertIsNone(pattern)

    def test_push_prefers_push_insteadof(self):
        rewrites = [
            ("https://mirror/", "https://github.com/", "insteadOf"),
            ("git@github.com:", "https://github.com/", "pushInsteadOf"),
        ]
        fetch, _, _ = doctor.apply_rewrites("https://github.com/o/r.git", rewrites)
        push, _, _ = doctor.apply_rewrites(
            "https://github.com/o/r.git", rewrites, push=True
        )
        self.assertEqual(fetch, "https://mirror/o/r.git")
        self.assertEqual(push, "git@github.com:o/r.git")

    def test_push_falls_back_to_insteadof(self):
        # git only treats pushInsteadOf as an override when one of them
        # matches; otherwise a push follows the same rewrite as a fetch.
        rewrites = [
            ("git@github.com:", "https://github.com/", "insteadOf"),
            ("git@elsewhere:", "https://gitlab.com/", "pushInsteadOf"),
        ]
        push, _, _ = doctor.apply_rewrites(
            "https://github.com/o/r.git", rewrites, push=True
        )
        self.assertEqual(push, "git@github.com:o/r.git")

    def test_rewrites_are_not_chained(self):
        # Documenting git's behaviour, which is what the report warns about:
        # the result of one rewrite is not fed through the next.
        rewrites = [
            ("https://step-two/", "https://step-one/", "insteadOf"),
            ("git@final:", "https://step-two/", "insteadOf"),
        ]
        dialled, _, _ = doctor.apply_rewrites("https://step-one/repo.git", rewrites)
        self.assertEqual(dialled, "https://step-two/repo.git")


class CredentialHelperTestCase(unittest.TestCase):
    def test_helpers_accumulate(self):
        entries = doctor.parse_git_config(
            config(
                ("system", "file:/etc/gitconfig", "credential.helper", "cache"),
                ("global", "file:~/.gitconfig", "credential.helper", "osxkeychain"),
            )
        )
        helpers, resets = doctor.credential_helpers(entries)
        self.assertEqual([v for v, _, _ in helpers], ["cache", "osxkeychain"])
        self.assertEqual(resets, [])

    def test_an_empty_value_discards_what_came_before(self):
        # The line people copy out of an answer without reading it, and then
        # spend an afternoon wondering where the keychain went.
        entries = doctor.parse_git_config(
            config(
                ("global", "file:~/.gitconfig", "credential.helper", "osxkeychain"),
                ("local", "file:.git/config", "credential.helper", ""),
                ("local", "file:.git/config", "credential.helper", "store"),
            )
        )
        helpers, resets = doctor.credential_helpers(entries)
        self.assertEqual([v for v, _, _ in helpers], ["store"])
        self.assertEqual(len(resets), 1)
        self.assertEqual(resets[0][2], 1, "one helper was discarded")

    def test_no_helper_configured(self):
        self.assertEqual(doctor.credential_helpers({}), ([], []))


class ClassifyHelperTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.bindir = os.path.join(self._tmp.name, "bin")
        self.execdir = os.path.join(self._tmp.name, "git-core")
        os.makedirs(self.bindir)
        os.makedirs(self.execdir)

    def tearDown(self):
        self._tmp.cleanup()

    def make(self, directory, name):
        path = os.path.join(directory, name)
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(path, 0o755)
        return path

    def test_a_name_resolves_through_path(self):
        self.make(self.bindir, "git-credential-manager")
        kind, resolved, problem = doctor.classify_helper("manager", self.bindir)
        self.assertEqual(kind, "name")
        self.assertTrue(resolved.endswith("git-credential-manager"))
        self.assertIsNone(problem)

    def test_a_builtin_helper_resolves_through_the_exec_path(self):
        # git-credential-store lives in /usr/lib/git-core, which is not on
        # PATH. Looking only at PATH would report it missing everywhere.
        self.make(self.execdir, "git-credential-store")
        kind, resolved, problem = doctor.classify_helper(
            "store", self.bindir, self.execdir
        )
        self.assertEqual(kind, "name")
        self.assertIsNone(problem)
        self.assertTrue(resolved.endswith("git-credential-store"))

    def test_a_missing_helper_is_reported(self):
        kind, resolved, problem = doctor.classify_helper("osxkeychain", self.bindir)
        self.assertEqual(kind, "name")
        self.assertIsNone(resolved)
        self.assertIn("git-credential-osxkeychain", problem)

    def test_arguments_are_ignored_when_resolving(self):
        self.make(self.execdir, "git-credential-store")
        _, _, problem = doctor.classify_helper(
            "store --file ~/.git-credentials", self.bindir, self.execdir
        )
        self.assertIsNone(problem)

    def test_a_shell_helper_is_not_resolved(self):
        kind, resolved, problem = doctor.classify_helper(
            "!f() { echo password=x; }; f", self.bindir
        )
        self.assertEqual(kind, "shell")
        self.assertIsNone(resolved)
        self.assertIsNone(problem)

    def test_an_absolute_path_that_exists(self):
        path = self.make(self.bindir, "my-helper")
        kind, resolved, problem = doctor.classify_helper(path, "")
        self.assertEqual(kind, "path")
        self.assertEqual(resolved, path)
        self.assertIsNone(problem)

    def test_an_absolute_path_that_does_not(self):
        kind, resolved, problem = doctor.classify_helper("/nope/helper", "")
        self.assertEqual(kind, "path")
        self.assertIsNone(resolved)
        self.assertIn("not an executable", problem)

    def test_empty(self):
        self.assertEqual(doctor.classify_helper("", ""), ("empty", None, None))


class CredentialFileTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, name, mode):
        path = os.path.join(self._tmp.name, name)
        with open(path, "w") as fh:
            fh.write("https://user:pass@example.com\n")
        os.chmod(path, mode)
        return path

    def test_group_readable_is_flagged(self):
        self.assertEqual(
            doctor.credential_file_problem(self.write("loose", 0o640)), "0o640"
        )

    def test_owner_only_is_not(self):
        self.assertIsNone(doctor.credential_file_problem(self.write("tight", 0o600)))

    def test_a_missing_file_is_not_a_problem(self):
        self.assertIsNone(
            doctor.credential_file_problem(os.path.join(self._tmp.name, "absent"))
        )


class NeedsCredentialsTestCase(unittest.TestCase):
    def test_http_kinds_need_a_helper(self):
        self.assertTrue(doctor.needs_credentials(["ssh", "https"]))

    def test_ssh_only_does_not(self):
        self.assertFalse(doctor.needs_credentials(["ssh", "scp", "local"]))


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


class JsonRedactionTestCase(unittest.TestCase):
    """--json must never say more than the text report did.

    Redaction happens before a line reaches a printer, and the printers are
    what record, so a secret the text hides cannot surface in the JSON. Both
    leak paths the text report already guards are driven through here.
    """

    def setUp(self):
        self._events = list(doctor.EVENTS)
        doctor.EVENTS.clear()

    def tearDown(self):
        doctor.EVENTS[:] = self._events

    def rendered(self):
        return doctor.render_json("git_remote_doctor.py", doctor.EVENTS, 0)

    def test_token_in_a_url_is_not_in_the_json(self):
        with contextlib.redirect_stdout(io.StringIO()):
            doctor.report_url("fetch", "https://user:s3cretpw@example.com/r.git",
                              [], push=False)
        out = self.rendered()
        self.assertNotIn("s3cretpw", out)
        self.assertIn("user:***@example.com", out)

    def test_shell_helper_password_is_not_in_the_json(self):
        entries = {"credential.helper": [
            ("!f() { echo password=hunter2hunter2; }; f", "file:/x/config", "global"),
        ]}
        with contextlib.redirect_stdout(io.StringIO()):
            doctor.diagnose_credentials(entries, [], "", "")
        out = self.rendered()
        self.assertNotIn("hunter2hunter2", out)
        self.assertIn("password=***", out)


class ScopedCredentialHelperTestCase(unittest.TestCase):
    """credential.<url>.helper counts toward the helpers a URL gets."""

    SHELL = "!f() { :; }; f"

    def diagnose(self, entries, urls):
        parts = [doctor.parse_url(u) for u in urls]
        with contextlib.redirect_stdout(io.StringIO()):
            return doctor.diagnose_credentials(entries, parts, "", "")

    def test_scoped_only_helper_passes_for_a_matching_url(self):
        entries = {"credential.https://github.com.helper": [
            (self.SHELL, "file:/x/config", "global")]}
        self.assertEqual(
            self.diagnose(entries, ["https://github.com/o/r.git"]), 0)

    def test_scoped_helper_does_not_cover_another_host(self):
        entries = {"credential.https://github.com.helper": [
            (self.SHELL, "file:/x/config", "global")]}
        self.assertEqual(
            self.diagnose(entries, ["https://gitlab.com/o/r.git"]), 1)

    def test_no_helper_at_all_is_still_a_problem(self):
        self.assertEqual(self.diagnose({}, ["https://github.com/o/r.git"]), 1)

    def test_url_matching_rules(self):
        match = doctor.credential_url_matches
        url = doctor.parse_url("https://user@example.com:443/team/repo.git")
        self.assertTrue(match("https://example.com", url))
        self.assertTrue(match("https://EXAMPLE.com/team", url))
        self.assertTrue(match("https://user@example.com", url))
        self.assertFalse(match("https://other@example.com", url))
        self.assertFalse(match("https://example.com/tea", url))
        self.assertFalse(match("http://example.com", url))
        self.assertFalse(match("https://example.com:8443", url))
        self.assertFalse(match("https://*.example.com", url))
        self.assertTrue(match("https://*.example.com", doctor.parse_url(
            "https://git.example.com/r")))

    def test_empty_scoped_value_resets_the_list(self):
        entries = {
            "credential.helper": [(self.SHELL, "file:/x/config", "global")],
            "credential.https://a.example.helper": [("", "file:/x/config", "local")],
        }
        helpers, _ = doctor.effective_credential_helpers(
            entries, doctor.parse_url("https://a.example/r"))
        self.assertEqual(helpers, [])


class ClassifyRemoteErrorTestCase(unittest.TestCase):
    """--probe: one named cause per failure, from git's and ssh's own words.

    The fixtures are the messages git and OpenSSH print, so a reworded
    pattern that stops matching them fails here rather than in someone's CI.
    """

    def cause(self, stderr, host=""):
        return doctor.classify_remote_error(stderr, host)[0]

    def test_dns_over_ssh(self):
        self.assertEqual(self.cause(
            "ssh: Could not resolve hostname github.invalid: Name or service not known\n"
            "fatal: Could not read from remote repository."), "dns")

    def test_dns_over_https(self):
        self.assertEqual(self.cause(
            "fatal: unable to access 'https://h.invalid/r.git/': Could not resolve host: "
            "h.invalid"), "dns")

    def test_ssh_publickey_names_the_ssh_doctor_for_the_host(self):
        cause, hint = doctor.classify_remote_error(
            "git@github.com: Permission denied (publickey).\n"
            "fatal: Could not read from remote repository.", "github.com")
        self.assertEqual(cause, "ssh-auth")
        self.assertIn("git_ssh_doctor.py --host github.com", hint)

    def test_unknown_host_key(self):
        cause, hint = doctor.classify_remote_error(
            "Host key verification failed.\n"
            "fatal: Could not read from remote repository.", "git.example.com")
        self.assertEqual(cause, "hostkey-unknown")
        self.assertIn("ssh-keyscan -t ed25519 git.example.com", hint)
        self.assertIn("verify the fingerprint", hint)

    def test_changed_host_key_beats_the_verification_failure_it_also_prints(self):
        cause, hint = doctor.classify_remote_error(
            "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n"
            "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
            "Host key verification failed.", "h")
        self.assertEqual(cause, "hostkey-changed")
        self.assertIn("ssh-keygen -R h", hint)

    def test_tls(self):
        cause, hint = doctor.classify_remote_error(
            "fatal: unable to access 'https://x.example/r.git/': SSL certificate problem: "
            "unable to get local issuer certificate")
        self.assertEqual(cause, "tls")
        # sslVerify=false is named only as what not to do.
        self.assertIn("not a fix", hint)

    def test_http_auth_without_a_prompt(self):
        self.assertEqual(self.cause(
            "fatal: could not read Username for 'https://github.com': terminal prompts "
            "disabled"), "http-auth")

    def test_http_403(self):
        self.assertEqual(self.cause(
            "fatal: unable to access 'https://h/r.git/': The requested URL returned error: "
            "403"), "http-auth")

    def test_repository_not_found(self):
        self.assertEqual(self.cause(
            "remote: Repository not found.\nfatal: repository 'https://h/o/r.git/' not found"),
            "not-found")

    def test_local_path_that_is_not_a_repository(self):
        self.assertEqual(self.cause(
            "fatal: '/nonexistent' does not appear to be a git repository\n"
            "fatal: Could not read from remote repository."), "not-found")

    def test_connection_refused(self):
        self.assertEqual(self.cause(
            "ssh: connect to host h port 22: Connection refused"), "network")
        self.assertEqual(self.cause(
            "fatal: unable to access 'https://127.0.0.1:1/r.git/': Failed to connect to "
            "127.0.0.1 port 1 after 0 ms: Couldn't connect to server"), "network")

    def test_timeout(self):
        self.assertEqual(self.cause(
            "ssh: connect to host h port 22: Connection timed out"), "timeout")
        self.assertEqual(self.cause("timed out after 20s"), "timeout")

    def test_proxy(self):
        self.assertEqual(self.cause(
            "fatal: unable to access 'https://h/': CONNECT tunnel failed, response 403"),
            "proxy")
        self.assertEqual(self.cause(
            "fatal: unable to access 'https://h/': Received HTTP code 407 from proxy after "
            "CONNECT"), "proxy")

    def test_dns_beats_the_generic_could_not_read_suffix(self):
        # Every ssh failure ends with this line, so on its own it names nothing.
        self.assertEqual(self.cause(
            "fatal: Could not read from remote repository.\n\n"
            "Please make sure you have the correct access rights\n"
            "and the repository exists."), "other")

    def test_empty_and_unknown_text_is_other(self):
        self.assertEqual(self.cause(""), "other")
        self.assertEqual(self.cause("something nobody has seen before"), "other")

    def test_matching_is_case_insensitive(self):
        self.assertEqual(self.cause("GIT@H: PERMISSION DENIED (PUBLICKEY)."), "ssh-auth")

    def test_a_missing_host_still_gives_a_readable_hint(self):
        _, hint = doctor.classify_remote_error("Host key verification failed.")
        self.assertIn("<host>", hint)


class RedactTextTestCase(unittest.TestCase):
    """--probe prints git's stderr, and git repeats the URL it dialled."""

    def test_userinfo_password_is_blanked(self):
        self.assertEqual(
            doctor.redact_text("https://user:s3cretpw@host/r.git"),
            "https://user:***@host/r.git",
        )

    def test_password_inside_a_quoted_error_line(self):
        out = doctor.redact_text(
            "fatal: unable to access 'https://user:s3cretpw@host/r.git/': Failed")
        self.assertNotIn("s3cretpw", out)
        self.assertIn("https://user:***@host/r.git/", out)

    def test_url_without_password_is_untouched(self):
        self.assertEqual(
            doctor.redact_text("https://user@host/r.git"), "https://user@host/r.git"
        )

    def test_multiple_urls_on_one_line(self):
        out = doctor.redact_text("a https://u:pw1@h/x and https://v:pw2@k/y b")
        self.assertEqual(out, "a https://u:***@h/x and https://v:***@k/y b")

    def test_a_bare_token_as_userinfo_is_blanked(self):
        out = doctor.redact_text("https://ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/o/r")
        self.assertNotIn("ghp_abcdefghijklmnopqrstuvwxyz0123", out)

    def test_text_without_a_url_is_unchanged(self):
        self.assertEqual(
            doctor.redact_text("plain text, no url\nsecond line"),
            "plain text, no url\nsecond line",
        )


if __name__ == "__main__":
    unittest.main()

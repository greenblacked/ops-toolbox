"""Tests for git/git_remote_doctor.py.

Only the pure parts are covered: URL parsing, insteadOf resolution, credential
helper accumulation and redaction. Nothing here runs git, opens a socket or
looks at the machine's own configuration — the functions all take their input
as a string, which is why they can be tested at all.
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


if __name__ == "__main__":
    unittest.main()

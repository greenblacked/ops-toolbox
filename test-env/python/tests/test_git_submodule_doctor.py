"""Tests for git/git_submodule_doctor.py.

Only the pure parts are covered: the three git output parsers, the URL
classification and the findings built from them. Anything that shells out to
git is left alone; the integration suite builds real superprojects offline.
"""

from __future__ import annotations

import os
import sys
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "git"))

import git_submodule_doctor as doctor  # noqa: E402

NUL = "\x00"


def module(path="lib", url="https://example.com/lib.git", branch=""):
    return {"path": path, "url": url, "branch": branch}


class ParseGitmodulesTestCase(unittest.TestCase):
    TEXT = NUL.join([
        "submodule.lib.path\nlib",
        "submodule.lib.url\n../lib.git",
        "submodule.libs.core.path\nlibs/core dir",
        "submodule.libs.core.url\nhttps://example.com/core.git",
        "submodule.libs.core.branch\nmain",
        "",
    ])

    def test_two_modules(self):
        self.assertEqual(sorted(doctor.parse_gitmodules(self.TEXT)), ["lib", "libs.core"])

    def test_a_name_containing_a_dot(self):
        self.assertEqual(
            doctor.parse_gitmodules(self.TEXT)["libs.core"],
            module("libs/core dir", "https://example.com/core.git", "main"),
        )

    def test_a_module_without_a_branch(self):
        self.assertEqual(doctor.parse_gitmodules(self.TEXT)["lib"]["branch"], "")

    def test_a_trailing_partial_record_is_dropped(self):
        cut = self.TEXT + "submodule.x.path\ntrunc"
        self.assertNotIn("x", doctor.parse_gitmodules(cut))

    def test_empty_text(self):
        self.assertEqual(doctor.parse_gitmodules(""), {})


class ParseGitlinksTestCase(unittest.TestCase):
    TEXT = NUL.join([
        "100644 aaaa 0\tfile.txt",
        "160000 bbbb 0\tlib",
        "160000 cccc 0\tsub dir/x",
        "",
    ])

    def test_only_gitlinks_and_a_path_with_a_space(self):
        self.assertEqual(doctor.parse_gitlinks(self.TEXT), ["lib", "sub dir/x"])

    def test_recorded_commits(self):
        self.assertEqual(
            doctor.parse_gitlink_entries(self.TEXT), {"lib": "bbbb", "sub dir/x": "cccc"}
        )

    def test_empty_text(self):
        self.assertEqual(doctor.parse_gitlinks(""), [])


class ParseSubmoduleStatusTestCase(unittest.TestCase):
    def test_the_four_states(self):
        text = (
            " 1a2b3c4d5e6f lib/core (v1.2.0-3-gabc)\n"
            "-ffff0000 vendor/x\n"
            "+aaaa1111 sub (heads/main)\n"
            "Udeadbeef broken\n"
        )
        self.assertEqual(doctor.parse_submodule_status(text), [
            ("ok", "1a2b3c4d5e6f", "lib/core"),
            ("uninitialized", "ffff0000", "vendor/x"),
            ("changed", "aaaa1111", "sub"),
            ("conflict", "deadbeef", "broken"),
        ])

    def test_a_path_with_spaces_and_parentheses(self):
        self.assertEqual(
            doctor.parse_submodule_status("+bbbb a path (with) spaces (x)\n"),
            [("changed", "bbbb", "a path (with) spaces")],
        )

    def test_empty_text(self):
        self.assertEqual(doctor.parse_submodule_status(""), [])


class ClassifySubmoduleUrlTestCase(unittest.TestCase):
    def test_kinds(self):
        for url, kind in (
            ("../lib.git", "relative"),
            ("./x", "relative"),
            ("git@example.com:o/r", "scp"),
            ("ssh://example.com/r", "ssh"),
            ("https://example.com/r", "https"),
            ("http://example.com/r", "http"),
            ("git://example.com/r", "git"),
            ("file:///srv/r", "file"),
            ("/srv/x", "local"),
            ("", "unknown"),
            ("svn://example.com/r", "unknown"),
        ):
            self.assertEqual(doctor.classify_submodule_url(url), kind, url)


class SubmoduleFindingsTestCase(unittest.TestCase):
    def findings(self, modules, gitlinks=("lib",), statuses=(), local_urls=None,
                 has_origin=True, recorded=None):
        return doctor.submodule_findings(
            modules, list(gitlinks), list(statuses), local_urls or {}, has_origin, recorded
        )

    def test_healthy(self):
        self.assertEqual(
            self.findings({"lib": module()}, statuses=[("ok", "a", "lib")],
                          local_urls={"lib": "https://example.com/lib.git"}),
            [],
        )

    def test_a_gitlink_without_a_mapping_fails(self):
        [(level, message, fix)] = self.findings({})
        self.assertEqual(level, "fail")
        self.assertIn("no submodule mapping found", message)
        self.assertIn("git rm --cached -- lib", fix)

    def test_repair_commands_quote_paths(self):
        path = "my lib"
        [(_, _, fix)] = self.findings({}, gitlinks=(path,))
        self.assertIn("git rm --cached -- 'my lib'", fix)
        [(_, _, fix)] = self.findings(
            {"lib": module(path=path)}, gitlinks=(path,),
            statuses=[("changed", "aaaa", path)], recorded={path: "bbbb"})
        self.assertIn("git add 'my lib' to", fix)
        [(_, _, fix)] = self.findings(
            {"lib": module(path=path)}, gitlinks=(path,),
            statuses=[("conflict", "a", path)])
        self.assertIn("git add 'my lib'", fix)
        self.assertIn("in 'my lib'", fix)

    def test_a_stale_gitmodules_entry_warns(self):
        [(level, _, fix)] = self.findings({"lib": module()}, gitlinks=())
        self.assertEqual(level, "warn")
        self.assertEqual(fix, "git config -f .gitmodules --remove-section submodule.lib")

    def test_not_initialised(self):
        [(level, message, fix)] = self.findings(
            {"lib": module()}, statuses=[("uninitialized", "a", "lib")]
        )
        self.assertEqual(level, "warn")
        self.assertIn("not initialised", message)
        self.assertEqual(fix, "git submodule update --init --recursive")

    def test_a_different_commit_names_both(self):
        [(_, message, fix)] = self.findings(
            {"lib": module()}, statuses=[("changed", "aaaa", "lib")], recorded={"lib": "bbbb"}
        )
        self.assertIn("aaaa", message)
        self.assertIn("bbbb", message)
        self.assertIn("git submodule update", fix)

    def test_a_conflict_fails(self):
        [(level, _, _)] = self.findings({"lib": module()}, statuses=[("conflict", "a", "lib")])
        self.assertEqual(level, "fail")

    def test_url_kinds(self):
        for url, level in (
            ("git://example.com/r", "fail"),
            ("http://example.com/r", "warn"),
            ("/srv/x", "fail"),
            ("file:///srv/x", "fail"),
            ("git@example.com:o/r", "info"),
            ("", "fail"),
        ):
            findings = self.findings({"lib": module(url=url)})
            self.assertEqual([f[0] for f in findings], [level], url)

    def test_a_local_path_explains_why(self):
        [(_, message, _)] = self.findings({"lib": module(url="/srv/x")})
        self.assertIn("one machine", message)

    def test_a_relative_url_with_an_origin_is_fine(self):
        self.assertEqual(self.findings({"lib": module(url="../lib.git")}), [])

    def test_a_relative_url_without_an_origin_warns(self):
        findings = self.findings({"lib": module(url="../lib.git")}, has_origin=False)
        self.assertEqual([f[0] for f in findings], ["warn"])

    def test_drift_names_the_sync(self):
        [(level, _, fix)] = self.findings(
            {"lib": module()}, local_urls={"lib": "https://old.example.com/lib.git"}
        )
        self.assertEqual(level, "warn")
        self.assertEqual(fix, "git submodule sync --recursive")

    def test_drift_compares_absolute_urls_only(self):
        self.assertEqual(
            self.findings({"lib": module(url="../lib.git")},
                          local_urls={"lib": "https://example.com/lib.git"}),
            [],
        )

    def test_passwords_never_reach_a_message(self):
        findings = self.findings(
            {"lib": module(url="https://u:newpw@example.com/r")},
            local_urls={"lib": "https://u:oldpw@example.com/q"},
        )
        text = " ".join(message for _, message, _ in findings)
        self.assertNotIn("newpw", text)
        self.assertNotIn("oldpw", text)


if __name__ == "__main__":
    unittest.main()

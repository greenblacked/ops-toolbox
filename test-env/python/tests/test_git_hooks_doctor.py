"""Tests for git/git_hooks_doctor.py.

Only the pure parts are covered: hook-name near misses, shebang parsing and
judgement, core.hooksPath and the hook-manager checks. Anything that lists a
hooks directory or asks git is left alone; the integration suite drives it
against real repositories. PATH lookups and directory existence are passed in
as callables, so nothing here depends on the machine running it.
"""

from __future__ import annotations

import os
import sys
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "git"))

import git_hooks_doctor as doctor  # noqa: E402


def found(name):
    return "/usr/bin/" + os.path.basename(name)


def missing(_name):
    return None


class NearMissTestCase(unittest.TestCase):
    def test_suffixes_separators_and_case(self):
        for given, meant in (
            ("pre-commit.sh", "pre-commit"),
            ("precommit", "pre-commit"),
            ("pre_commit", "pre-commit"),
            ("commitmsg", "commit-msg"),
            ("pre-push.bak", "pre-push"),
            ("Pre-Commit", "pre-commit"),
            ("pre-comit", "pre-commit"),
        ):
            self.assertEqual(doctor.near_miss(given), meant, given)

    def test_an_exact_hook_name_is_not_a_near_miss(self):
        self.assertIsNone(doctor.near_miss("pre-commit"))

    def test_unrelated_names(self):
        self.assertIsNone(doctor.near_miss("README.md"))
        self.assertIsNone(doctor.near_miss("notes"))
        self.assertIsNone(doctor.near_miss("helpers.sh"))


class ParseShebangTestCase(unittest.TestCase):
    def test_the_common_shapes(self):
        self.assertEqual(doctor.parse_shebang(b"#!/bin/sh\n"), ("/bin/sh", [], False))
        self.assertEqual(
            doctor.parse_shebang(b"#!/usr/bin/env bash\n"), ("/usr/bin/env", ["bash"], False)
        )
        self.assertEqual(
            doctor.parse_shebang(b"#! /bin/bash -e\n"), ("/bin/bash", ["-e"], False)
        )

    def test_crlf(self):
        self.assertEqual(doctor.parse_shebang(b"#!/bin/sh\r\n"), ("/bin/sh", [], True))
        self.assertEqual(
            doctor.parse_shebang(b"#!/usr/bin/env bash\r\n"), ("/usr/bin/env", ["bash"], True)
        )

    def test_no_shebang(self):
        self.assertEqual(doctor.parse_shebang(b"echo hi\n"), (None, [], False))
        self.assertEqual(doctor.parse_shebang(b""), (None, [], False))

    def test_a_bare_hash_bang(self):
        self.assertEqual(doctor.parse_shebang(b"#!\n"), ("", [], False))

    def test_a_byte_order_mark_hides_the_shebang(self):
        self.assertEqual(doctor.parse_shebang(b"\xef\xbb\xbf#!/bin/sh\n"), (None, [], False))


class ShebangFindingsTestCase(unittest.TestCase):
    def test_crlf_fails_and_prints_a_repair_that_keeps_a_backup(self):
        [(level, message, fix)] = doctor.shebang_findings(
            b"#!/usr/bin/env bash\r\n", found, ".git/hooks/pre-commit"
        )
        self.assertEqual(level, "fail")
        self.assertIn("carriage return", message)
        self.assertIn("bash\\r", message)
        self.assertIn("-pi.bak", fix)
        self.assertIn(".git/hooks/pre-commit", fix)

    def test_a_missing_absolute_interpreter_fails(self):
        [(level, message, _)] = doctor.shebang_findings(b"#!/opt/x/bin/tool\n", missing)
        self.assertEqual(level, "fail")
        self.assertIn("/opt/x/bin/tool", message)

    def test_env_with_a_program_not_on_path_fails(self):
        [(level, message, _)] = doctor.shebang_findings(b"#!/usr/bin/env node\n", missing)
        self.assertEqual(level, "fail")
        self.assertIn("node", message)

    def test_env_options_are_skipped(self):
        self.assertEqual(doctor.shebang_findings(b"#!/usr/bin/env -S node --x\n", found), [])

    def test_no_shebang_warns(self):
        [(level, _, _)] = doctor.shebang_findings(b"exit 0\n", found)
        self.assertEqual(level, "warn")

    def test_a_relative_interpreter_warns(self):
        [(level, _, _)] = doctor.shebang_findings(b"#!bash\n", found)
        self.assertEqual(level, "warn")

    def test_a_good_shebang_has_nothing_to_say(self):
        self.assertEqual(doctor.shebang_findings(b"#!/bin/bash\n", found), [])


class HooksPathFindingsTestCase(unittest.TestCase):
    def test_unset_is_nothing(self):
        self.assertEqual(
            doctor.hooks_path_findings("", "", "", "/r", ["pre-commit"], lambda p: False), []
        )

    def test_a_relative_path_resolves_against_the_work_tree(self):
        seen = []

        def exists(path):
            seen.append(path)
            return True

        self.assertEqual(
            doctor.hooks_path_findings(".githooks", ".git/config", "local", "/r", [], exists),
            [],
        )
        self.assertEqual(seen, ["/r/.githooks"])

    def test_a_missing_directory_fails(self):
        [(level, message, fix)] = doctor.hooks_path_findings(
            "hooks", ".git/config", "local", "/r", [], lambda p: False
        )
        self.assertEqual(level, "fail")
        self.assertIn("does not exist", message)
        self.assertIn("runs NO hooks", message)
        self.assertIn("mkdir -p /r/hooks", fix)

    def test_a_missing_global_directory_names_the_global_unset(self):
        [(_, _, fix)] = doctor.hooks_path_findings(
            "/gone", "~/.gitconfig", "global", "/r", [], lambda p: False
        )
        self.assertIn("git config --global --unset core.hooksPath", fix)

    def test_a_global_path_shadows_local_hooks(self):
        [(level, message, _)] = doctor.hooks_path_findings(
            "/g", "~/.gitconfig", "global", "/r", ["pre-commit"], lambda p: True
        )
        self.assertEqual(level, "warn")
        self.assertIn("never run", message)
        self.assertIn("pre-commit", message)

    def test_a_local_path_that_exists_is_fine(self):
        self.assertEqual(
            doctor.hooks_path_findings(
                ".githooks", ".git/config", "local", "/r", ["pre-commit"], lambda p: True
            ),
            [],
        )


class FrameworkFindingsTestCase(unittest.TestCase):
    PRE_COMMIT_HOOK = {"pre-commit": "# File generated by pre-commit: https://pre-commit.com"}

    def levels(self, findings):
        return [level for level, _, _ in findings]

    def test_pre_commit_config_without_the_framework_installed(self):
        [(level, _, fix)] = doctor.framework_findings({".pre-commit-config.yaml"}, "", {})
        self.assertEqual(level, "warn")
        self.assertEqual(fix, "pre-commit install")

    def test_pre_commit_installed(self):
        self.assertEqual(
            doctor.framework_findings({".pre-commit-config.yaml"}, "", self.PRE_COMMIT_HOOK),
            [],
        )

    def test_pre_commit_cannot_install_under_a_hooks_path(self):
        findings = doctor.framework_findings({".pre-commit-config.yaml"}, ".githooks", {})
        self.assertEqual(self.levels(findings), ["warn", "info"])
        self.assertIn("--unset-all core.hooksPath", findings[1][1])

    def test_husky(self):
        self.assertEqual(self.levels(doctor.framework_findings({".husky"}, "", {})), ["warn"])
        self.assertEqual(doctor.framework_findings({".husky"}, ".husky/_/", {}), [])
        self.assertEqual(doctor.framework_findings({".husky"}, ".husky", {}), [])

    def test_githooks(self):
        [(level, _, fix)] = doctor.framework_findings({".githooks"}, "", {})
        self.assertEqual(level, "warn")
        self.assertEqual(fix, "git config core.hooksPath .githooks")
        self.assertEqual(doctor.framework_findings({".githooks"}, ".githooks", {}), [])

    def test_lefthook(self):
        self.assertEqual(
            self.levels(doctor.framework_findings({"lefthook.yml"}, "", {})), ["warn"]
        )
        self.assertEqual(
            doctor.framework_findings(
                {"lefthook.yml"}, "", {"pre-commit": "lefthook run pre-commit"}
            ),
            [],
        )

    def test_no_framework(self):
        self.assertEqual(doctor.framework_findings(set(), "", {}), [])


if __name__ == "__main__":
    unittest.main()

"""Tests for git/git_hooks_doctor.py.

Mostly the pure parts: hook-name near misses, shebang parsing and judgement,
core.hooksPath and the hook-manager checks. PATH lookups and directory
existence are passed in as callables, so nothing here depends on the machine
running it. The one report-level test (a linked worktree) stubs the git
queries and builds its directories under a temporary one; the integration
suite drives the whole tool against real repositories.
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import unittest
from unittest import mock

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

    def test_env_with_several_words_and_no_split_flag_fails(self):
        [(level, message, fix)] = doctor.shebang_findings(b"#!/usr/bin/env python3 -u\n", found)
        self.assertEqual(level, "fail")
        self.assertIn("without -S", message)
        self.assertEqual(fix, "#!/usr/bin/env -S python3 -u")

    def test_env_with_an_option_before_the_program_needs_split_too(self):
        [(level, _, fix)] = doctor.shebang_findings(b"#!/usr/bin/env -i python3\n", found)
        self.assertEqual(level, "fail")
        self.assertEqual(fix, "#!/usr/bin/env -S -i python3")

    def test_repair_paths_with_a_space_are_quoted(self):
        [(_, _, fix)] = doctor.shebang_findings(
            b"#!/bin/sh\r\n", found, "/my repo/.git/hooks/pre-commit"
        )
        self.assertIn("'/my repo/.git/hooks/pre-commit'", fix)
        [(_, _, fix)] = doctor.hooks_path_findings(
            "/my repo/hooks", ".git/config", "local", "/r", [], lambda p: False
        )
        self.assertIn("mkdir -p '/my repo/hooks'", fix)

    def test_a_direct_interpreter_with_several_arguments_warns(self):
        [(level, message, fix)] = doctor.shebang_findings(
            b"#!/usr/bin/python3 -u -B\n", found
        )
        self.assertEqual(level, "warn")
        self.assertIn("ONE word", message)
        self.assertIn("-u -B", message)
        self.assertEqual(fix, "use a single option, or #!/usr/bin/env -S python3 -u -B")

    def test_a_direct_interpreter_with_one_argument_is_fine(self):
        self.assertEqual(doctor.shebang_findings(b"#!/bin/bash -e\n", found), [])

    def test_env_options_are_skipped(self):
        self.assertEqual(doctor.shebang_findings(b"#!/usr/bin/env -S node --x\n", found), [])

    def test_env_split_string_with_the_program_attached_is_accepted(self):
        for line in (
            b"#!/usr/bin/env --split-string=python3 -u\n",
            b"#!/usr/bin/env --split-string python3 -u\n",
            b"#!/usr/bin/env -Spython3 -u\n",
            b"#!/usr/bin/env -S python3 -u\n",
        ):
            with self.subTest(line=line):
                self.assertEqual(doctor.shebang_findings(line, found), [])

    def test_env_split_string_still_checks_the_program(self):
        [(level, message, _)] = doctor.shebang_findings(
            b"#!/usr/bin/env --split-string=node --x\n", missing
        )
        self.assertEqual(level, "fail")
        self.assertIn("node", message)

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

    def test_a_relative_path_is_also_resolved_from_the_git_dir(self):
        seen = []

        def exists(path):
            seen.append(path)
            return True

        self.assertEqual(
            doctor.hooks_path_findings(
                ".githooks", ".git/config", "local", "/r", [], exists, "/r/.git"
            ),
            [],
        )
        self.assertEqual(seen, ["/r/.githooks", "/r/.git/.githooks"])

    def test_a_missing_client_directory_names_the_work_tree_root(self):
        [(level, message, fix)] = doctor.hooks_path_findings(
            "hooks", ".git/config", "local", "/r", [], lambda p: p == "/r/.git/hooks",
            "/r/.git"
        )
        self.assertEqual(level, "fail")
        self.assertIn("for client hooks (read from the work tree root)", message)
        self.assertIn("mkdir -p /r/hooks", fix)

    def test_a_missing_receive_side_directory_is_information(self):
        [(level, message, fix)] = doctor.hooks_path_findings(
            "hooks", ".git/config", "local", "/r", [], lambda p: p == "/r/hooks",
            "/r/.git"
        )
        self.assertEqual(level, "info")
        self.assertIn("$GIT_DIR, /r/.git/hooks, which does not exist", message)
        self.assertIn("pre-receive", message)
        self.assertIn("reference-transaction", message)
        self.assertIn("mkdir -p /r/.git/hooks", fix)

    def test_a_missing_receive_side_directory_keeps_the_shadow_warning(self):
        findings = doctor.hooks_path_findings(
            ".githooks", "~/.gitconfig", "global", "/r", ["pre-commit"],
            lambda p: p == "/r/.githooks", "/r/.git"
        )
        self.assertEqual([level for level, _, _ in findings], ["info", "warn"])
        self.assertIn("never run", findings[1][1])
        self.assertIn("pre-commit", findings[1][1])

    def test_receive_hooks_dir_uses_the_given_common_directory(self):
        self.assertEqual(
            doctor.receive_hooks_dir("hooks", "/wt", "/main/.git"), "/main/.git/hooks"
        )

    def test_one_receive_location_without_a_linked_worktree(self):
        self.assertEqual(
            doctor.receive_locations("hooks", "/r", "/r/.git", "/r/.git"),
            [(None, "/r/.git/hooks")],
        )
        self.assertEqual(doctor.receive_locations("/h", "/r", "/r/.git", "/r/.git"), [])

    def test_a_linked_worktree_has_a_receive_location_per_push_target(self):
        with mock.patch.object(doctor, "HOME", "/nonexistent-home"):
            self.assertEqual(
                doctor.receive_locations(
                    "hooks", "/wt", "/main/.git", "/main/.git/worktrees/wt"
                ),
                [
                    ("push to /main", "/main/.git/hooks"),
                    ("push to this worktree's path", "/main/.git/worktrees/wt/hooks"),
                ],
            )

    def test_each_missing_receive_location_is_reported_with_its_push_target(self):
        with mock.patch.object(doctor, "HOME", "/nonexistent-home"):
            findings = doctor.hooks_path_findings(
                "hooks", ".git/config", "local", "/wt", [], lambda p: p == "/wt/hooks",
                "/main/.git", "/main/.git/worktrees/wt"
            )
        self.assertEqual([level for level, _, _ in findings], ["info", "info"])
        self.assertIn("for a push to /main the", findings[0][1])
        self.assertIn("/main/.git/hooks, which does not exist", findings[0][1])
        self.assertIn("for a push to this worktree's path the", findings[1][1])
        self.assertIn("/main/.git/worktrees/wt/hooks, which does not exist", findings[1][1])
        self.assertIn("mkdir -p /main/.git/worktrees/wt/hooks", findings[1][2])

    def test_an_absolute_path_has_one_location(self):
        seen = []

        def exists(path):
            seen.append(path)
            return True

        doctor.hooks_path_findings("/h", ".git/config", "local", "/r", [], exists, "/r/.git")
        self.assertEqual(seen, ["/h"])

    def test_a_bare_repository_has_one_location(self):
        self.assertIsNone(doctor.receive_hooks_dir("hooks", "/r.git", "/r.git"))

    def test_receive_hooks_dir_for_a_work_tree(self):
        self.assertEqual(doctor.receive_hooks_dir("hooks", "/r", "/r/.git"), "/r/.git/hooks")
        self.assertIsNone(doctor.receive_hooks_dir("/h", "/r", "/r/.git"))

    def test_receive_side_hooks_are_all_known_hook_names(self):
        self.assertTrue(doctor.RECEIVE_HOOKS <= doctor.HOOK_NAMES)

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

    def test_pre_commit_marker_must_be_the_whole_line(self):
        cfg = {".pre-commit-config.yaml"}
        lookalike = {"pre-commit": "echo see https://pre-commit.com for docs"}
        self.assertEqual(self.levels(doctor.framework_findings(cfg, "", lookalike)), ["warn"])
        indented = {
            "pre-commit": "#!/bin/sh\n  # File generated by pre-commit: https://pre-commit.com  \n"
        }
        self.assertEqual(doctor.framework_findings(cfg, "", indented), [])

    def test_pre_commit_entry_point_counts(self):
        hook = {"pre-commit": 'exec python -m pre_commit hook-impl'}
        self.assertEqual(doctor.framework_findings({".pre-commit-config.yaml"}, "", hook), [])

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


class LinkedWorktreeReportTestCase(unittest.TestCase):
    """run_report with git's answers stubbed, over real temporary directories."""

    def report(self, root, git_dir):
        main_git = os.path.join(root, "main", ".git")
        worktree = os.path.join(root, "wt")
        answers = {
            "--absolute-git-dir": git_dir,
            "--git-common-dir": main_git,
        }
        os.makedirs(os.path.join(worktree, "hooks"))
        os.makedirs(os.path.join(main_git, "hooks"))
        for directory in (os.path.join(worktree, "hooks"), os.path.join(main_git, "hooks")):
            hook = os.path.join(directory, "pre-receive")
            with open(hook, "w") as handle:
                handle.write("#!/bin/sh\nexit 0\n")
            os.chmod(hook, 0o755)
        transaction = os.path.join(worktree, "hooks", "reference-transaction")
        with open(transaction, "w") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        os.chmod(transaction, 0o755)
        out = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(doctor, "HOME", "/nonexistent-home"))
            stack.enter_context(mock.patch.object(
                doctor, "git_path", side_effect=lambda *a: answers.get(a[0])))
            stack.enter_context(mock.patch.object(
                doctor, "run", return_value=(0, worktree + "\n", "")))
            stack.enter_context(mock.patch.object(
                doctor, "hooks_path_config", return_value=("hooks", ".git/config", "local")))
            stack.enter_context(contextlib.redirect_stdout(out))
            doctor.run_report(None)
        return out.getvalue(), main_git

    def test_a_linked_worktree_reports_both_receive_side_locations(self):
        with tempfile.TemporaryDirectory() as root:
            private = os.path.join(root, "main", ".git", "worktrees", "wt")
            text, main_git = self.report(root, private)
        main_path = os.path.dirname(main_git)
        self.assertIn("$GIT_DIR (push to %s) -> %s" % (main_path, main_git + "/hooks"), text)
        self.assertIn(
            "$GIT_DIR (push to this worktree's path) -> %s" % (private + "/hooks"), text
        )
        self.assertIn("never runs: it only runs when this repository receives a push", text)
        self.assertIn(
            "runs here for local ref updates only; for a push into this repository "
            "Git looks in %s for a push to %s; " % (main_git + "/hooks", main_path),
            text,
        )
        self.assertIn("for a push to %s" % main_path, text)
        self.assertIn("for a push to this worktree's path", text)
        self.assertIn(
            "pre-receive (receive-side, in %s, push to %s)" % (main_git + "/hooks", main_path),
            text,
        )
        self.assertIn("%s, which does not exist" % (private + "/hooks"), text)

    def test_a_plain_repository_names_one_receive_side_location(self):
        with tempfile.TemporaryDirectory() as root:
            text, main_git = self.report(root, os.path.join(root, "main", ".git"))
        self.assertIn("$GIT_DIR -> %s" % (main_git + "/hooks"), text)
        self.assertNotIn("this worktree's path", text)
        self.assertNotIn("(push to", text)


if __name__ == "__main__":
    unittest.main()

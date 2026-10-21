"""Tests for git/git_fleet_doctor.py.

Only the pure parts are covered: which files are doctors, what an exit code
means in the table, how repositories are found under a root, and how the
table and the overall verdict are put together. The repository walk is
tested against a temporary directory tree; running the doctors is left to the
integration suite, which does it for real.
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

import git_fleet_doctor as doctor  # noqa: E402


class DoctorKeyTestCase(unittest.TestCase):
    def test_doctors(self):
        self.assertEqual(doctor.doctor_key("git_ssh_doctor.py"), "ssh")
        self.assertEqual(doctor.doctor_key("git_remote_doctor.py"), "remote")

    def test_the_driver_never_runs_itself(self):
        self.assertIsNone(doctor.doctor_key("git_fleet_doctor.py"))

    def test_other_names(self):
        for name in ("git_ssh_doctor.pyc", "git_doctor.py", "other_doctor.py",
                     "git_x_y_doctor.py", "git_ssh_doctor.py.bak"):
            self.assertIsNone(doctor.doctor_key(name), name)


class VerdictTestCase(unittest.TestCase):
    def test_codes(self):
        self.assertEqual(doctor.verdict(0, False), "ok")
        self.assertEqual(doctor.verdict(1, False), "FAIL")
        self.assertEqual(doctor.verdict(4, False), "n/a")

    def test_a_doctor_that_did_not_run_is_an_error_not_a_finding(self):
        for rc in (2, 3, 255, -9):
            self.assertEqual(doctor.verdict(rc, False), "ERR", rc)

    def test_a_timeout_wins_over_the_code(self):
        self.assertEqual(doctor.verdict(0, True), "TIME")
        self.assertEqual(doctor.verdict(1, True), "TIME")


class WalkReposTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def repo(self, relative, git="dir"):
        path = os.path.join(self.root, relative)
        os.makedirs(path, exist_ok=True)
        if git == "dir":
            os.makedirs(os.path.join(path, ".git"))
        elif git == "file":
            with open(os.path.join(path, ".git"), "w") as handle:
                handle.write("gitdir: /elsewhere\n")
        return path

    def test_finds_repositories_and_skips_what_it_should(self):
        a = self.repo("a")
        b = self.repo("b", git="file")  # a linked worktree or a submodule
        d = self.repo("c/plain/d")
        self.repo("node_modules/x")
        self.repo("a/nested")  # inside a repository: not searched
        self.repo("archive/old")
        self.assertEqual(doctor.walk_repos(self.root, 3, ["archive/*"]), sorted([a, b, d]))

    def test_depth_is_respected(self):
        deep = self.repo("deep/1/2/3")
        self.assertNotIn(deep, doctor.walk_repos(self.root, 3, []))
        self.assertIn(deep, doctor.walk_repos(self.root, 4, []))

    def test_a_symlinked_directory_is_not_followed(self):
        target = self.repo("real")
        link = os.path.join(self.root, "link")
        try:
            os.symlink(target, link)
        except (OSError, NotImplementedError):
            self.skipTest("this platform cannot create a symlink here")
        self.assertEqual(doctor.walk_repos(self.root, 3, []), [target])

    def test_a_root_that_is_a_repository_is_returned(self):
        a = self.repo("a")
        self.assertEqual(doctor.walk_repos(a, 3, []), [a])

    def test_an_empty_root(self):
        self.assertEqual(doctor.walk_repos(self.root, 3, []), [])


class RenderTableTestCase(unittest.TestCase):
    ROWS = [
        ("clean", {"ignore": "ok", "remote": "n/a"}),
        ("claimed", {"ignore": "FAIL", "remote": "ok"}),
        ("broken", {"ignore": "ERR"}),
    ]

    def test_header_and_sorted_columns(self):
        lines = doctor.render_table(self.ROWS, ["remote", "ignore"]).splitlines()
        self.assertEqual(lines[0].split(), ["repo", "ignore", "remote"])

    def test_cells_line_up_under_their_heading(self):
        lines = doctor.render_table(self.ROWS, ["remote", "ignore"]).splitlines()
        self.assertEqual(lines[2].index("FAIL"), lines[0].index("ignore"))
        self.assertEqual(lines[1].index("n/a"), lines[0].index("remote"))

    def test_a_doctor_that_did_not_run_shows_a_dash(self):
        lines = doctor.render_table(self.ROWS, ["remote", "ignore"]).splitlines()
        self.assertTrue(lines[3].endswith("-"))

    def test_summary_counts(self):
        last = doctor.render_table(self.ROWS, ["remote", "ignore"]).splitlines()[-1]
        self.assertEqual(last, "3 repo(s): 1 clean, 1 with findings, 1 errors")


class RepoLabelsTestCase(unittest.TestCase):
    def test_relative_to_the_common_parent(self):
        self.assertEqual(
            doctor.repo_labels(["/r/x", "/r/y/z"]), {"/r/x": "x", "/r/y/z": "y/z"}
        )

    def test_a_single_repository_is_its_own_name(self):
        self.assertEqual(doctor.repo_labels(["/r/x"]), {"/r/x": "x"})


class OverallExitTestCase(unittest.TestCase):
    def test_all_ok(self):
        self.assertEqual(doctor.overall_exit([("a", {"x": "ok", "y": "n/a"})]), 0)

    def test_one_failure(self):
        self.assertEqual(doctor.overall_exit([("a", {"x": "FAIL"})]), 1)

    def test_a_failure_outranks_an_error(self):
        self.assertEqual(doctor.overall_exit([("a", {"x": "FAIL"}), ("b", {"x": "ERR"})]), 1)

    def test_errors_and_timeouts(self):
        self.assertEqual(doctor.overall_exit([("a", {"x": "ERR"})]), 2)
        self.assertEqual(doctor.overall_exit([("a", {"x": "TIME"})]), 2)

    def test_no_rows(self):
        self.assertEqual(doctor.overall_exit([]), 4)


if __name__ == "__main__":
    unittest.main()

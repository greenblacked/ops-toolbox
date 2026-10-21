"""Tests for git/git_health_doctor.py.

Only the pure parts are covered: the count-objects parser, the lock verdicts,
the object thresholds and the gc.log excerpt. Anything that stats a repository
or reads the process table is left alone; the clock is injected, so nothing
here depends on the day it runs.

The lock tests are the ones that matter. Removing index.lock under a live git
command breaks the command, so "old" alone must never be enough for the fail
verdict, and a process table that cannot be read must never count as empty.
"""

from __future__ import annotations

import os
import sys
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "git"))

import git_health_doctor as doctor  # noqa: E402

NOW = 1_700_000_000

COUNT_OBJECTS = """count: 7012
size: 28044
in-pack: 120345
packs: 3
size-pack: 51234
prune-packable: 4
garbage: 1
size-garbage: 12
"""


class ParseCountObjectsTestCase(unittest.TestCase):
    def test_all_eight_keys(self):
        self.assertEqual(
            doctor.parse_count_objects(COUNT_OBJECTS),
            {
                "count": 7012,
                "size": 28044,
                "in-pack": 120345,
                "packs": 3,
                "size-pack": 51234,
                "prune-packable": 4,
                "garbage": 1,
                "size-garbage": 12,
            },
        )

    def test_missing_keys_are_absent_not_zero(self):
        counts = doctor.parse_count_objects("count: 3\npacks: 1\n")
        self.assertEqual(counts, {"count": 3, "packs": 1})
        self.assertNotIn("garbage", counts)

    def test_a_line_without_a_colon_is_ignored(self):
        self.assertEqual(doctor.parse_count_objects("count: 3\nnot a line\n"), {"count": 3})

    def test_a_non_integer_value_is_ignored(self):
        self.assertEqual(doctor.parse_count_objects("count: 3\npacks: many\n"), {"count": 3})

    def test_an_unknown_key_is_ignored(self):
        # count-objects names garbage files on stderr as "warning: garbage
        # found: PATH"; merged into the same text it must not become a key.
        text = "count: 3\nwarning: garbage found: /r/.git/objects/pack/tmp_x\n"
        self.assertEqual(doctor.parse_count_objects(text), {"count": 3})

    def test_empty_text(self):
        self.assertEqual(doctor.parse_count_objects(""), {})


class ClassifyLocksTestCase(unittest.TestCase):
    LOCK = "/r/.git/index.lock"

    def test_old_lock_and_no_git_is_a_failure_with_the_rm(self):
        [(level, message, fix)] = doctor.classify_locks(
            [(self.LOCK, NOW - 42 * 60)], NOW, 10, False
        )
        self.assertEqual(level, "fail")
        self.assertIn("42 min", message)
        self.assertIn("no git process is running", message)
        self.assertIn("rm -- /r/.git/index.lock", fix)

    def test_old_lock_with_git_running_only_warns(self):
        [(level, _, fix)] = doctor.classify_locks(
            [(self.LOCK, NOW - 42 * 60)], NOW, 10, True
        )
        self.assertEqual(level, "warn")
        self.assertNotIn("rm --", fix)

    def test_unknown_process_table_never_fails(self):
        [(level, _, fix)] = doctor.classify_locks(
            [(self.LOCK, NOW - 42 * 60)], NOW, 10, None
        )
        self.assertEqual(level, "warn")
        self.assertIn("only after confirming", fix)

    def test_unattributed_git_process_warns_and_never_fails(self):
        [(level, message, fix)] = doctor.classify_locks(
            [(self.LOCK, NOW - 42 * 60)], NOW, 10, doctor.UNATTRIBUTED
        )
        self.assertEqual(level, "warn")
        self.assertIn("running somewhere", message)
        self.assertIn("cannot tell whether it owns this lock", message)
        self.assertIn("only after confirming", fix)

    def test_a_two_minute_old_lock_is_information(self):
        [(level, message, fix)] = doctor.classify_locks(
            [(self.LOCK, NOW - 120)], NOW, 10, False
        )
        self.assertEqual(level, "info")
        self.assertIn("mid-flight", message)
        self.assertIsNone(fix)

    def test_exactly_at_the_threshold_is_stale(self):
        [(level, _, _)] = doctor.classify_locks([(self.LOCK, NOW - 600)], NOW, 10, False)
        self.assertEqual(level, "fail")

    def test_a_lock_from_the_future_is_recent(self):
        [(level, message, _)] = doctor.classify_locks(
            [(self.LOCK, NOW + 600)], NOW, 10, False
        )
        self.assertEqual(level, "info")
        self.assertIn("0 min", message)

    def test_a_path_with_a_space_is_quoted_in_the_fix(self):
        [(_, _, fix)] = doctor.classify_locks(
            [("/my repo/.git/index.lock", NOW - 3600)], NOW, 10, False
        )
        self.assertIn("rm -- '/my repo/.git/index.lock'", fix)

    def test_empty_list(self):
        self.assertEqual(doctor.classify_locks([], NOW, 10, False), [])


class ObjectFindingsTestCase(unittest.TestCase):
    def test_loose_objects_above_gc_auto_warn(self):
        [(level, message, fix)] = doctor.object_findings({"count": 7000}, 6700, 50, False)
        self.assertEqual(level, "warn")
        self.assertIn("above gc.auto (6700)", message)
        self.assertEqual(fix, "git gc")

    def test_loose_objects_at_gc_auto_are_fine(self):
        self.assertEqual(doctor.object_findings({"count": 6700}, 6700, 50, False), [])

    def test_packs_above_the_limit_warn(self):
        [(level, _, fix)] = doctor.object_findings({"packs": 51}, 6700, 50, False)
        self.assertEqual(level, "warn")
        self.assertEqual(fix, "git repack -ad")

    def test_packs_at_the_limit_are_fine(self):
        self.assertEqual(doctor.object_findings({"packs": 50}, 6700, 50, False), [])

    def test_a_pack_limit_of_zero_disables_the_check(self):
        self.assertEqual(doctor.object_findings({"packs": 500}, 6700, 0, False), [])

    def test_garbage_warns_and_names_git_prune(self):
        [(level, message, fix)] = doctor.object_findings(
            {"garbage": 2, "size-garbage": 8}, 6700, 50, False
        )
        self.assertEqual(level, "warn")
        self.assertIn("2 garbage file(s) (8 KiB)", message)
        self.assertIn("git prune", fix)

    def test_a_custom_gc_auto(self):
        [(level, message, _)] = doctor.object_findings({"count": 101}, 100, 50, False)
        self.assertEqual(level, "warn")
        self.assertIn("gc.auto (100)", message)

    def test_disabled_gc_reports_context_not_a_missed_run(self):
        findings = doctor.object_findings({"count": 9000, "packs": 80}, 6700, 50, True)
        self.assertEqual([f[0] for f in findings], ["info"])
        self.assertIn("disabled", findings[0][1])
        self.assertNotIn("above gc.auto", findings[0][1])

    def test_a_large_pack_points_at_the_size_report(self):
        [(level, message, _)] = doctor.object_findings(
            {"size-pack": 600 * 1024}, 6700, 50, False
        )
        self.assertEqual(level, "info")
        self.assertIn("git_size_report.sh", message)

    def test_a_healthy_repository_has_nothing_to_say(self):
        self.assertEqual(
            doctor.object_findings(doctor.parse_count_objects("count: 3\npacks: 1\n"),
                                   6700, 50, False),
            [],
        )


class ParseGcLogTestCase(unittest.TestCase):
    def test_caps_at_three_lines_and_skips_blanks(self):
        self.assertEqual(doctor.parse_gc_log("\n a \n\nb\nc\nd\n"), ["a", "b", "c"])

    def test_empty_text(self):
        self.assertEqual(doctor.parse_gc_log(""), [])


class GcLogExpiryTestCase(unittest.TestCase):
    DAY = 86400

    def test_common_forms(self):
        parse = doctor.parse_expiry_seconds
        self.assertEqual(parse("1.day"), self.DAY)
        self.assertEqual(parse("3.days"), 3 * self.DAY)
        self.assertEqual(parse("2.weeks.ago"), 14 * self.DAY)
        self.assertEqual(parse("12 hours"), 12 * 3600)
        self.assertEqual(parse("now"), 0)

    def test_never_and_unknown_forms_never_expire(self):
        for text in ("never", "", "yesterday", "soon.ish", "-1.day"):
            self.assertIsNone(doctor.parse_expiry_seconds(text), text)

    def test_a_fresh_log_blocks(self):
        self.assertTrue(doctor.gc_log_blocks(3600, self.DAY))

    def test_an_expired_log_does_not_block(self):
        self.assertFalse(doctor.gc_log_blocks(self.DAY + 1, self.DAY))
        self.assertFalse(doctor.gc_log_blocks(self.DAY, self.DAY))
        self.assertFalse(doctor.gc_log_blocks(0, 0))

    def test_never_always_blocks(self):
        self.assertTrue(doctor.gc_log_blocks(10 * 365 * self.DAY, None))


class ProcessNamesTestCase(unittest.TestCase):
    def test_paths_and_names_reduce_to_basenames(self):
        self.assertEqual(
            doctor.parse_process_names("/usr/bin/git\n bash\n\n"), ["git", "bash"]
        )

    def test_only_git_itself_counts_as_running(self):
        self.assertTrue(doctor.git_is_running(["bash", "git"]))
        self.assertFalse(doctor.git_is_running(["gitk", "git-lfs", "git-credential-cache"]))


class AttributeGitProcessesTestCase(unittest.TestCase):
    REPO = "/srv/repo"
    PATHS = ["/srv/repo", "/srv/repo/.git", "/srv/wt-b"]

    def attribute(self, procs):
        return doctor.attribute_git_processes(procs, self.PATHS)

    def test_no_git_process_is_false(self):
        self.assertIs(self.attribute([]), False)

    def test_an_unrelated_git_does_not_count(self):
        self.assertIs(self.attribute([("/home/me/other", None, None)]), False)

    def test_a_sibling_directory_with_the_same_prefix_does_not_count(self):
        self.assertIs(self.attribute([("/srv/repo-two", None, None)]), False)

    def test_cwd_inside_the_worktree_counts(self):
        self.assertIs(self.attribute([("/srv/repo/src/deep", None, None)]), True)

    def test_cwd_in_a_linked_worktree_counts(self):
        self.assertIs(self.attribute([("/srv/wt-b", None, None)]), True)

    def test_git_dir_from_the_environment_counts(self):
        self.assertIs(self.attribute([("/tmp", "/srv/repo/.git", None)]), True)

    def test_relative_git_dir_resolves_against_the_cwd(self):
        self.assertIs(self.attribute([("/srv/repo", ".git", None)]), True)

    def test_work_tree_from_the_environment_counts(self):
        self.assertIs(self.attribute([("/tmp", None, "/srv/repo")]), True)

    def test_an_unreadable_cwd_is_unattributed_not_a_match(self):
        self.assertEqual(
            self.attribute([("/home/me/other", None, None), (None, None, None)]),
            doctor.UNATTRIBUTED,
        )

    def test_a_match_wins_over_an_unreadable_process(self):
        self.assertIs(self.attribute([(None, None, None), ("/srv/repo", None, None)]), True)

    def test_git_dir_option_from_the_command_line_counts(self):
        self.assertIs(
            self.attribute([("/tmp", None, None,
                             ["--git-dir=/srv/repo/.git", "fetch"])]), True)

    def test_git_dir_option_with_a_separate_value_counts(self):
        self.assertIs(
            self.attribute([("/tmp", None, None,
                             ["--git-dir", "/srv/repo/.git", "fetch"])]), True)

    def test_relative_git_dir_option_resolves_against_the_cwd(self):
        self.assertIs(
            self.attribute([("/srv/repo", None, None,
                             ["--git-dir", ".git", "gc"])]), True)

    def test_work_tree_option_counts(self):
        self.assertIs(
            self.attribute([("/tmp", None, None,
                             ["--work-tree=/srv/repo", "status"])]), True)

    def test_dash_c_moves_the_directory(self):
        self.assertIs(
            self.attribute([("/tmp", None, None, ["-C", "/srv/repo", "gc"])]), True)
        self.assertIs(
            self.attribute([("/srv/repo", None, None, ["-C", "/tmp", "gc"])]), False)

    def test_options_stop_at_the_subcommand(self):
        self.assertIs(
            self.attribute([("/tmp", None, None,
                             ["log", "--git-dir=/srv/repo/.git"])]), False)

    def test_value_taking_options_are_skipped(self):
        self.assertIs(
            self.attribute([("/tmp", None, None,
                             ["-c", "a.b=c", "--git-dir", "/srv/repo/.git",
                              "fetch"])]), True)

    def test_a_process_with_no_repository_evidence_is_unattributed(self):
        self.assertEqual(
            self.attribute([(None, None, None, ["fetch"])]), doctor.UNATTRIBUTED)
        self.assertEqual(
            self.attribute([(None, None, None, ["--git-dir=.git", "fetch"])]),
            doctor.UNATTRIBUTED)

    def test_an_absolute_option_places_a_process_without_a_cwd(self):
        self.assertIs(
            self.attribute([(None, None, None, ["--git-dir=/home/x/.git", "gc"])]),
            False)
        self.assertIs(
            self.attribute([(None, None, None, ["--git-dir=/srv/repo/.git", "gc"])]),
            True)

    def test_git_running_uses_the_stubbed_process_lookup(self):
        original = doctor._proc_git_processes
        try:
            doctor._proc_git_processes = lambda: [("/elsewhere", None, None)]
            self.assertIs(doctor.git_running(self.PATHS), False)
            doctor._proc_git_processes = lambda: [("/srv/repo", None, None)]
            self.assertIs(doctor.git_running(self.PATHS), True)
        finally:
            doctor._proc_git_processes = original


if __name__ == "__main__":
    unittest.main()

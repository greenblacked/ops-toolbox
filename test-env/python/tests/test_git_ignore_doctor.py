"""Tests for git/git_ignore_doctor.py.

Only the pure parts are covered: the check-ignore wire format, gitignore
pattern semantics, and the re-inclusion recipe. Anything that shells out to
git is left alone — it needs a repository, and a mock would assert nothing
beyond its own shape.

The recipe test is the one that earns its keep. `build/*` plus
`!build/keep/note.txt` reads like a fix, pastes cleanly, and leaves the file
exactly as ignored as it was, because git never descends into `build/keep` to
reach the second line. The doctor printed that form until a fixture repository
proved it wrong.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "git"))

import git_ignore_doctor as doctor  # noqa: E402


class PathTestCase(unittest.TestCase):
    def test_dotdot_component_is_outside(self):
        self.assertTrue(doctor.is_outside(".."))
        self.assertTrue(doctor.is_outside("../x"))

    def test_a_name_starting_with_two_dots_is_inside(self):
        # A tracked file literally named ..config was refused as outside.
        self.assertFalse(doctor.is_outside("..config"))
        self.assertFalse(doctor.is_outside("sub/..config"))

    def test_rel_keeps_a_dotdot_named_file(self):
        self.assertEqual(doctor.rel("/r", "/r/..config"), "..config")

    def test_recipe_base_of_the_exclude_file_is_the_root(self):
        self.assertEqual(doctor.recipe_base(".git/info/exclude"), "")

    def test_recipe_base_of_a_global_excludes_file_is_the_root(self):
        self.assertEqual(doctor.recipe_base("/home/u/.config/git/ignore"), "")

    def test_recipe_base_of_a_nested_ignore_file_is_its_directory(self):
        self.assertEqual(doctor.recipe_base("sub/.gitignore"), "sub")


class ParseCheckIgnoreTestCase(unittest.TestCase):
    def test_matching_record(self):
        data = ".gitignore\0001\000build/\000build/keep/note.txt\000"
        records = doctor.parse_check_ignore(data)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].source, ".gitignore")
        self.assertEqual(records[0].lineno, "1")
        self.assertEqual(records[0].pattern, "build/")
        self.assertEqual(records[0].path, "build/keep/note.txt")
        self.assertTrue(doctor.matched(records[0]))

    def test_non_matching_record_has_empty_rule_fields(self):
        records = doctor.parse_check_ignore("\000\000\000src/main.c\000")
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].path, "src/main.c")
        self.assertFalse(doctor.matched(records[0]))

    def test_mixed_records_keep_their_order(self):
        data = (
            ".gitignore\0003\000*.log\000app.log\000"
            "\000\000\000src/main.c\000"
        )
        records = doctor.parse_check_ignore(data)
        self.assertEqual([r.path for r in records], ["app.log", "src/main.c"])

    def test_path_containing_a_newline_survives(self):
        records = doctor.parse_check_ignore("\000\000\000od\nd\000")
        self.assertEqual(records[0].path, "od\nd")

    def test_empty_output_is_no_records(self):
        self.assertEqual(doctor.parse_check_ignore(""), [])

    def test_truncated_trailing_record_is_dropped(self):
        # A killed git leaves a partial record; guessing at its missing fields
        # would attribute a rule to the wrong path.
        data = ".gitignore\0001\000build/\000build/x\000.gitignore\0002\000"
        records = doctor.parse_check_ignore(data)
        self.assertEqual([r.path for r in records], ["build/x"])

    def test_missing_record_is_not_a_match(self):
        self.assertFalse(doctor.matched(None))


class IgnoresTestCase(unittest.TestCase):
    def test_a_plain_match_ignores(self):
        record = doctor.IgnoreMatch(".gitignore", "1", "build/", "build/x")
        self.assertTrue(doctor.ignores(record))

    def test_a_negation_match_does_not_ignore(self):
        # check-ignore reports the negation as the deciding pattern, and the
        # decision it reports is "not ignored".
        record = doctor.IgnoreMatch(".gitignore", "3", "!build/keep/note.txt",
                                    "build/keep/note.txt")
        self.assertTrue(doctor.matched(record))
        self.assertFalse(doctor.ignores(record))


class ClassifyPatternTestCase(unittest.TestCase):
    def test_plain_pattern(self):
        shape = doctor.classify_pattern("*.log")
        self.assertFalse(shape.negated)
        self.assertFalse(shape.dir_only)
        self.assertFalse(shape.anchored)

    def test_directory_only(self):
        self.assertTrue(doctor.classify_pattern("build/").dir_only)

    def test_negation(self):
        shape = doctor.classify_pattern("!build/keep/note.txt")
        self.assertTrue(shape.negated)
        self.assertEqual(shape.body, "build/keep/note.txt")

    def test_leading_doublestar_does_not_anchor(self):
        # `**/logs` matches at every depth; the doctor called it anchored and
        # told the reader it did not match elsewhere.
        self.assertFalse(doctor.classify_pattern("**/logs").anchored)

    def test_doublestar_in_the_middle_still_anchors(self):
        self.assertTrue(doctor.classify_pattern("a/**/b").anchored)

    def test_interior_slash_anchors(self):
        self.assertTrue(doctor.classify_pattern("src/build").anchored)

    def test_leading_slash_anchors(self):
        self.assertTrue(doctor.classify_pattern("/build").anchored)

    def test_trailing_slash_alone_does_not_anchor(self):
        # `build/` matches a directory called build at any depth; only a slash
        # inside the pattern ties it to one place.
        self.assertFalse(doctor.classify_pattern("build/").anchored)

    def test_escaped_bang_is_not_a_negation(self):
        shape = doctor.classify_pattern("\\!important")
        self.assertFalse(shape.negated)
        self.assertEqual(shape.body, "!important")

    def test_escaped_hash_is_a_pattern(self):
        self.assertEqual(doctor.classify_pattern("\\#tag").body, "#tag")


class TrailingSpaceTestCase(unittest.TestCase):
    def test_unescaped_trailing_space_is_dropped(self):
        pattern, dropped = doctor.strip_trailing_space("logs  ")
        self.assertEqual(pattern, "logs")
        self.assertEqual(dropped, "  ")

    def test_escaped_trailing_space_is_kept(self):
        pattern, dropped = doctor.strip_trailing_space("logs\\ ")
        self.assertEqual(pattern, "logs\\ ")
        self.assertEqual(dropped, "")

    def test_escaped_backslash_does_not_protect_the_space(self):
        # `logs\\ ` is an escaped backslash then a bare space, so git drops it.
        pattern, dropped = doctor.strip_trailing_space("logs\\\\ ")
        self.assertEqual(pattern, "logs\\\\")
        self.assertEqual(dropped, " ")

    def test_no_trailing_space(self):
        self.assertEqual(doctor.strip_trailing_space("logs"), ("logs", ""))

    def test_classify_reports_the_dropped_run(self):
        self.assertEqual(doctor.classify_pattern("logs ").trailing_space, " ")

    def test_escaping_restores_a_single_dropped_space(self):
        self.assertEqual(doctor.escaped_trailing_space("logs", " "), "logs\\ ")

    def test_escaping_restores_a_run_by_escaping_only_the_last(self):
        # Verified against git: `logs \ ` matches a directory named "logs  "
        # and not "logs". Escaping every space would match something else again.
        self.assertEqual(doctor.escaped_trailing_space("logs", "  "), "logs \\ ")

    def test_escaping_a_pattern_with_nothing_dropped_is_a_no_op(self):
        self.assertEqual(doctor.escaped_trailing_space("logs", ""), "logs")

    def test_the_escaped_form_survives_a_second_strip(self):
        # The suggestion has to be a pattern the parser then leaves alone,
        # or the doctor would flag its own fix on the next run.
        restored = doctor.escaped_trailing_space("logs", "  ")
        self.assertEqual(doctor.strip_trailing_space(restored), (restored, ""))


class ParseIgnoreFileTestCase(unittest.TestCase):
    def test_line_numbers_survive_blanks_and_comments(self):
        rules = doctor.parse_ignore_file("# a comment\n\nbuild/\n\n*.log\n")
        self.assertEqual([r.lineno for r in rules], [3, 5])
        self.assertEqual([r.text for r in rules], ["build/", "*.log"])

    def test_a_hash_after_the_first_column_is_a_pattern(self):
        rules = doctor.parse_ignore_file("foo#bar\n")
        self.assertEqual([r.text for r in rules], ["foo#bar"])

    def test_crlf_line_endings_do_not_join_the_pattern(self):
        rules = doctor.parse_ignore_file("build/\r\n")
        self.assertEqual(rules[0].shape.body, "build/")

    def test_empty_file(self):
        self.assertEqual(doctor.parse_ignore_file(""), [])


class AncestorsTestCase(unittest.TestCase):
    def test_nested_path(self):
        self.assertEqual(doctor.ancestors("a/b/c.txt"), ["a", "a/b"])

    def test_top_level_path_has_none(self):
        self.assertEqual(doctor.ancestors("c.txt"), [])


class DeadNegationsTestCase(unittest.TestCase):
    def sourced(self, source, base, text, lineno=1):
        return doctor.SourcedRule(
            source, base, doctor.IgnoreRule(lineno, text, doctor.classify_pattern(text))
        )

    def test_anchored_negation_under_the_excluded_directory(self):
        rules = [self.sourced(".gitignore", "", "!build/keep/note.txt", 2)]
        found = doctor.dead_negations(rules, "build")
        self.assertEqual([e.rule.text for e in found], ["!build/keep/note.txt"])

    def test_negation_elsewhere_is_left_alone(self):
        rules = [self.sourced(".gitignore", "", "!docs/keep.txt")]
        self.assertEqual(doctor.dead_negations(rules, "build"), [])

    def test_a_plain_rule_is_not_a_dead_negation(self):
        rules = [self.sourced(".gitignore", "", "build/keep/note.txt")]
        self.assertEqual(doctor.dead_negations(rules, "build"), [])

    def test_unanchored_negation_is_not_claimed(self):
        # `!note.txt` matches at every depth; deciding it was meant for this
        # directory would be a guess, and a wrong one sends someone editing a
        # rule that was doing its job.
        rules = [self.sourced(".gitignore", "", "!note.txt")]
        self.assertEqual(doctor.dead_negations(rules, "build"), [])

    def test_a_nested_ignore_file_anchors_to_its_own_directory(self):
        # `!keep/note.txt` in build/.gitignore means build/keep/note.txt.
        rules = [self.sourced("build/.gitignore", "build", "!keep/note.txt")]
        found = doctor.dead_negations(rules, "build")
        self.assertEqual([e.rule.text for e in found], ["!keep/note.txt"])

    def test_a_nested_file_does_not_claim_another_directory(self):
        rules = [self.sourced("docs/.gitignore", "docs", "!keep/note.txt")]
        self.assertEqual(doctor.dead_negations(rules, "build"), [])


class ReinclusionRecipeTestCase(unittest.TestCase):
    def test_every_directory_on_the_way_down_is_re_included(self):
        self.assertEqual(
            doctor.reinclusion_recipe("build", "build/keep/note.txt"),
            ["build/*", "!build/keep/", "!build/keep/note.txt"],
        )

    def test_a_file_directly_inside_needs_no_intermediate(self):
        self.assertEqual(
            doctor.reinclusion_recipe("build", "build/note.txt"),
            ["build/*", "!build/note.txt"],
        )

    def test_two_levels_down(self):
        self.assertEqual(
            doctor.reinclusion_recipe("a", "a/b/c/d.txt"),
            ["a/*", "!a/b/", "!a/b/c/", "!a/b/c/d.txt"],
        )

    def test_a_trailing_slash_on_the_directory_is_not_doubled(self):
        self.assertEqual(
            doctor.reinclusion_recipe("build/", "build/note.txt")[0], "build/*"
        )


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

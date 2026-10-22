"""Tests for git/git_secrets_doctor.py.

Only the pure parts are covered: the name rules, the --allow globs, and the
two git output parsers. Anything that shells out to git is left alone; the
integration suite drives it against real repositories.

Token-shaped fixtures are assembled from pieces at run time, the same way the
doctor assembles its own patterns, so neither this file nor the doctor trips
the repository's secret scanning or push protection.
"""

from __future__ import annotations

import os
import re
import sys
import unittest

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "git"))

import git_secrets_doctor as doctor  # noqa: E402


def rules(path):
    return [(rule_id, level) for rule_id, level, _ in doctor.match_path(path)]


class MatchPathTestCase(unittest.TestCase):
    def test_env_file_fails(self):
        self.assertEqual(rules(".env"), [("env-file", "fail")])

    def test_env_with_a_suffix_fails(self):
        self.assertEqual(rules("app/.env.production"), [("env-file", "fail")])

    def test_placeholders_pass(self):
        self.assertEqual(rules(".env.example"), [])
        self.assertEqual(rules(".env.sample"), [])
        self.assertEqual(rules("config/.env.template"), [])

    def test_private_key_by_name(self):
        self.assertEqual(rules("deploy/id_ed25519"), [("private-key-file", "fail")])

    def test_public_half_passes(self):
        self.assertEqual(rules("id_ed25519.pub"), [])

    def test_terraform_state_and_its_backup(self):
        self.assertEqual(rules("infra/terraform.tfstate"), [("tfstate", "fail")])
        self.assertEqual(rules("terraform.tfstate.backup"), [("tfstate", "fail")])

    def test_pem_fails(self):
        self.assertEqual(rules("certs/server.pem"), [("private-key-file", "fail")])

    def test_npmrc_only_warns(self):
        self.assertEqual(rules("app/.npmrc"), [("npmrc", "warn")])

    def test_ordinary_files_pass(self):
        self.assertEqual(rules("Dockerfile"), [])
        self.assertEqual(rules("README.md"), [])
        self.assertEqual(rules("my.env"), [])
        self.assertEqual(rules("src/environment.ts"), [])

    def test_matching_is_case_insensitive(self):
        self.assertEqual(rules(".ENV"), [("env-file", "fail")])

    def test_a_directory_named_envs_is_not_an_env_file(self):
        self.assertEqual(rules("envs/prod.txt"), [])

    def test_nested_paths_use_the_file_name(self):
        self.assertEqual(rules("a/b/.git-credentials"), [("git-credentials", "fail")])

    def test_rules_that_need_the_directory(self):
        self.assertEqual(rules("home/.aws/credentials"), [("aws-credentials", "fail")])
        self.assertEqual(rules(".aws/credentials"), [("aws-credentials", "fail")])
        self.assertEqual(rules("ci/.docker/config.json"), [("docker-auth", "fail")])
        self.assertEqual(rules(".kube/config"), [("kubeconfig", "fail")])
        self.assertEqual(rules("credentials"), [])

    def test_the_warn_level_names(self):
        self.assertEqual(rules("service-account-prod.json"), [("service-account", "warn")])
        self.assertEqual(rules("secrets.yml"), [("secrets-yaml", "warn")])
        self.assertEqual(rules("terraform.tfvars"), [("tfvars", "warn")])


class AllowTestCase(unittest.TestCase):
    def test_a_glob_covers_a_fixture_directory(self):
        self.assertTrue(doctor.is_allowed("tests/fixtures/a/.env", ["tests/fixtures/*"]))

    def test_a_glob_does_not_cover_other_paths(self):
        self.assertFalse(doctor.is_allowed("src/.env", ["tests/fixtures/*"]))

    def test_an_exact_path(self):
        self.assertTrue(doctor.is_allowed("notes.txt", ["other", "notes.txt"]))

    def test_no_globs_allows_nothing(self):
        self.assertFalse(doctor.is_allowed(".env", []))


class ParseGrepFilesTestCase(unittest.TestCase):
    def test_two_records(self):
        self.assertEqual(
            doctor.parse_grep_files("HEAD:a/b.txt\0HEAD:c.txt\0"), ["a/b.txt", "c.txt"]
        )

    def test_a_name_with_a_space_and_a_newline_survives(self):
        self.assertEqual(
            doctor.parse_grep_files("HEAD:x y\nz.txt\0HEAD:a\0"), ["a", "x y\nz.txt"]
        )

    def test_duplicates_collapse(self):
        self.assertEqual(doctor.parse_grep_files("HEAD:a\0HEAD:a\0"), ["a"])

    def test_empty_output(self):
        self.assertEqual(doctor.parse_grep_files(""), [])

    def test_a_trailing_partial_record_is_dropped(self):
        self.assertEqual(doctor.parse_grep_files("HEAD:a\0HEAD:trunc"), ["a"])


class ParseAddedPathsTestCase(unittest.TestCase):
    LOG = (
        "@@new1\n\nconfig/.env\n"
        "@@mid2\n\nsecrets.txt\n\"tab\\tname\"\n"
        "@@old3\n\nconfig/.env\nkeep.txt\n"
    )

    def test_commit_markers_attribute_each_path(self):
        added = doctor.parse_added_paths(self.LOG)
        self.assertEqual(added["secrets.txt"], "mid2")
        self.assertEqual(added["keep.txt"], "old3")

    def test_a_path_added_twice_keeps_the_newest_addition(self):
        self.assertEqual(doctor.parse_added_paths(self.LOG)["config/.env"], "new1")

    def test_quoted_names_and_blank_lines_are_skipped(self):
        self.assertEqual(
            sorted(doctor.parse_added_paths(self.LOG)),
            ["config/.env", "keep.txt", "secrets.txt"],
        )

    def test_empty_text(self):
        self.assertEqual(doctor.parse_added_paths(""), {})


class ContentRulesTestCase(unittest.TestCase):
    """The EREs are handed to git grep; Python's re reads this subset the same."""

    def rule(self, rule_id):
        return {r: p for r, _, p in doctor.CONTENT_RULES}[rule_id]

    def test_private_key_headers(self):
        pattern = self.rule("private-key-block")
        for kind in ("OPENSSH ", "RSA ", "EC ", ""):
            self.assertRegex("-----BEGIN " + kind + "PRIVATE KEY-----", pattern)
        self.assertNotRegex("-----BEGIN " + "PUBLIC KEY-----", pattern)

    def test_github_token_needs_its_full_length(self):
        pattern = self.rule("github-token")
        self.assertRegex("ghp" + "_" + "a" * 36, pattern)
        self.assertNotRegex("ghp" + "_example", pattern)

    def test_the_doctor_does_not_match_its_own_rules(self):
        path = os.path.join(REPO_ROOT, "git", "git_secrets_doctor.py")
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        for rule_id, _, pattern in doctor.CONTENT_RULES:
            self.assertIsNone(re.search(pattern, source), rule_id)


if __name__ == "__main__":
    unittest.main()

"""Unit tests for release evidence, without booting a router."""

import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from release_evidence import collect

GOOD = """test_routeros_scripts.py::test_routeros_version_matches PASSED [  2%]
============ 72 passed, 9 xfailed, 7 warnings in 530.62s (0:08:50) =============
all selected suites passed
"""
WITH_SUBTESTS = (
    "mikrotik/tests/test_routeros_scripts.py::test_routeros_version_matches PASSED [  4%]\n"
    "=== 74 passed, 9 xfailed, 7 warnings, 7 subtests passed in 530.93s (0:08:50) ===\n"
    "all selected suites passed\n"
)


class ReleaseEvidenceTest(unittest.TestCase):
    def collect(self, log):
        return collect("7.25.2", "a" * 64, log, "b" * 40, "123", "1", "2026-11-24T23:20:32Z")

    def test_success(self):
        result = self.collect(GOOD)
        self.assertEqual((result["passed"], result["xfailed"], result["warnings"]), (72, 9, 7))
        self.assertEqual(result["subtestsPassed"], 0)
        self.assertEqual(result["unexpectedFailures"], 0)
        self.assertEqual(result["platform"], "chr-x86_64")

    def test_cli_exports_candidate_evidence_with_subtests(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            script = directory / "release_evidence.py"
            shutil.copyfile(Path(__file__).with_name(script.name), script)
            log = directory / "candidate.log"
            log.write_text(WITH_SUBTESTS, encoding="utf-8")
            subprocess.run(
                [sys.executable, str(script), "7.25.2", "a" * 64, str(log), "b" * 40],
                env={**os.environ, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"},
                check=True,
            )
            evidence = json.loads((directory / "evidence/7.25.2.json").read_text(encoding="utf-8"))

        self.assertEqual(evidence["passed"], 74)
        self.assertEqual(evidence["subtestsPassed"], 7)
        self.assertEqual(evidence["archiveSha256"], "a" * 64)
        self.assertEqual(evidence["testedCommit"], "b" * 40)
        self.assertEqual((evidence["runId"], evidence["runAttempt"]), (123, 2))

    def test_failure(self):
        for log in (
            GOOD.replace("72 passed", "71 passed, 1 failed"),
            GOOD.replace("72 passed", "71 passed, 1 xpassed"),
            GOOD.replace("all selected suites passed", ""),
            GOOD.replace("version_matches PASSED", "version_matches FAILED"),
            GOOD.replace("72 passed", "72 passed, 1 failed, 0 failed"),
            GOOD.replace("7 warnings", "7 warnings, 0 warning"),
            WITH_SUBTESTS.replace("74 passed", "73 passed, 1 failed"),
            WITH_SUBTESTS.replace("7 subtests passed", "6 subtests passed, 1 subtest failed"),
            WITH_SUBTESTS.replace("7 subtests passed", "7 subtests passed, 0 subtests passed"),
            GOOD + GOOD,
        ):
            with self.subTest(log=log), self.assertRaises(ValueError):
                self.collect(log)


if __name__ == "__main__":
    unittest.main()

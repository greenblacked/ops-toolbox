"""Unit tests for release evidence, without booting a router."""

import unittest

from release_evidence import collect

GOOD = """test_routeros_scripts.py::test_routeros_version_matches PASSED [  2%]
============ 72 passed, 9 xfailed, 7 warnings in 530.62s (0:08:50) =============
all selected suites passed
"""


class ReleaseEvidenceTest(unittest.TestCase):
    def collect(self, log):
        return collect("7.25.2", "a" * 64, log, "b" * 40, "123", "1", "2026-11-24T23:20:32Z")

    def test_success(self):
        result = self.collect(GOOD)
        self.assertEqual((result["passed"], result["xfailed"], result["warnings"]), (72, 9, 7))
        self.assertEqual(result["unexpectedFailures"], 0)
        self.assertEqual(result["platform"], "chr-x86_64")

    def test_failure(self):
        for log in (
            GOOD.replace("72 passed", "71 passed, 1 failed"),
            GOOD.replace("72 passed", "71 passed, 1 xpassed"),
            GOOD.replace("all selected suites passed", ""),
            GOOD.replace("version_matches PASSED", "version_matches FAILED"),
            GOOD + GOOD,
        ):
            with self.subTest(log=log), self.assertRaises(ValueError):
                self.collect(log)


if __name__ == "__main__":
    unittest.main()

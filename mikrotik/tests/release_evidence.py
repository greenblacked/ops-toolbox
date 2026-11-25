"""Emit bounded, non-secret evidence from a successful candidate CHR run."""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

VERSION = re.compile(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?")
SHA256 = re.compile(r"[a-f0-9]{64}")
SHA = re.compile(r"[a-f0-9]{40}")


def collect(version, digest, log, commit, run_id, attempt, tested_at):
    """Refuse incomplete or ambiguous test output; never publish raw logs."""
    if not VERSION.fullmatch(version) or not SHA256.fullmatch(digest):
        raise ValueError("invalid version or archive digest")
    if not SHA.fullmatch(commit) or not run_id.isdecimal() or not attempt.isdecimal():
        raise ValueError("invalid workflow provenance")
    if "all selected suites passed" not in log:
        raise ValueError("CHR suite did not finish successfully")
    if not re.search(r"::test_routeros_version_matches PASSED\b", log):
        raise ValueError("installed-version test did not pass")
    summaries = re.findall(r"^=+\s+(.+?)\s+in\s+[\d.]+s.*?=+\s*$", log, re.MULTILINE)
    if len(summaries) != 1:
        raise ValueError("missing or ambiguous pytest summary")
    counts = {}
    for item in summaries[0].split(", "):
        match = re.fullmatch(
            r"(\d+) (passed|subtests passed|xfailed|warnings?|failed|errors?|skipped|xpassed)", item
        )
        if not match:
            raise ValueError("unrecognized pytest summary")
        count, label = match.groups()
        key = label.rstrip("s") if label in ("warnings", "errors") else label
        if key in counts:
            raise ValueError("duplicate pytest summary count")
        counts[key] = int(count)
    if counts.get("passed", 0) < 1 or any(counts.get(k, 0) for k in ("failed", "error", "xpassed")):
        raise ValueError("unexpected test failures")
    return {
        "schema": 1,
        "version": version,
        "channel": "stable",
        "platform": "chr-x86_64",
        "archiveSha256": digest,
        "testedCommit": commit,
        "runId": int(run_id),
        "runAttempt": int(attempt),
        "testedAt": tested_at,
        "passed": counts["passed"],
        "subtestsPassed": counts.get("subtests passed", 0),
        "xfailed": counts.get("xfailed", 0),
        "warnings": counts.get("warning", 0),
        "skipped": counts.get("skipped", 0),
        "unexpectedFailures": 0,
    }


def main():
    version, digest, log_path, commit = sys.argv[1:]
    tested_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    payload = collect(
        version,
        digest,
        Path(log_path).read_text(encoding="utf-8"),
        commit,
        os.environ["GITHUB_RUN_ID"],
        os.environ["GITHUB_RUN_ATTEMPT"],
        tested_at,
    )
    directory = Path(__file__).resolve().parent / "evidence"
    directory.mkdir(exist_ok=True)
    path = directory / (version + ".json")
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

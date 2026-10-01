"""Native Apple Bash integration using only temporary user-owned fixture data."""

import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[3] / "macos-initial-setup/stay_fresh.sh"


@unittest.skipUnless(sys.platform == "darwin", "native macOS fixture integration")
class NativeStayFreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.env = {"HOME": str(self.home), "TMPDIR": str(self.home),
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "TERM": "dumb",
                    "STAY_FRESH_NOTIFY": "none"}

    def run_script(self, *args):
        result = subprocess.run(["/bin/bash", str(SCRIPT), "--no-sudo", "--notify", "none",
                                 "--step-timeout", "30", *args], env=self.env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_log_cleanup_preserves_open_and_recent_files(self):
        root = self.home / "Library/Logs"
        root.mkdir(parents=True)
        for name in ("old.log", "open.log", "recent.log"):
            path = root / name
            path.write_text("temporary test log")
            if name != "recent.log":
                os.utime(path, (time.time() - 40 * 86400,) * 2)
        with (root / "open.log").open():
            self.run_script("--only", "user-logs", "--yes", "--fail-on-warn")
        self.assertFalse((root / "old.log").exists())
        self.assertTrue((root / "open.log").exists())
        self.assertTrue((root / "recent.log").exists())

    def test_messenger_preview_and_cleanup_preserve_state(self):
        # Only fixture data is selected; do not depend on real Slack being closed.
        binary = self.home / "bin/pgrep"
        binary.parent.mkdir()
        binary.write_text("#!/bin/sh\nexit 1\n")
        binary.chmod(0o755)
        self.env["PATH"] = str(binary.parent) + ":" + self.env["PATH"]
        info = self.home / "Applications/Slack.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier="com.tinyspeck.slackmacgap",
                                            CFBundleExecutable="FixtureMessenger")))
        root = self.home / "Library/Application Support/Slack"
        leaves = ("Cache", "Partitions/workspace/Code Cache", "Partitions/workspace/IndexedDB")
        for leaf in leaves:
            folder = root / leaf
            folder.mkdir(parents=True)
            (folder / "fixture").write_text("temporary fixture")
        output = self.run_script("--only", "app-caches", "--deep-clean", "--dry-run")
        self.assertNotIn("Electron/Chromium caches: ", output)
        for leaf in leaves:
            self.assertTrue((root / leaf / "fixture").exists())
        self.run_script("--only", "app-caches", "--deep-clean", "--yes", "--fail-on-warn")
        for leaf in leaves[:2]:
            self.assertFalse((root / leaf / "fixture").exists())
        self.assertTrue((root / leaves[2] / "fixture").exists())

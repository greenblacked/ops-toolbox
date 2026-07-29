"""Tests for macos-initial-setup/lib/workspace_scan.py.

Written against stdlib unittest on purpose: the module under test is called by
stay_fresh.sh with /usr/bin/python3 and imports nothing outside the standard
library, so its tests should not need a venv, a pip install, or a network to
run. pytest collects these fine if you prefer to run them that way.

The bias under test is the important part. Classifying a live workspace as
stale deletes a project's editor state; classifying a stale one as live wastes
disk. Every ambiguous case here asserts the second outcome.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(  # <repo>
    os.path.dirname(  # test-env
        os.path.dirname(  # test-env/python
            os.path.dirname(os.path.abspath(__file__))  # test-env/python/tests
        )
    )
)
LIB_DIR = os.path.join(REPO_ROOT, "macos-initial-setup", "lib")
SCANNER = os.path.join(LIB_DIR, "workspace_scan.py")
sys.path.insert(0, LIB_DIR)

import workspace_scan  # noqa: E402  (path must be set up first)
from workspace_scan import LIVE, STALE, UNRESOLVED  # noqa: E402


class ScanTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        # Stand-in for /Volumes. Empty means "nothing is mounted".
        self.volumes = os.path.join(self.tmp, "volumes")
        os.makedirs(self.volumes)
        # A workspaceStorage root to hang entries off.
        self.root = os.path.join(self.tmp, "workspaceStorage")
        os.makedirs(self.root)
        self._entry_n = 0

    def tearDown(self):
        self._tmp.cleanup()

    # --- helpers ----------------------------------------------------------
    def make_entry(self, manifest=None, raw_manifest=None):
        """Create workspaceStorage/<hash>/ and return its path."""
        self._entry_n += 1
        entry = os.path.join(self.root, "hash%02d" % self._entry_n)
        os.makedirs(entry)
        if raw_manifest is not None:
            with open(os.path.join(entry, "workspace.json"), "w") as fh:
                fh.write(raw_manifest)
        elif manifest is not None:
            with open(os.path.join(entry, "workspace.json"), "w") as fh:
                json.dump(manifest, fh)
        return entry

    def make_project(self, name):
        """Create a real directory to stand in for an open project."""
        path = os.path.join(self.tmp, name)
        os.makedirs(path)
        return path

    def mount(self, volume_name):
        os.makedirs(os.path.join(self.volumes, volume_name), exist_ok=True)

    def classify(self, entry):
        mounted = workspace_scan.mounted_volume_names(self.volumes)
        return workspace_scan.classify_entry(entry, mounted)

    # --- the basic three --------------------------------------------------
    def test_existing_folder_is_live(self):
        project = self.make_project("proj")
        entry = self.make_entry({"folder": "file://" + project})
        status, _, path = self.classify(entry)
        self.assertEqual(status, LIVE)
        self.assertEqual(path, project)

    def test_missing_folder_is_stale(self):
        entry = self.make_entry({"folder": "file://" + os.path.join(self.tmp, "gone")})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, STALE)
        self.assertEqual(reason, "path gone")

    def test_code_workspace_file_is_honoured(self):
        ws = os.path.join(self.tmp, "thing.code-workspace")
        open(ws, "w").close()
        entry = self.make_entry({"workspace": "file://" + ws})
        status, _, _ = self.classify(entry)
        self.assertEqual(status, LIVE)

    # --- everything unknown is kept ---------------------------------------
    def test_missing_manifest_is_unresolved(self):
        entry = self.make_entry()
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertEqual(reason, "no workspace.json")

    def test_unparsable_manifest_is_unresolved(self):
        entry = self.make_entry(raw_manifest="{not json at all")
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertEqual(reason, "unparsable workspace.json")

    def test_manifest_without_known_key_is_unresolved(self):
        entry = self.make_entry({"something": "else"})
        status, _, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)

    def test_manifest_that_is_not_an_object_is_unresolved(self):
        entry = self.make_entry(raw_manifest="[1, 2, 3]")
        status, _, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)

    def test_remote_workspace_is_unresolved(self):
        entry = self.make_entry({"folder": "vscode-remote://ssh-remote+box/home/me/p"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertIn("non-local", reason)

    def test_unc_host_is_unresolved(self):
        # file://server/share is a remote host, not a local absolute path.
        entry = self.make_entry({"folder": "file://fileserver/share/proj"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertIn("non-local", reason)

    def test_file_localhost_is_treated_as_local(self):
        project = self.make_project("localproj")
        entry = self.make_entry({"folder": "file://localhost" + project})
        status, _, _ = self.classify(entry)
        self.assertEqual(status, LIVE)

    # --- percent-encoding -------------------------------------------------
    def test_percent_encoded_space_resolves(self):
        project = self.make_project("with space")
        entry = self.make_entry({"folder": "file://" + project.replace(" ", "%20")})
        status, _, _ = self.classify(entry)
        self.assertEqual(status, LIVE)

    def test_literal_percent_in_path_resolves(self):
        # '100%25%20done' decodes to '100% done'. Both forms are checked, so
        # the entry survives whichever one is on disk.
        project = self.make_project("100% done")
        encoded = os.path.join(self.tmp, "100%25%20done")
        entry = self.make_entry({"folder": "file://" + encoded})
        status, _, _ = self.classify(entry)
        self.assertEqual(status, LIVE)
        self.assertTrue(os.path.isdir(project))

    def test_malformed_escape_falls_back_to_raw(self):
        # '%zz' is not a valid escape; unquote leaves it alone and the raw form
        # is what exists on disk.
        project = self.make_project("weird%zzname")
        entry = self.make_entry({"folder": "file://" + project})
        status, _, _ = self.classify(entry)
        self.assertEqual(status, LIVE)

    def test_malformed_escape_on_missing_path_is_still_stale(self):
        entry = self.make_entry(
            {"folder": "file://" + os.path.join(self.tmp, "nope%zz")}
        )
        status, _, _ = self.classify(entry)
        self.assertEqual(status, STALE)

    # --- the external-volume fix -----------------------------------------
    def test_path_on_unmounted_volume_is_unresolved(self):
        # The regression this whole module exists for: an unplugged SSD looks
        # exactly like a deleted project to a bare existence check.
        entry = self.make_entry({"folder": "file:///Volumes/BigSSD/projects/thing"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertIn("volume not mounted", reason)
        self.assertIn("BigSSD", reason)

    def test_missing_path_on_mounted_volume_is_stale(self):
        # Volume is attached, so a missing path really is missing.
        self.mount("BigSSD")
        entry = self.make_entry({"folder": "file:///Volumes/BigSSD/definitely/gone"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, STALE)
        self.assertEqual(reason, "path gone")

    def test_network_share_unmounted_is_unresolved(self):
        entry = self.make_entry({"folder": "file:///Volumes/team-nas/design/src"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertIn("team-nas", reason)

    def test_percent_encoded_volume_name_is_decoded_before_matching(self):
        # "Macintosh HD" style names arrive percent-encoded.
        entry = self.make_entry({"folder": "file:///Volumes/My%20Disk/proj"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertIn("My Disk", reason)

    def test_volume_named_with_literal_percent_is_matched_raw(self):
        # Decoding '/Volumes/back%25up' yields '/Volumes/back%up'. The volume
        # actually attached is the raw spelling, so the raw form has to be
        # considered too or a mounted disk reads as unmounted.
        self.mount("back%25up")
        entry = self.make_entry({"folder": "file:///Volumes/back%25up/gone"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, STALE, "mounted volume was misread as unmounted")
        self.assertEqual(reason, "path gone")

    def test_neither_spelling_mounted_is_unresolved(self):
        entry = self.make_entry({"folder": "file:///Volumes/back%25up/proj"})
        status, reason, _ = self.classify(entry)
        self.assertEqual(status, UNRESOLVED)
        self.assertIn("volume not mounted", reason)

    def test_home_path_is_not_treated_as_a_volume(self):
        # Paths on the boot volume must not be shielded by the volume check,
        # or nothing would ever be collected.
        entry = self.make_entry({"folder": "file://" + os.path.join(self.tmp, "x")})
        status, _, _ = self.classify(entry)
        self.assertEqual(status, STALE)

    def test_system_volumes_data_is_never_shielded(self):
        entry = self.make_entry(
            {"folder": "file:///System/Volumes/Data/Users/me/goneproj"}
        )
        status, _, _ = self.classify(entry)
        self.assertEqual(status, STALE)

    def test_missing_volumes_dir_does_not_shield_root_paths(self):
        mounted = workspace_scan.mounted_volume_names(
            os.path.join(self.tmp, "no-such-dir")
        )
        self.assertEqual(mounted, frozenset())
        entry = self.make_entry({"folder": "file://" + os.path.join(self.tmp, "gone")})
        status, _, _ = workspace_scan.classify_entry(entry, mounted)
        self.assertEqual(status, STALE)

    # --- scan() over roots -------------------------------------------------
    def test_scan_covers_every_entry_and_skips_files(self):
        self.make_project("live-one")
        self.make_entry({"folder": "file://" + os.path.join(self.tmp, "live-one")})
        self.make_entry({"folder": "file://" + os.path.join(self.tmp, "dead-one")})
        self.make_entry()
        # A stray file in the storage root must not be classified.
        open(os.path.join(self.root, "stray.txt"), "w").close()

        results = workspace_scan.scan([self.root], volumes_dir=self.volumes)
        self.assertEqual(len(results), 3)
        by_status = {}
        for item in results:
            by_status.setdefault(item["status"], []).append(item)
        self.assertEqual(len(by_status[LIVE]), 1)
        self.assertEqual(len(by_status[STALE]), 1)
        self.assertEqual(len(by_status[UNRESOLVED]), 1)

    def test_scan_ignores_absent_roots(self):
        results = workspace_scan.scan(
            [os.path.join(self.tmp, "not-there")], volumes_dir=self.volumes
        )
        self.assertEqual(results, [])

    def test_scan_is_empty_for_empty_root(self):
        self.assertEqual(workspace_scan.scan([self.root], volumes_dir=self.volumes), [])


class CliTestCase(unittest.TestCase):
    """The NUL-delimited contract stay_fresh.sh actually consumes."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.volumes = os.path.join(self.tmp, "volumes")
        os.makedirs(self.volumes)
        self.root = os.path.join(self.tmp, "workspaceStorage")
        os.makedirs(self.root)

    def tearDown(self):
        self._tmp.cleanup()

    def add(self, name, target):
        entry = os.path.join(self.root, name)
        os.makedirs(entry)
        with open(os.path.join(entry, "workspace.json"), "w") as fh:
            json.dump({"folder": "file://" + target}, fh)
        return entry

    def run_scanner(self, *args):
        return subprocess.run(
            [sys.executable, SCANNER, self.root, "--volumes-dir", self.volumes]
            + list(args),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def test_records_are_nul_delimited_with_four_fields(self):
        os.makedirs(os.path.join(self.tmp, "alive"))
        self.add("a", os.path.join(self.tmp, "alive"))
        self.add("b", os.path.join(self.tmp, "dead"))

        out = self.run_scanner().stdout
        self.assertTrue(out.endswith(b"\0"))
        records = [r for r in out.split(b"\0") if r]
        self.assertEqual(len(records), 2)
        statuses = set()
        for rec in records:
            fields = rec.decode("utf-8").split("\t")
            self.assertEqual(len(fields), 4)
            statuses.add(fields[0])
        self.assertEqual(statuses, {LIVE, STALE})

    def test_newline_in_path_does_not_split_a_record(self):
        # macOS permits newlines in filenames, which is why the output is
        # NUL-delimited rather than line-based.
        weird = os.path.join(self.tmp, "two\nlines")
        os.makedirs(weird)
        self.add("a", weird)

        out = self.run_scanner().stdout
        records = [r for r in out.split(b"\0") if r]
        self.assertEqual(len(records), 1)
        self.assertIn(b"two\nlines", records[0])

    def test_json_mode_is_valid_json(self):
        self.add("a", os.path.join(self.tmp, "dead"))
        out = self.run_scanner("--json").stdout
        data = json.loads(out.decode("utf-8"))
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["status"], STALE)

    def test_empty_root_produces_no_output(self):
        self.assertEqual(self.run_scanner().stdout, b"")


if __name__ == "__main__":
    unittest.main()

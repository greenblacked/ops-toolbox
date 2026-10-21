"""Tests for mikrotik/features/export_config.py.

Normalisation is covered because it is the part with a judgement call in it.
Strip too little and every export is a noisy diff; strip too much and a real
configuration change disappears into the filter. The secret scan is covered for
the same reason, and for one more: it is the last thing between a pasted bot
token and git history, and the one thing it must never do is print what it
found. Everything else in that script is ssh and git plumbing that would need a
router to mean anything.
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
sys.path.insert(0, os.path.join(REPO_ROOT, "mikrotik", "features"))

import export_config  # noqa: E402

# Shape of a real RouterOS 7 export.
EXPORT_TEMPLATE = """\
# {date} by RouterOS 7.22
# software id = ABCD-1234
#
# model = RB5009UG+S+
# serial number = HJ80TESTTEST
/interface bridge
add admin-mac=48:A9:8A:00:00:00 auto-mac=no comment=defconf name=bridge
/ip firewall filter
add action=accept chain=input comment="defconf: accept established" \\
    connection-state=established,related
add action=drop chain=input comment="defconf: drop all not coming from LAN" \\
    in-interface-list=!LAN
"""


class NormaliseTestCase(unittest.TestCase):
    def test_two_exports_of_an_unchanged_router_are_identical(self):
        # The whole reason the function exists.
        first = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        second = export_config.normalise(EXPORT_TEMPLATE.format(date="aug/03/2026 09:12:47"))
        self.assertEqual(first, second)

    def test_iso_style_timestamp_is_also_stripped(self):
        a = export_config.normalise(EXPORT_TEMPLATE.format(date="2026-07-29 18:04:11"))
        b = export_config.normalise(EXPORT_TEMPLATE.format(date="2026-08-03 09:12:47"))
        self.assertEqual(a, b)

    def test_configuration_lines_survive(self):
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertIn("/interface bridge", out)
        self.assertIn("/ip firewall filter", out)
        self.assertIn("in-interface-list=!LAN", out)

    def test_a_real_change_still_shows(self):
        base = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        changed_src = EXPORT_TEMPLATE.format(date="jul/30/2026 10:00:00").replace(
            "in-interface-list=!LAN", "in-interface-list=!WAN"
        )
        changed = export_config.normalise(changed_src)
        self.assertNotEqual(base, changed)
        self.assertIn("!WAN", changed)

    def test_comments_that_are_configuration_are_kept(self):
        # comment= is part of a rule, not a header. Dropping it would hide a
        # meaningful edit.
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertIn('comment="defconf: accept established"', out)

    def test_hardware_identity_header_is_stripped(self):
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertNotIn("serial number", out)
        self.assertNotIn("software id", out)

    def test_trailing_blank_lines_collapse(self):
        out = export_config.normalise("/ip address\nadd address=10.0.0.1/24\n\n\n\n")
        self.assertTrue(out.endswith("add address=10.0.0.1/24\n"))
        self.assertFalse(out.endswith("\n\n"))

    def test_trailing_whitespace_does_not_create_a_diff(self):
        a = export_config.normalise("/ip address   \nadd address=10.0.0.1/24\n")
        b = export_config.normalise("/ip address\nadd address=10.0.0.1/24\n")
        self.assertEqual(a, b)

    def test_empty_input_does_not_crash(self):
        self.assertEqual(export_config.normalise(""), "\n")

    def test_output_always_ends_with_one_newline(self):
        out = export_config.normalise(EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11"))
        self.assertTrue(out.endswith("\n"))
        self.assertFalse(out.endswith("\n\n"))


class ArgumentGuardTestCase(unittest.TestCase):
    def test_sensitive_plus_commit_is_refused(self):
        # Writing router secrets into git history is not something to do by
        # accident, so it fails before it ever contacts the router.
        out, errout = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(errout):
            rc = export_config.main(
                ["--host", "192.0.2.1", "--show-sensitive", "--commit"]
            )
        self.assertEqual(rc, 3)
        self.assertIn("secrets", (out.getvalue() + errout.getvalue()).lower())

    def test_output_modes_are_mutually_exclusive(self):
        rc = export_config.main(
            ["--host", "192.0.2.1", "--stdout", "--diff"]
        )
        self.assertEqual(rc, 3)


class DiffModeTestCase(unittest.TestCase):
    def test_diff_shows_change_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "router.rsc")
            with open(dest, "w", encoding="utf-8") as fh:
                fh.write("/ip address\nadd address=192.0.2.1/24\n")
            live = "/ip address\nadd address=192.0.2.2/24\n"
            stdout = io.StringIO()
            with mock.patch.object(
                export_config, "fetch_export", return_value=(0, live, "")
            ), contextlib.redirect_stdout(stdout):
                rc = export_config.main([
                    "--host", "router", "--name", "router", "--out", tmp, "--diff"
                ])
            # Drift is a finding, so --diff exits 1 the way `git diff
            # --exit-code` does. Asserting 0 here is what let the mode that
            # exists to report drift be unable to report it.
            self.assertEqual(rc, 1)
            self.assertIn("-add address=192.0.2.1/24", stdout.getvalue())
            self.assertIn("+add address=192.0.2.2/24", stdout.getvalue())
            with open(dest, encoding="utf-8") as fh:
                self.assertIn("192.0.2.1", fh.read())

    def test_diff_exits_zero_when_nothing_changed(self):
        # The other half of the contract: without this, exiting 1 on drift
        # could be satisfied by exiting 1 always, and `--diff || alert` would
        # cry wolf on every run instead of never firing.
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "router.rsc")
            live = "/ip address\nadd address=192.0.2.1/24\n"
            with open(dest, "w", encoding="utf-8") as fh:
                fh.write(live)
            stdout = io.StringIO()
            with mock.patch.object(
                export_config, "fetch_export", return_value=(0, live, "")
            ), contextlib.redirect_stdout(stdout):
                rc = export_config.main([
                    "--host", "router", "--name", "router", "--out", tmp, "--diff"
                ])
            self.assertEqual(rc, 0)
            self.assertNotIn("---", stdout.getvalue())

    def test_diff_fails_when_existing_destination_cannot_be_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "router.rsc")
            os.mkdir(dest)
            with mock.patch.object(
                export_config, "fetch_export", return_value=(0, "/ip address\n", "")
            ):
                rc = export_config.main([
                    "--host", "router", "--name", "router", "--out", tmp, "--diff"
                ])
            self.assertEqual(rc, 1)


class PrivateAtomicOutputTestCase(unittest.TestCase):
    def run_export(self, directory, **patches):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(
                export_config, "fetch_export", return_value=(0, "new config\n", "")
            ))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            for name, effect in patches.items():
                stack.enter_context(mock.patch(name, side_effect=effect))
            return export_config.main(["--host", "router", "--out", directory])

    def test_output_is_private_with_permissive_umask_and_existing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "router.rsc")
            old_umask = os.umask(0)
            try:
                for mask in (0o000, 0o022, 0o077):
                    os.umask(mask)
                    for existing in (False, True):
                        if os.path.exists(dest):
                            os.unlink(dest)
                        if existing:
                            with open(dest, "w") as fh:
                                # Even unchanged exports must harden an old file.
                                fh.write("new config\n")
                            os.chmod(dest, 0o644)
                        self.assertEqual(self.run_export(tmp), 0)
                        self.assertEqual(os.stat(dest).st_mode & 0o777, 0o600)
            finally:
                os.umask(old_umask)

    def test_symlink_is_refused_without_reading_or_overwriting_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "target")
            with open(target, "w") as fh:
                fh.write("old config\n")
            os.symlink(target, os.path.join(tmp, "router.rsc"))
            self.assertEqual(self.run_export(tmp), 1)
            with open(target) as fh:
                self.assertEqual(fh.read(), "old config\n")

    def test_dangling_symlink_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "missing")
            dest = os.path.join(tmp, "router.rsc")
            os.symlink(target, dest)
            self.assertEqual(self.run_export(tmp), 1)
            self.assertTrue(os.path.islink(dest))
            self.assertFalse(os.path.exists(target))

    def test_failed_publish_preserves_old_artifact_and_removes_staging_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "router.rsc")
            with open(dest, "w") as fh:
                fh.write("old config\n")
            self.assertEqual(self.run_export(tmp, **{"os.replace": OSError("disk failure")}), 1)
            with open(dest) as fh:
                self.assertEqual(fh.read(), "old config\n")
            self.assertEqual(os.listdir(tmp), ["router.rsc"])

    def test_failed_write_preserves_old_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "router.rsc")
            with open(dest, "w") as fh:
                fh.write("old config\n")
            self.assertEqual(self.run_export(tmp, **{"os.fsync": OSError("disk full")}), 1)
            with open(dest) as fh:
                self.assertEqual(fh.read(), "old config\n")
            self.assertEqual(os.listdir(tmp), ["router.rsc"])


# A fake token in the shape BotFather issues. It never left this file.
FAKE_TOKEN = "123456789:AAH-fake_fake_fake_fake_fake_fake_fake1"

# Real export shapes: /export does not hide a script's source or a scheduler's
# on-event, and the install steps put the token in a startup script. Inside an
# export the script's quotes are escaped and its line breaks are \r\n.
SECRET_EXPORT = (
    "/system scheduler\n"
    'add interval=1d name=boot on-event=":global TgBotToken \\"' + FAKE_TOKEN + '\\"; '
    '/system script run startup" policy=read,write start-time=startup\n'
    "/system script\n"
    "add dont-require-permissions=no name=startup owner=admin policy=ftp,read,write "
    'source=":global TgBotToken \\"' + FAKE_TOKEN + '\\";\\r\\n:global TgChatId \\"12345678\\";"\n'
    "/ip firewall filter\n"
    'add action=accept chain=input comment="#critical" connection-state=established,related\n'
)

CLEAN_EXPORT = EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11")


class SecretScanTestCase(unittest.TestCase):
    def run_main(self, argv, export=SECRET_EXPORT):
        out, errout = io.StringIO(), io.StringIO()
        with mock.patch.object(export_config, "fetch_export",
                               return_value=(0, export, "")), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(errout):
            rc = export_config.main(argv)
        return rc, out.getvalue(), errout.getvalue()

    def test_finds_the_telegram_token_by_shape(self):
        text = 'url="https://api.telegram.org/bot%s/sendMessage"\n' % FAKE_TOKEN
        self.assertEqual(export_config.find_secrets(text), [(1, "telegram bot token")])

    def test_finds_a_global_assignment_with_escaped_quotes(self):
        text = ('add name=s source=":global RouterBackupPassword \\"hunter2hunter\\";"\n')
        self.assertEqual(export_config.find_secrets(text),
                         [(1, "secret assigned in a script")])

    def test_ignores_the_shipped_placeholders_and_empty_values(self):
        text = (
            'add name=s source=":local BotToken \\"token\\";\\r\\n'
            ':local Password \\"\\";\\r\\n'
            ':global RouterBackupPassword \\"<paste backup password>\\";\\r\\n'
            '# :global RouterBackupPassword \\"s3cret\\"\\r\\n'
            '/system backup save password=\\$Password"\n'
            "set wifi1 passphrase=<redacted>\n"
        )
        self.assertEqual(export_config.find_secrets(text), [])

    def test_finds_sensitive_fields_and_redacts_inside_their_quotes(self):
        text = 'set [ find default-name=wlan1 ] comment="#x" passphrase="my pass"\n'
        self.assertEqual(export_config.find_secrets(text), [(1, "sensitive field")])
        self.assertEqual(
            export_config.redact_secrets(text),
            'set [ find default-name=wlan1 ] comment="#x" passphrase="<redacted>"\n',
        )

    def test_findings_never_contain_the_value(self):
        findings = export_config.find_secrets(SECRET_EXPORT)
        self.assertTrue(findings)
        for finding in findings:
            self.assertNotIn(FAKE_TOKEN, repr(finding))
            self.assertNotIn("AAH-fake", repr(finding))
        with tempfile.TemporaryDirectory() as tmp:
            for argv in (["--host", "router", "--scan-secrets"],
                         ["--host", "router", "--out", tmp, "--stdout", "--redact-secrets"],
                         ["--host", "router", "--out", tmp, "--diff", "--redact-secrets"],
                         ["--host", "router", "--out", tmp, "--commit"]):
                _, out, err = self.run_main(argv)
                self.assertNotIn("AAH-fake", out + err, argv)

    def test_redaction_replaces_only_the_value_and_keeps_the_rest_of_the_line(self):
        redacted = export_config.redact_secrets(SECRET_EXPORT)
        lines = redacted.splitlines()
        self.assertEqual(
            lines[3],
            "add dont-require-permissions=no name=startup owner=admin policy=ftp,read,write "
            'source=":global TgBotToken \\"<redacted>\\";\\r\\n:global TgChatId \\"12345678\\";"',
        )
        self.assertNotIn(FAKE_TOKEN, redacted)
        self.assertEqual(lines[0], "/system scheduler")
        self.assertEqual(lines[5], SECRET_EXPORT.splitlines()[5])
        self.assertEqual(len(lines), len(SECRET_EXPORT.splitlines()))

    def test_redaction_is_idempotent(self):
        once = export_config.redact_secrets(SECRET_EXPORT)
        self.assertEqual(export_config.redact_secrets(once), once)
        self.assertEqual(export_config.find_secrets(once), [])

    def test_a_line_continuation_is_joined_before_matching_but_reports_the_first_line(self):
        # /export wraps long lines anywhere, the middle of a token included.
        split = (
            "/system script\n"
            'add name=startup source=":global TgBotToken \\"123456789:AAH-fake_fake_fake_fa\\\n'
            '    ke_fake_fake_fake_fake1\\";"\n'
            "/ip address\n"
        )
        findings = export_config.find_secrets(split)
        self.assertEqual({line for line, _ in findings}, {2})
        self.assertIn((2, "telegram bot token"), findings)
        redacted = export_config.redact_secrets(split)
        self.assertNotIn("fake_fake", redacted)
        self.assertEqual(
            redacted,
            "/system script\n"
            'add name=startup source=":global TgBotToken \\"<redacted>\\";"\n'
            "/ip address\n",
        )

    def test_clean_export_has_no_findings(self):
        self.assertEqual(export_config.find_secrets(CLEAN_EXPORT), [])
        self.assertEqual(export_config.redact_secrets(CLEAN_EXPORT), CLEAN_EXPORT)

    def test_scan_file_needs_no_host_and_no_ssh(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "router.rsc")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(SECRET_EXPORT)
            fetch = mock.Mock(side_effect=AssertionError("--scan-file must not use ssh"))
            out = io.StringIO()
            with mock.patch.object(export_config, "fetch_export", fetch), \
                 contextlib.redirect_stdout(out), \
                 contextlib.redirect_stderr(io.StringIO()):
                rc = export_config.main(["--scan-file", path])
            self.assertEqual(rc, 1)
            fetch.assert_not_called()
            self.assertIn("line 4: secret assigned in a script", out.getvalue())
            self.assertIn("values are never printed", out.getvalue())

    def test_scan_secrets_exits_1_on_findings_0_when_clean(self):
        rc, out, _ = self.run_main(["--host", "router", "--scan-secrets"])
        self.assertEqual(rc, 1)
        self.assertIn("4 finding(s)", out)
        rc, out, _ = self.run_main(["--host", "router", "--scan-secrets"], export=CLEAN_EXPORT)
        self.assertEqual(rc, 0)
        self.assertIn("0 finding(s)", out)

    def test_scan_secrets_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            before = sorted(os.listdir(tmp))
            rc, _, _ = self.run_main(["--host", "router", "--out", tmp, "--scan-secrets"])
            self.assertEqual(rc, 1)
            self.assertEqual(sorted(os.listdir(tmp)), before)

    def test_commit_is_refused_when_secrets_are_found_without_redact(self):
        with tempfile.TemporaryDirectory() as tmp:
            git = mock.Mock(return_value=(0, "", ""))
            with mock.patch.object(export_config, "git", git):
                rc, _, err = self.run_main(["--host", "router", "--out", tmp, "--commit"])
            self.assertEqual(rc, 1)
            git.assert_not_called()
            self.assertEqual(os.listdir(tmp), [])
            self.assertIn("--redact-secrets", err)

    def test_commit_proceeds_with_redact_and_the_stored_file_has_no_token(self):
        def fake_git(args, cwd):
            if args[:1] == ["diff"]:
                return 0, " router.rsc | 7 +++++++\n", ""
            return 0, "", ""

        with tempfile.TemporaryDirectory() as tmp:
            git = mock.Mock(side_effect=fake_git)
            with mock.patch.object(export_config, "git", git):
                rc, _, _ = self.run_main(
                    ["--host", "router", "--out", tmp, "--commit", "--redact-secrets"]
                )
            self.assertEqual(rc, 0)
            self.assertTrue(any(c.args[0][:1] == ["commit"] for c in git.call_args_list))
            with open(os.path.join(tmp, "router.rsc"), encoding="utf-8") as fh:
                stored = fh.read()
            self.assertNotIn(FAKE_TOKEN, stored)
            self.assertIn("<redacted>", stored)

    def test_a_plain_write_warns_on_stderr_and_still_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, out, err = self.run_main(["--host", "router", "--out", tmp])
            self.assertEqual(rc, 0)
            self.assertIn("possible secret(s)", err)
            self.assertNotIn("possible secret(s)", out)
            self.assertEqual(os.listdir(tmp), ["router.rsc"])

    def test_scan_flags_are_mutually_exclusive_with_stdout_diff_commit(self):
        for extra in (["--stdout"], ["--diff"], ["--commit"], ["--redact-secrets"]):
            for scan in (["--scan-secrets"], ["--scan-file", "/nonexistent.rsc"]):
                rc, _, _ = self.run_main(["--host", "router"] + scan + extra)
                self.assertEqual(rc, 3, scan + extra)

    def test_missing_host_without_scan_file_is_still_usage_3(self):
        errout = io.StringIO()
        with contextlib.redirect_stderr(errout), self.assertRaises(SystemExit) as raised:
            export_config.main(["--stdout"])
        self.assertEqual(raised.exception.code, 3)
        self.assertIn("--host", errout.getvalue())

    def test_show_sensitive_with_commit_is_still_refused_with_3(self):
        rc, _, _ = self.run_main(["--host", "router", "--show-sensitive", "--commit"])
        self.assertEqual(rc, 3)


class DefaultOutputTestCase(unittest.TestCase):
    """Where an export lands when --out is not given.

    The history is the operator's, not the package's: it is not tracked here
    (`.gitignore`), it predates the core/features split, and the README points
    at `mikrotik/config-history/`. Keying the default off this file's own
    folder moved it to `mikrotik/features/config-history/` when the file moved
    - silently, into an empty directory, with `--diff` comparing a live export
    against nothing while every stored export sat where it had always been.
    """

    def test_default_out_is_the_package_root_not_this_file_s_folder(self):
        package = os.path.join(REPO_ROOT, "mikrotik")
        self.assertEqual(
            export_config.DEFAULT_OUT, os.path.join(package, "config-history")
        )
        self.assertNotEqual(
            os.path.dirname(export_config.DEFAULT_OUT),
            os.path.dirname(os.path.abspath(export_config.__file__)),
            "the export history must not follow the script between folders",
        )


if __name__ == "__main__":
    unittest.main()

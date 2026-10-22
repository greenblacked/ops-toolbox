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
BOT_FAKE = "123456789" + ":" + "AAH-" + "fake_" * 6 + "fake1"

# Real export shapes: /export does not hide a script's source or a scheduler's
# on-event, and the install steps put the token in a startup script. Inside an
# export the script's quotes are escaped and its line breaks are \r\n.
LEAKY_EXPORT = (
    "/system scheduler\n"
    'add interval=1d name=boot on-event=":global TgBotToken \\"' + BOT_FAKE + '\\"; '
    '/system script run startup" policy=read,write start-time=startup\n'
    "/system script\n"
    "add dont-require-permissions=no name=startup owner=admin policy=ftp,read,write "
    'source=":global TgBotToken \\"' + BOT_FAKE + '\\";\\r\\n:global TgChatId \\"12345678\\";"\n'
    "/ip firewall filter\n"
    'add action=accept chain=input comment="#critical" connection-state=established,related\n'
)

CLEAN_EXPORT = EXPORT_TEMPLATE.format(date="jul/29/2026 18:04:11")


class SecretScanTestCase(unittest.TestCase):
    def run_main(self, argv, export=LEAKY_EXPORT):
        out, errout = io.StringIO(), io.StringIO()
        with mock.patch.object(export_config, "fetch_export",
                               return_value=(0, export, "")), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(errout):
            rc = export_config.main(argv)
        return rc, out.getvalue(), errout.getvalue()

    def test_finds_the_telegram_token_by_shape(self):
        text = 'url="https://api.telegram.org/bot%s/sendMessage"\n' % BOT_FAKE
        self.assertEqual(export_config.find_leaks(text), [(1, "telegram bot token")])

    def test_finds_a_global_assignment_with_escaped_quotes(self):
        text = ('add name=s source=":global RouterBackupPassword \\"hunter2hunter\\";"\n')
        self.assertEqual(export_config.find_leaks(text),
                         [(1, "secret assigned in a script")])

    def test_finds_underscored_secret_names(self):
        for name in ("BACKUP_PASSWORD", "CF_API_TOKEN", "my_secret_key"):
            kind = "local" if name.islower() else "global"
            text = ':%s %s "z9z9z9"\n' % (kind, name)
            self.assertEqual(export_config.find_leaks(text),
                             [(1, "secret assigned in a script")], name)
            self.assertNotIn("z9z9z9", export_config.redact_secrets(text))

    def test_finds_and_redacts_a_quoted_variable_name(self):
        for text in (':global "api-token" "supersecret"\n',
                     ':local "my-password" "supersecret"\n',
                     ':global "api-token" supersecret\n',
                     'add name=s source=":global \\"api-token\\" '
                     '\\"supersecret\\";"\n',
                     'add name=s source=":global \\"api-token\\" supersecret;"\n'):
            self.assertEqual(export_config.find_leaks(text),
                             [(1, "secret assigned in a script")], text)
            redacted = export_config.redact_secrets(text)
            self.assertNotIn("supersecret", redacted, text)
            self.assertEqual(redacted.count(export_config.REDACTED), 1, text)
            self.assertEqual(export_config.find_leaks(redacted), [], text)
        self.assertEqual(export_config.find_leaks(':global "api-name" "x"\n'), [])

    def test_finds_and_redacts_a_wireguard_preshared_key(self):
        text = ('add allowed-address=10.0.0.2/32 interface=wg0 '
                'preshared-key="Zm9vYmFyZm9vYmFy" public-key="abc"\n')
        self.assertEqual(export_config.find_leaks(text), [(1, "sensitive field")])
        redacted = export_config.redact_secrets(text)
        self.assertNotIn("Zm9vYmFyZm9vYmFy", redacted)
        self.assertIn('preshared-key="<redacted>" public-key="abc"', redacted)
        self.assertEqual(export_config.find_leaks(redacted), [])
        bare = "set [ find ] preshared-key=Zm9vYmFy\n"
        self.assertEqual(export_config.find_leaks(bare), [(1, "sensitive field")])
        self.assertEqual(export_config.redact_secrets(bare),
                         "set [ find ] preshared-key=<redacted>\n")

    def test_every_secret_global_the_scripts_use_is_detected(self):
        import re
        pattern = re.compile(
            r":(?:global|local)\s+([A-Za-z0-9_]*"
            r"(?:token|password|secret|apikey|passphrase|psk)[A-Za-z0-9_]*)",
            re.IGNORECASE)
        names = set()
        root = os.path.join(REPO_ROOT, "mikrotik")
        for base, _, files in os.walk(root):
            for fname in files:
                if fname.endswith(".lua"):
                    with open(os.path.join(base, fname), encoding="utf-8") as fh:
                        names.update(pattern.findall(fh.read()))
        self.assertIn("CF_API_TOKEN", names)
        self.assertIn("BACKUP_PASSWORD", names)
        for name in sorted(names):
            text = ':global %s "s3cr3tvalue"\n' % name
            self.assertTrue(export_config.find_leaks(text), name)

    def test_diff_with_redact_never_prints_a_stored_secret(self):
        stored = ('/system script\nadd name=s source=":global TgBotToken '
                  '\\"%s\\";"\n' % BOT_FAKE)
        live = '/system script\nadd name=s source=":global TgChatId 1;"\n'
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "router.rsc"), "w", encoding="utf-8") as fh:
                fh.write(stored)
            rc, out, err = self.run_main(
                ["--host", "router", "--name", "router", "--out", tmp, "--diff",
                 "--redact-secrets"], export=live)
        self.assertEqual(rc, 1)
        self.assertNotIn("AAH-fake", out + err)
        self.assertNotIn(BOT_FAKE, out + err)

    def test_finds_a_value_holding_escaped_backslashes(self):
        # A script's own `\\` is `\\\\` in an export, and the value goes on
        # past it. The old pattern stopped at the first backslash and found
        # nothing, so --commit could write the whole value.
        text = 'add name=s source=":global ApiPassword \\"abc\\\\def\\";"\n'
        self.assertEqual(export_config.find_leaks(text),
                         [(1, "secret assigned in a script")])
        self.assertEqual(
            export_config.redact_secrets(text),
            'add name=s source=":global ApiPassword \\"<redacted>\\";"\n',
        )
        # A trailing escaped backslash does not swallow the closing quote.
        # (script `"abc\\"` is five backslashes and a quote in an export).
        text = 'add name=s source=":global ApiPassword \\"abc\\\\\\\\\\";"\n'
        self.assertEqual(export_config.redact_secrets(text),
                         'add name=s source=":global ApiPassword \\"<redacted>\\";"\n')
        # Other escapes inside the value (\$, \n) stay part of it.
        text = 'add name=s source=":global ApiPassword \\"a\\$b\\";"\n'
        self.assertEqual(export_config.find_leaks(text),
                         [(1, "secret assigned in a script")])

    def test_a_value_holding_an_escaped_quote_is_redacted_whole(self):
        # Script value a"b: the script escapes the quote as \", and the
        # export escapes both characters, giving three backslashes and a quote.
        text = 'add name=s source=":global ApiPassword \\"a\\\\\\"b\\";"\n'
        self.assertEqual(export_config.find_leaks(text),
                         [(1, "secret assigned in a script")])
        redacted = export_config.redact_secrets(text)
        self.assertEqual(
            redacted, 'add name=s source=":global ApiPassword \\"<redacted>\\";"\n')

    def test_a_value_holding_a_literal_dollar_is_redacted_whole(self):
        # Script value a$b: the script writes \$, and the export escapes the
        # backslash as well, giving a backslash pair followed by \$.
        text = 'add name=s source=":global ApiPassword \\"a\\\\\\$b\\";"\n'
        self.assertEqual(export_config.find_leaks(text),
                         [(1, "secret assigned in a script")])
        self.assertEqual(
            export_config.redact_secrets(text),
            'add name=s source=":global ApiPassword \\"<redacted>\\";"\n')
        # Script value pa$$"\w: every special character is escaped twice.
        text = ('add name=s source=":global ApiPassword '
                '\\"pa\\\\\\$\\\\\\$\\\\\\\"\\\\\\\\w\\";"\n')
        self.assertEqual(export_config.find_leaks(text),
                         [(1, "secret assigned in a script")])
        self.assertEqual(
            export_config.redact_secrets(text),
            'add name=s source=":global ApiPassword \\"<redacted>\\";"\n')

    def test_an_escaped_variable_reference_is_not_a_value(self):
        # The export spells a script's `$other` as `\$other`.
        text = 'add name=s source=":set ApiPassword \\"\\$other\\";"\n'
        self.assertEqual(export_config.find_leaks(text), [])
        self.assertEqual(export_config.redact_secrets(text), text)

    def test_ignores_the_shipped_placeholders_and_empty_values(self):
        text = (
            'add name=s source=":local BotToken \\"token\\";\\r\\n'
            ':local Password \\"\\";\\r\\n'
            ':global RouterBackupPassword \\"<paste backup password>\\";\\r\\n'
            '# :global RouterBackupPassword \\"s3cret\\"\\r\\n'
            '/system backup save password=\\$Password"\n'
            "set wifi1 passphrase=<redacted>\n"
        )
        self.assertEqual(export_config.find_leaks(text), [])

    def test_finds_and_redacts_an_unquoted_literal(self):
        for stmt in (":global ApiPassword abc123", ":local my_token x1",
                     ":set BACKUP_PASSWORD hunter2hunter", ":global CfApiToken a-b.c"):
            for text in ("%s;\n" % stmt, "%s\n" % stmt,
                         'add name=s source="%s;\\r\\n:log info x"\n' % stmt):
                self.assertEqual(export_config.find_leaks(text),
                                 [(1, "secret assigned in a script")], text)
                redacted = export_config.redact_secrets(text)
                self.assertEqual(redacted.count(export_config.REDACTED), 1, text)
                self.assertNotIn(stmt.split()[-1], redacted, text)
                self.assertEqual(export_config.find_leaks(redacted), [], text)
                self.assertEqual(export_config.redact_secrets(redacted), redacted)
        self.assertEqual(
            export_config.redact_secrets(":global ApiPassword abc123; :log info x\n"),
            ":global ApiPassword <redacted>; :log info x\n")

    def test_an_unquoted_expression_or_declaration_is_not_a_value(self):
        for text in (":set BackupPassword $RouterBackupPassword;\n",
                     ":set Password [:pick $a 0 4]\n",
                     ":set Password ($a . $b)\n",
                     ":global TgBotToken;\n",
                     ':set Password \\$other;\n',
                     'add name=s source=":set Password \\$other;"\n'):
            self.assertEqual(export_config.find_leaks(text), [], text)
            self.assertEqual(export_config.redact_secrets(text), text)

    def test_an_unquoted_literal_stops_at_a_closing_bracket(self):
        for text, want in (
                ("add name=s do={:set password abc}\n",
                 "add name=s do={:set password <redacted>}\n"),
                (":set Password abc)\n", ":set Password <redacted>)\n"),
                (":set Password abc]\n", ":set Password <redacted>]\n")):
            self.assertEqual(export_config.find_leaks(text),
                             [(1, "secret assigned in a script")], text)
            self.assertEqual(export_config.redact_secrets(text), want)

    def test_an_unquoted_array_is_not_a_bare_literal(self):
        for text in (':global ApiToken {"a";"b"}\n',
                     ':global ApiToken {\\"a\\";\\"b\\"}\n',
                     ":global ApiToken {1;2}\n"):
            self.assertEqual(export_config.find_leaks(text), [], text)
            self.assertEqual(export_config.redact_secrets(text), text)

    def test_only_the_shipped_placeholder_assignments_are_exempt(self):
        shipped = (':local BotToken "token"\n',
                   ':global TgBotToken "<paste bot token>"\n',
                   ':global RouterBackupPassword "<paste backup password>"\n',
                   ':global RouterBackupPassword \\"<paste backup password>\\";\n',
                   ":global ApiPassword <redacted>\n",
                   ':global ApiPassword "<redacted>"\n')
        for text in shipped:
            self.assertEqual(export_config.find_leaks(text), [], text)
        flagged = (':global ApiPassword "<production-secret>"\n',
                   ':global TgBotToken "token"\n',
                   ':global ApiToken "ID"\n',
                   ':local BotToken "<paste bot token>"\n',
                   ':global RouterBackupPassword "<anything else>"\n',
                   "set wifi1 passphrase=<production-secret>\n",
                   'set wifi1 passphrase="token"\n')
        for text in flagged:
            self.assertTrue(export_config.find_leaks(text), text)
            self.assertIn(export_config.REDACTED, export_config.redact_secrets(text))

    def test_finds_sensitive_fields_and_redacts_inside_their_quotes(self):
        text = 'set [ find default-name=wlan1 ] comment="#x" passphrase="my pass"\n'
        self.assertEqual(export_config.find_leaks(text), [(1, "sensitive field")])
        self.assertEqual(
            export_config.redact_secrets(text),
            'set [ find default-name=wlan1 ] comment="#x" passphrase="<redacted>"\n',
        )

    def test_quoted_field_with_an_escaped_quote_is_redacted_whole(self):
        text = 'set wifi1 passphrase="abc\\"def" comment=x\n'
        self.assertEqual(export_config.find_leaks(text), [(1, "sensitive field")])
        redacted = export_config.redact_secrets(text)
        self.assertEqual(redacted, 'set wifi1 passphrase="<redacted>" comment=x\n')
        self.assertEqual(export_config.find_leaks(redacted), [])

    def test_quoted_field_with_an_escaped_backslash_before_the_closing_quote(self):
        text = 'set wifi1 passphrase="abc\\\\" comment=x\n'
        self.assertEqual(
            export_config.redact_secrets(text),
            'set wifi1 passphrase="<redacted>" comment=x\n')

    def test_quoted_field_with_hex_and_dollar_escapes_is_redacted_whole(self):
        text = 'set u password="a\\41b\\$c\\"d\\\\" comment=x\n'
        self.assertEqual(
            export_config.redact_secrets(text),
            'set u password="<redacted>" comment=x\n')

    def test_unterminated_quoted_field_is_a_leak_redacted_to_the_line_end(self):
        text = 'set u password="abc\\"\n'
        self.assertEqual(export_config.find_leaks(text), [(1, "sensitive field")])
        redacted = export_config.redact_secrets(text)
        self.assertNotIn("abc", redacted)
        self.assertEqual(export_config.find_leaks(redacted), [])
        # Unterminated, with more text after it: all of it goes.
        text = 'set u password="abc comment=x\n'
        self.assertEqual(export_config.find_leaks(text), [(1, "sensitive field")])
        self.assertNotIn("abc", export_config.redact_secrets(text))

    def test_quoted_field_starting_with_an_escaped_dollar_is_a_value(self):
        # `\$` in a field is a literal dollar in the secret, not a variable.
        text = 'set u password="\\$ecret" comment=x\n'
        self.assertEqual(export_config.find_leaks(text), [(1, "sensitive field")])
        self.assertEqual(
            export_config.redact_secrets(text),
            'set u password="<redacted>" comment=x\n')

    def test_a_field_holding_a_real_variable_reference_is_not_a_value(self):
        for text in ('set u password=$Password comment=x\n',
                     'set u password="$Password" comment=x\n'):
            self.assertEqual(export_config.find_leaks(text), [], text)

    def test_a_field_holding_a_routeros_expression_is_not_a_value(self):
        for text in ('set u password=$[/system/identity/get name] comment=x\n',
                     'set u password="$[/system/identity/get name]" comment=x\n',
                     'set u password="$(1+2)" comment=x\n',
                     'set u password=$(1+2) comment=x\n',
                     'set u password="$\\"name\\"" comment=x\n',
                     'set u password=$"name" comment=x\n'):
            self.assertEqual(export_config.find_leaks(text), [], text)

    def test_unquoted_name_expression_is_not_redacted(self):
        text = 'set u password=$"name" comment=x\n'
        self.assertEqual(export_config.find_leaks(text), [])
        self.assertEqual(export_config.redact_secrets(text), text)

    def test_unquoted_field_value_is_unchanged_by_the_escape_handling(self):
        text = "set u password=hunter2 comment=x\n"
        self.assertEqual(
            export_config.redact_secrets(text),
            "set u password=<redacted> comment=x\n")

    def test_findings_never_contain_the_value(self):
        findings = export_config.find_leaks(LEAKY_EXPORT)
        self.assertTrue(findings)
        for finding in findings:
            self.assertNotIn(BOT_FAKE, repr(finding))
            self.assertNotIn("AAH-fake", repr(finding))
        with tempfile.TemporaryDirectory() as tmp:
            for argv in (["--host", "router", "--scan-secrets"],
                         ["--host", "router", "--out", tmp, "--stdout", "--redact-secrets"],
                         ["--host", "router", "--out", tmp, "--diff", "--redact-secrets"],
                         ["--host", "router", "--out", tmp, "--commit"]):
                _, out, err = self.run_main(argv)
                self.assertNotIn("AAH-fake", out + err, argv)

    def test_redaction_replaces_only_the_value_and_keeps_the_rest_of_the_line(self):
        redacted = export_config.redact_secrets(LEAKY_EXPORT)
        lines = redacted.splitlines()
        self.assertEqual(
            lines[3],
            "add dont-require-permissions=no name=startup owner=admin policy=ftp,read,write "
            'source=":global TgBotToken \\"<redacted>\\";\\r\\n:global TgChatId \\"12345678\\";"',
        )
        self.assertNotIn(BOT_FAKE, redacted)
        self.assertEqual(lines[0], "/system scheduler")
        self.assertEqual(lines[5], LEAKY_EXPORT.splitlines()[5])
        self.assertEqual(len(lines), len(LEAKY_EXPORT.splitlines()))

    def test_redaction_is_idempotent(self):
        once = export_config.redact_secrets(LEAKY_EXPORT)
        self.assertEqual(export_config.redact_secrets(once), once)
        self.assertEqual(export_config.find_leaks(once), [])

    def test_a_line_continuation_is_joined_before_matching_but_reports_the_first_line(self):
        # /export wraps long lines anywhere, the middle of a token included.
        split = (
            "/system script\n"
            'add name=startup source=":global TgBotToken \\"123456789:AAH-fake_fake_fake_fa\\\n'
            '    ke_fake_fake_fake_fake1\\";"\n'
            "/ip address\n"
        )
        findings = export_config.find_leaks(split)
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
        self.assertEqual(export_config.find_leaks(CLEAN_EXPORT), [])
        self.assertEqual(export_config.redact_secrets(CLEAN_EXPORT), CLEAN_EXPORT)

    def test_scan_file_needs_no_host_and_no_ssh(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "router.rsc")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(LEAKY_EXPORT)
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
            self.assertNotIn(BOT_FAKE, stored)
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


class UnverifiableAssignmentTestCase(unittest.TestCase):
    """The scan fails closed: what it cannot read with confidence blocks
    --commit instead of passing."""

    def run_main(self, argv, export):
        out, errout = io.StringIO(), io.StringIO()
        with mock.patch.object(export_config, "fetch_export",
                               return_value=(0, export, "")), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(errout):
            rc = export_config.main(argv)
        return rc, out.getvalue(), errout.getvalue()

    def assert_commit_blocked(self, export, reason, redacting_too=True):
        # Redaction replaces a value, so it cannot repair a quote that never
        # closes, but it does remove a value whose only fault was its escapes.
        variants = [[], ["--redact-secrets"]] if redacting_too else [[]]
        for extra in variants:
            with tempfile.TemporaryDirectory() as tmp:
                git = mock.Mock(return_value=(0, "", ""))
                with mock.patch.object(export_config, "git", git):
                    rc, _, err = self.run_main(
                        ["--host", "router", "--out", tmp, "--commit"] + extra, export)
                self.assertEqual(rc, 1, extra)
                git.assert_not_called()
                self.assertEqual(os.listdir(tmp), [], extra)
                self.assertIn("line 2", err, extra)
                self.assertIn(reason, err, extra)
                self.assertNotIn("hunter2", err, extra)

    def assert_commit_proceeds(self, export):
        def fake_git(args, cwd):
            if args[:1] == ["diff"]:
                return 0, " router.rsc | 3 +++\n", ""
            return 0, "", ""

        with tempfile.TemporaryDirectory() as tmp:
            git = mock.Mock(side_effect=fake_git)
            with mock.patch.object(export_config, "git", git):
                rc, _, err = self.run_main(
                    ["--host", "router", "--out", tmp, "--commit"], export)
            self.assertEqual(rc, 0, err)
            self.assertTrue(any(c.args[0][:1] == ["commit"] for c in git.call_args_list))

    def test_an_unbalanced_quote_in_a_secret_assignment_blocks_commit(self):
        export = '/system script\nadd name=s source=":global ApiToken \\"hunter2;"\n'
        self.assertEqual(export_config.find_unverifiable(export),
                         [(2, "unbalanced quote")])
        self.assert_commit_blocked(export, "unbalanced quote")

    def test_an_unbalanced_plain_quote_blocks_commit(self):
        export = '/system script\n:global ApiPassword "hunter2\n'
        self.assertEqual(export_config.find_unverifiable(export),
                         [(2, "unbalanced quote")])
        self.assert_commit_blocked(export, "unbalanced quote")

    def test_an_unknown_escape_blocks_commit(self):
        # Script value ab\qc: \q is not a RouterOS escape.
        inner = 'add name=s source=":global ApiToken \\"hunter2\\\\qc\\";"\n'
        self.assertEqual(export_config.find_unverifiable("/x\n" + inner),
                         [(2, "unrecognized escape in the value")])
        self.assert_commit_blocked("/x\n" + inner, "unrecognized escape", False)
        # The same unknown escape in the export's own layer.
        outer = 'add name=s source=":global ApiToken \\"hunter2\\q\\";"\n'
        self.assertEqual([r for _, r in export_config.find_unverifiable("/x\n" + outer)],
                         ["unrecognized escape"])
        self.assert_commit_blocked("/x\n" + outer, "unrecognized escape", False)

    def test_an_ambiguous_hex_escape_is_unverifiable(self):
        text = '/x\nadd name=s source=":global ApiToken \\"hunter2\\\\ab\\";"\n'
        self.assertEqual(export_config.find_unverifiable(text),
                         [(2, "ambiguous escape in the value")])

    def test_a_stray_quote_inside_the_field_is_unverifiable(self):
        text = '/x\nadd name=s source=":global ApiToken "hunter2" ;"\n'
        self.assertEqual(export_config.find_unverifiable(text),
                         [(2, "unescaped quote inside a quoted field")])
        self.assert_commit_blocked(text, "unescaped quote")

    def test_a_name_that_cannot_be_extracted_is_unverifiable(self):
        for stmt in (":global $x 1", ":set (a) 1", ":global", ':set "a$b" 1',
                     ":global Name$x 1"):
            text = "/x\n%s\n" % stmt
            self.assertEqual(len(export_config.find_unverifiable(text)), 1, stmt)
        self.assertEqual(export_config.find_unverifiable("/x\n:local i 0; :set i 1\n"), [])

    def test_an_expression_that_may_hold_a_literal_is_unverifiable(self):
        for stmt in (':set Password "$other hunter2"', ':set Password ($a . "hunter2")',
                     ":set Password [:pick $a 0", ":set Password $a-hunter2",
                     ':global ApiToken {"hunter2"}', ":global ApiToken {1;2}",
                     ':set Password "[:pick $a 0 4] hunter2"',
                     # A bare word inside brackets is a literal in RouterOS.
                     ":global ApiToken [:tostr hunter2]",
                     ":set Password [:pick s3cretvalue 0 8]",
                     ":set Password $[:tostr hunter2]",
                     ":set Password (hunter2)",
                     ":set Password [:tostr {hunter2}]",
                     ":set Password [:tostr [:tostr hunter2]]",
                     ":set Password [:pick $a 0 4 hunter2]",
                     # Accepted fail-closed false positive: `value` and `x` are
                     # bare words, and so is `name` here.
                     ":set Password [/system script environment get [find name=x] value]",
                     ":set Password $[/system/identity/get name]"):
            text = "/x\n%s\n" % stmt
            self.assertEqual(len(export_config.find_unverifiable(text)), 1, stmt)

    def test_expressions_that_hold_no_literal_are_verifiable(self):
        for stmt in (":set BackupPassword $RouterBackupPassword;",
                     ":set Password [:pick $a 0 4]", ":set Password ($a . $b)",
                     ':set Password "$other"', ':set Password "[:pick $a 0 4]"',
                     ":global TgBotToken;", ":global ApiToken {}",
                     ":set Password $[/system/identity/get $name]",
                     ":set Password [:tostr [:pick $a 0 4]]",
                     ':global Password ""'):
            self.assertEqual(export_config.find_unverifiable("/x\n%s\n" % stmt), [],
                             stmt)
        self.assertEqual(export_config.find_unverifiable(
            'add name=s source=":set Password \\$other;"\n'), [])

    def test_a_secret_literal_is_a_leak_not_an_unverifiable_finding(self):
        for stmt in (':global ApiPassword "abc123"', ":global ApiPassword abc123",
                     ':local BotToken "<paste bot token>"'):
            text = "/x\n%s\n" % stmt
            self.assertTrue(export_config.find_leaks(text), stmt)
            self.assertEqual(export_config.find_unverifiable(text), [], stmt)

    def test_a_normal_non_secret_script_still_commits(self):
        export = (
            "/system script\n"
            'add name=s source=":local i 0;\\r\\n:global TgChatId \\"12345678\\";\\r\\n'
            ':log info \\"hello\\";\\r\\n:set i ($i + 1)"\n'
            "/ip firewall filter\n"
            "add action=accept chain=input\n"
        )
        self.assertEqual(export_config.find_unverifiable(export), [])
        self.assertEqual(export_config.find_leaks(export), [])
        self.assert_commit_proceeds(export)

    def test_the_known_redacted_placeholder_still_commits(self):
        export = (
            "/system script\n"
            'add name=s source=":global TgBotToken \\"<redacted>\\";\\r\\n'
            ':global RouterBackupPassword \\"<paste backup password>\\";"\n'
        )
        self.assertEqual(export_config.find_unverifiable(export), [])
        self.assert_commit_proceeds(export)
        # A real token redacted by --redact-secrets ends up in that same shape.
        redacted = export_config.redact_secrets(LEAKY_EXPORT)
        self.assertEqual(export_config.find_unverifiable(redacted), [])

    def test_a_comment_example_with_a_placeholder_is_not_an_assignment(self):
        text = ('add name=s source="# :global RouterBackupPassword '
                '\\"<paste backup password>\\"\\r\\n'
                '# :set Password \\"<redacted>\\"\\r\\n:log info x"\n')
        self.assertEqual(export_config.find_unverifiable(text), [])
        self.assertEqual(export_config.find_leaks(text), [])

    def test_a_comment_example_with_a_real_looking_value_is_reported(self):
        # Fail closed: a commented-out line is still in git history, and the
        # scan cannot tell an example from a secret somebody disabled.
        text = ('add name=s source="# :global RouterBackupPassword \\"s3cret\\r\\n'
                '# :set Password \\"\\r\\n:log info x"\n')
        self.assertEqual(export_config.find_unverifiable(text),
                         [(1, "commented assignment with a literal")])

    def assert_leak_blocks_commit(self, export):
        with tempfile.TemporaryDirectory() as tmp:
            git = mock.Mock(return_value=(0, "", ""))
            with mock.patch.object(export_config, "git", git):
                rc, _, err = self.run_main(
                    ["--host", "router", "--out", tmp, "--commit"], export)
            self.assertEqual(rc, 1)
            git.assert_not_called()
            self.assertEqual(os.listdir(tmp), [])
            self.assertNotIn("hunter2", err)

    def test_a_backslash_n_in_plain_script_is_not_a_line_break(self):
        # In a plain script `\n` is a string escape, so the `#` is inside the
        # string and the :global after it is a live assignment.
        export = '/x\n:log info "a\\n# x"; :global ApiToken "hunter2"\n'
        self.assertEqual(export_config.find_leaks(export),
                         [(2, "secret assigned in a script")])
        self.assertNotIn("hunter2", export_config.redact_secrets(export))
        self.assert_leak_blocks_commit(export)

    def test_an_escaped_backslash_n_in_an_export_is_not_a_line_break(self):
        # The script's own backslash-n arrives as backslash-backslash-n.
        export = ('/x\nadd name=s source=":log info \\"a\\\\n# x\\"; '
                  ':global ApiToken \\"hunter2\\""\n')
        self.assertEqual(export_config.find_leaks(export),
                         [(2, "secret assigned in a script")])
        self.assertNotIn("hunter2", export_config.redact_secrets(export))
        self.assert_leak_blocks_commit(export)

    def test_a_real_line_break_in_an_export_ends_a_comment(self):
        live = '/x\nadd name=s source="# note\\n:global ApiToken \\"hunter2\\""\n'
        self.assertEqual(export_config.find_leaks(live),
                         [(2, "secret assigned in a script")])
        commented = ('/x\nadd name=s source="# :global ApiToken \\"hunter2\\"'
                     '\\n:log info x"\n')
        # Not a live leak, but a commented secret is still reported.
        self.assertEqual(export_config.find_leaks(commented), [])
        self.assertEqual(export_config.find_unverifiable(commented),
                         [(2, "commented assignment with a literal")])
        for harmless in ('# :global Hostname \\"hunter2\\"',
                         '# :global ApiToken \\"<redacted>\\"',
                         '# :global TgBotToken \\"<paste bot token>\\"'):
            text = ('/x\nadd name=s source="%s\\n:log info x"\n' % harmless)
            self.assertEqual(export_config.find_leaks(text), [], harmless)
            self.assertEqual(export_config.find_unverifiable(text), [], harmless)

    def test_numbers_inside_an_expression_may_be_the_secret(self):
        # (12345678) and [:tostr 12345678] hold a literal as surely as a word.
        for stmt in (":set WifiPassword (12345678)",
                     ":set WifiPassword [:tostr 12345678]",
                     ":set WifiPassword $[:tostr 12345678]",
                     ':set WifiPassword "$[:tostr 12345678]"',
                     ":set ApiToken (10.20.30.40.50.60)",
                     ":set ApiToken [:tostr 1234]",
                     ":set ApiToken (123.4)"):
            text = "/x\n%s\n" % stmt
            self.assertEqual(export_config.find_unverifiable(text),
                             [(2, "expression value that may hold a literal")], stmt)
            self.assert_commit_blocked(text, "expression value that may hold a literal")
        export_form = '/x\nadd name=s source=":set WifiPassword [:tostr 12345678]"\n'
        self.assertEqual(export_config.find_unverifiable(export_form),
                         [(2, "expression value that may hold a literal")])
        self.assert_commit_blocked(export_form, "expression value that may hold a literal")

    def test_small_numbers_in_an_expression_are_still_accepted(self):
        for stmt in (":set ApiToken [:pick $a 0 4]", ":set ApiToken ($a + 1)",
                     ':set ApiToken "$[:pick $a 0 999]"'):
            text = "/x\n%s\n" % stmt
            self.assertEqual(export_config.find_unverifiable(text), [], stmt)
            self.assertEqual(export_config.find_leaks(text), [], stmt)

    def test_a_quoted_value_starting_with_a_bracket_is_a_literal_string(self):
        # Only a leading $ makes a quoted value an expression in RouterOS.
        for stmt in (':set ApiToken "[hunter2]"', ':set ApiToken "(hunter2)"',
                     ':set ApiToken "[12345678]"', ':set ApiToken "(12345678)"'):
            text = "/x\n%s\n" % stmt
            self.assertEqual(export_config.find_leaks(text),
                             [(2, "secret assigned in a script")], stmt)
            self.assertNotIn("hunter2", export_config.redact_secrets(text))
            self.assert_leak_blocks_commit(text)
        export_form = '/x\nadd name=s source=":set ApiToken \\"[hunter2]\\""\n'
        self.assertEqual(export_config.find_leaks(export_form),
                         [(2, "secret assigned in a script")])
        self.assert_leak_blocks_commit(export_form)

    def test_a_string_that_ends_in_equals_does_not_open_an_export_field(self):
        # "a=" is a closed plain string; a later backslash-n is not a line
        # break in plain script, so the "#" is not a comment start.
        text = '/x\n:global k "a="; :put \\n#; :set ApiToken hunter2\n'
        self.assertEqual(export_config.find_leaks(text),
                         [(2, "secret assigned in a script")])
        self.assert_leak_blocks_commit(text)
        # Even a script-field name inside a line that is not an export.
        text = '/x\n:global k "source=\\"x"; :put \\n#; :set ApiToken hunter2\n'
        self.assertEqual(export_config.find_leaks(text),
                         [(2, "secret assigned in a script")])
        # A field that holds no script is not a script field either.
        self.assert_leak_blocks_commit(
            '/x\nadd name=s comment="a=" source=":put x; :set ApiToken hunter2"\n')

    def test_a_real_export_field_still_ends_a_comment_at_a_break(self):
        for field in ("source", "on-event", "on-up", "on-down", "on-login",
                      "on-logout", "script", "do"):
            live = ('/x\nadd name=s %s="# note\\r\\n:set ApiToken \\"hunter2\\""\n'
                    % field)
            self.assertEqual(export_config.find_leaks(live),
                             [(2, "secret assigned in a script")], field)

    def test_a_commented_secret_assignment_blocks_commit(self):
        plain = "/x\n# :set ApiToken realtok\n"
        in_source = ('/x\nadd name=s source=":log info x\\r\\n'
                     '# :set ApiToken \\"realtoken123\\""\n')
        for text in (plain, in_source, "/x\n#:set ApiToken realtok\n",
                     '/x\n# :global ApiToken "realtok"\n'):
            self.assertEqual(export_config.find_unverifiable(text),
                             [(2, "commented assignment with a literal")], text)
            self.assert_commit_blocked(text, "commented assignment with a literal")

    def test_commented_placeholders_and_other_names_stay_clean(self):
        for text in ("/x\n# :set ApiToken <redacted>\n",
                     '/x\n# :set ApiToken "<redacted>"\n',
                     '/x\n# :global TgBotToken "<paste bot token>"\n',
                     "/x\n# :set ApiToken $other\n",
                     "/x\n# :set Hostname realtok\n",
                     "/x\n# use :set to change a value\n"):
            self.assertEqual(export_config.find_unverifiable(text), [], text)
            self.assertEqual(export_config.find_leaks(text), [], text)

    def test_a_keyword_glued_to_the_next_character_is_still_read(self):
        for stmt in (':global"ApiToken" "hunter2"', ':set"ApiToken" "hunter2"',
                     ":set(ApiToken) hunter2"):
            text = "/x\n%s\n" % stmt
            self.assertEqual(len(export_config.find_unverifiable(text)), 1, stmt)
            self.assert_commit_blocked(text, "", False)

    def test_a_closed_field_before_the_keyword_is_not_an_export(self):
        text = '/tool fetch url="https://e.x"; :set ApiToken "$x"\n'
        self.assertEqual(export_config.find_unverifiable(text), [])
        text = '/x\n/tool fetch url="https://e.x"; :set ApiToken "hunter2;\n'
        self.assertEqual(export_config.find_unverifiable(text),
                         [(2, "unbalanced quote")])

    def test_a_commit_is_blocked_by_an_expression_with_a_bare_word(self):
        text = "/x\n:global ApiToken [:tostr hunter2]\n"
        self.assertEqual(export_config.find_unverifiable(text),
                         [(2, "expression value that may hold a literal")])
        self.assert_commit_blocked(text, "expression value that may hold a literal")

    def test_the_leaky_export_has_nothing_unverifiable(self):
        self.assertEqual(export_config.find_unverifiable(LEAKY_EXPORT), [])

    def test_print_only_output_warns_and_still_redacts(self):
        export = '/system script\nadd name=s source=":global ApiToken \\"hunter2;"\n'
        rc, out, err = self.run_main(["--host", "router", "--stdout"], export)
        self.assertEqual(rc, 0)
        self.assertIn("cannot verify", err)
        self.assertIn("(lines 2)", err)
        rc, out, err = self.run_main(
            ["--host", "router", "--stdout", "--redact-secrets"], export)
        self.assertEqual(rc, 0)
        self.assertNotIn("hunter2", out)

    def test_a_plain_write_warns_and_still_writes(self):
        export = '/system script\n:global ApiPassword "hunter2\n'
        with tempfile.TemporaryDirectory() as tmp:
            rc, _, err = self.run_main(["--host", "router", "--out", tmp], export)
            self.assertEqual(rc, 0)
            self.assertIn("cannot verify", err)
            self.assertEqual(os.listdir(tmp), ["router.rsc"])

    def test_scans_report_unverifiable_findings_and_exit_1(self):
        export = '/system script\n:global ApiPassword "hunter2\n'
        rc, out, _ = self.run_main(["--host", "router", "--scan-secrets"], export)
        self.assertEqual(rc, 1)
        self.assertIn("line 2: unverifiable: unbalanced quote", out)
        self.assertIn("1 finding(s)", out)
        self.assertNotIn("hunter2", out)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "router.rsc")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(export)
            out = io.StringIO()
            with contextlib.redirect_stdout(out), \
                 contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(export_config.main(["--scan-file", path]), 1)
            self.assertIn("unverifiable", out.getvalue())

    def test_there_is_no_override_flag(self):
        errout = io.StringIO()
        with contextlib.redirect_stderr(errout), self.assertRaises(SystemExit) as raised:
            export_config.main(["--host", "router", "--commit", "--allow-unverified"])
        self.assertEqual(raised.exception.code, 3)


SUMMARY_BEFORE = """\
/interface bridge
add name=bridge
/ip firewall filter
add action=accept chain=input comment="defconf: accept established" \\
    connection-state=established,related
add action=drop chain=input comment="block the scanner" src-address=203.0.113.77
/ip dns
set servers=1.1.1.1
"""


class SummaryTestCase(unittest.TestCase):
    """--diff --summary: what kind of change happened, without the change.

    The unified diff of a real router is hundreds of lines and carries rule
    bodies, comments and addresses into whatever it is pasted into. The summary
    is counts per menu, so it is safe in a ticket or an alert text.
    """

    def run_diff(self, stored, live, extra=("--summary",)):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "router.rsc")
            if stored is not None:
                with open(dest, "w", encoding="utf-8") as fh:
                    fh.write(stored)
            before = sorted(os.listdir(tmp))
            stdout = io.StringIO()
            with mock.patch.object(export_config, "fetch_export",
                                   return_value=(0, live, "")), \
                 contextlib.redirect_stdout(stdout), \
                 contextlib.redirect_stderr(io.StringIO()):
                rc = export_config.main(["--host", "router", "--name", "router",
                                         "--out", tmp, "--diff"] + list(extra))
            after = sorted(os.listdir(tmp))
            content = None
            if stored is not None:
                with open(dest, encoding="utf-8") as fh:
                    content = fh.read()
        return rc, stdout.getvalue(), before, after, content

    def test_added_rule_counts_plus_one_in_its_menu(self):
        after = SUMMARY_BEFORE.replace("add name=bridge\n", "add name=bridge\nadd name=guest\n")
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, after),
                         [("/interface bridge", 1, 0)])

    def test_removed_rule_counts_minus_one(self):
        after = SUMMARY_BEFORE.replace(
            'add action=drop chain=input comment="block the scanner" src-address=203.0.113.77\n', ""
        )
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, after),
                         [("/ip firewall filter", 0, 1)])

    def test_modified_rule_is_plus_one_minus_one_in_the_same_menu(self):
        after = SUMMARY_BEFORE.replace("203.0.113.77", "203.0.113.78")
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, after),
                         [("/ip firewall filter", 1, 1)])

    def test_continuation_lines_are_one_rule(self):
        # The same rule, wrapped differently by /export, is not a change; the
        # same rule with its continued half edited is one change, not two.
        unwrapped = SUMMARY_BEFORE.replace(" \\\n    connection-state", " connection-state")
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, unwrapped), [])
        edited = SUMMARY_BEFORE.replace("connection-state=established,related",
                                        "connection-state=established")
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, edited),
                         [("/ip firewall filter", 1, 1)])

    def test_two_menus_are_reported_separately_and_in_file_order(self):
        after = (SUMMARY_BEFORE
                 .replace("set servers=1.1.1.1", "set servers=9.9.9.9")
                 .replace("add name=bridge\n", "add name=bridge\nadd name=guest\n"))
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, after),
                         [("/interface bridge", 1, 0), ("/ip dns", 1, 1)])

    def test_lines_before_the_first_header_go_to_top(self):
        self.assertEqual(
            export_config.summarise_diff("x=1\n/ip address\nadd address=192.0.2.1/24\n",
                                         "x=2\n/ip address\nadd address=192.0.2.1/24\n"),
            [("(top)", 1, 1)],
        )

    def test_terse_export_uses_the_path_before_add(self):
        before = "/ip firewall filter add chain=input action=accept\n"
        after = before + (
            "/ip firewall filter add chain=input action=drop\n/ip dns set servers=9.9.9.9\n"
        )
        self.assertEqual(export_config.summarise_diff(before, after),
                         [("/ip firewall filter", 1, 0), ("/ip dns", 1, 0)])

    def test_comments_and_blank_lines_are_ignored(self):
        after = "# aug/03/2026 09:12:47 by RouterOS 7.22\n\n" + SUMMARY_BEFORE.replace(
            "/ip dns\n", "/ip dns\n# a note\n\n"
        )
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, after), [])

    def test_a_reorder_is_reported_without_counts(self):
        lines = SUMMARY_BEFORE.splitlines(keepends=True)
        swapped = "".join(lines[:3] + lines[5:6] + lines[3:5] + lines[6:])
        rows = export_config.summarise_diff(SUMMARY_BEFORE, swapped)
        self.assertEqual(rows, [("/ip firewall filter", 0, 0)])
        self.assertIn("order changed", export_config.render_summary(rows))

    def test_output_never_contains_rule_bodies(self):
        after = SUMMARY_BEFORE.replace("203.0.113.77", "203.0.113.99")
        table = export_config.render_summary(export_config.summarise_diff(SUMMARY_BEFORE, after))
        for secret in ("203.0.113", "block the scanner", "chain=input", "action=drop"):
            self.assertNotIn(secret, table)
        self.assertIn("/ip firewall filter", table)
        self.assertTrue(table.endswith("total: +1 -1 in 1 menu(s)\n"))

    def test_identical_texts_yield_an_empty_list(self):
        self.assertEqual(export_config.summarise_diff(SUMMARY_BEFORE, SUMMARY_BEFORE), [])
        self.assertEqual(export_config.summarise_diff("", ""), [])

    def test_summary_without_diff_is_exit_3(self):
        fetch = mock.Mock(return_value=(0, SUMMARY_BEFORE, ""))
        with mock.patch.object(export_config, "fetch_export", fetch), \
             contextlib.redirect_stdout(io.StringIO()), \
             contextlib.redirect_stderr(io.StringIO()):
            for extra in ([], ["--stdout"], ["--commit"]):
                rc = export_config.main(["--host", "router", "--summary"] + extra)
                self.assertEqual(rc, 3, extra)
        fetch.assert_not_called()

    def test_diff_summary_exits_1_on_drift_and_0_when_equal(self):
        after = SUMMARY_BEFORE.replace("203.0.113.77", "203.0.113.99")
        rc, out, _, _, _ = self.run_diff(SUMMARY_BEFORE, after)
        self.assertEqual(rc, 1)
        self.assertIn("/ip firewall filter", out)
        self.assertNotIn("203.0.113", out)
        self.assertNotIn("@@", out)
        rc, out, _, _, _ = self.run_diff(SUMMARY_BEFORE, SUMMARY_BEFORE)
        self.assertEqual(rc, 0)
        self.assertNotIn("total:", out)

    def test_diff_summary_writes_nothing(self):
        after = SUMMARY_BEFORE.replace("203.0.113.77", "203.0.113.99")
        rc, _, before, files_after, content = self.run_diff(SUMMARY_BEFORE, after)
        self.assertEqual(rc, 1)
        self.assertEqual(files_after, before)
        self.assertEqual(content, SUMMARY_BEFORE)
        rc, out, before, files_after, _ = self.run_diff(None, SUMMARY_BEFORE)
        self.assertEqual(rc, 1)
        self.assertEqual(files_after, before)
        self.assertEqual(files_after, [])
        self.assertIn("total: +4 -0 in 3 menu(s)", out)


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

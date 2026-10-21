"""Tests for mikrotik/features/router_doctor.py.

Only the layer between the router's answer and the verdict is covered, which is
where all the judgement lives: what counts as "scheduled", what counts as a
finding rather than a choice, and what the tool is allowed to know about a
secret. The ssh call either reaches a router or it does not, and stubbing it
would test the stub.

Two of these guard mistakes the tool exists to catch, so they are worth naming:
`backup` must not be reported as scheduled because some other entry mentions
`backup_file_cleanup`, and a global's value must never be fetched — only its
length, which is what makes "TgBotToken is set" printable at all.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "mikrotik", "features"))

import router_doctor  # noqa: E402

# Shape of the probe's output from a router with a partial install: health_check
# is installed but nothing runs it, and "startup" is somebody's own script.
REPORT = """\
SCR:tg_send
SCR:backup
SCR:health_check
SCR:backup_file_cleanup
SCR:startup
SCH:backup|1d|/system script run backup
SCH:backup_file_cleanup|1d|/system script run backup_file_cleanup
SCH:startup|00:00:00|/system script run startup
ENV:TgBotToken|46
ENV:TgChatId|9
"""

PACKAGE = ["backup", "backup_file_cleanup", "health_check", "tg_send"]


def levels_for(findings, needle):
    """The levels of every finding whose message contains needle."""
    return [level for level, message in findings if needle in message]


class ParseReportTestCase(unittest.TestCase):
    def test_scripts_schedulers_and_globals_are_separated(self):
        scripts, schedulers, env = router_doctor.parse_report(REPORT)
        self.assertEqual(
            scripts, ["tg_send", "backup", "health_check", "backup_file_cleanup", "startup"]
        )
        self.assertEqual([s["name"] for s in schedulers],
                         ["backup", "backup_file_cleanup", "startup"])
        self.assertEqual(env, {"TgBotToken": 46, "TgChatId": 9})

    def test_interval_and_on_event_are_kept(self):
        _, schedulers, _ = router_doctor.parse_report(REPORT)
        self.assertEqual(schedulers[0]["interval"], "1d")
        self.assertEqual(schedulers[0]["on_event"], "/system script run backup")

    def test_a_multi_line_on_event_stays_with_its_scheduler(self):
        # An on-event is free-form and RouterOS returns it verbatim, newlines
        # included. Treating those lines as junk would lose the script name.
        text = (
            "SCH:notify-boot|00:00:00|:delay 20s;\n"
            ":local S [:parse [/system script get tg_send source]];\n"
            "$S MessageText=(\"back online\");\n"
            "ENV:TgChatId|9\n"
        )
        _, schedulers, env = router_doctor.parse_report(text)
        self.assertEqual(len(schedulers), 1)
        self.assertIn("tg_send", schedulers[0]["on_event"])
        self.assertIn("back online", schedulers[0]["on_event"])
        self.assertEqual(env, {"TgChatId": 9})

    def test_carriage_returns_do_not_end_up_in_names(self):
        scripts, _, env = router_doctor.parse_report("SCR:backup\r\nENV:TgChatId|9\r\n")
        self.assertEqual(scripts, ["backup"])
        self.assertEqual(env, {"TgChatId": 9})

    def test_an_unreadable_length_is_treated_as_empty(self):
        _, _, env = router_doctor.parse_report("ENV:TgChatId|nan\n")
        self.assertEqual(env, {"TgChatId": 0})

    def test_empty_output_parses_to_nothing(self):
        self.assertEqual(router_doctor.parse_report(""), ([], [], {}))

    def test_pause_control_is_parsed_without_exposing_secrets(self):
        _, _, env = router_doctor.parse_report(
            "ENV:TgBotToken|46\nCTL:OpsToolboxPaused|true\n"
        )
        self.assertEqual(env["TgBotToken"], 46)
        self.assertIs(env[router_doctor.PAUSE_STATE_KEY], True)

    def test_false_pause_control_is_not_reported_as_active(self):
        _, _, env = router_doctor.parse_report("CTL:OpsToolboxPaused|false\n")
        self.assertIs(env[router_doctor.PAUSE_STATE_KEY], False)


class RunsScriptTestCase(unittest.TestCase):
    def test_a_longer_name_does_not_match_a_shorter_one(self):
        # The regression this function exists for: reporting backup as scheduled
        # because backup_file_cleanup is.
        on_event = "/system script run backup_file_cleanup"
        self.assertTrue(router_doctor.runs_script(on_event, "backup_file_cleanup"))
        self.assertFalse(router_doctor.runs_script(on_event, "backup"))

    def test_a_hyphenated_name_matches(self):
        self.assertTrue(
            router_doctor.runs_script("/system script run reboot-and-flush",
                                      "reboot-and-flush")
        )

    def test_a_name_inside_inline_code_matches(self):
        on_event = ':local S [:parse [/system script get tg_send source]]; $S MessageText="x"'
        self.assertTrue(router_doctor.runs_script(on_event, "tg_send"))

    def test_an_absent_name_does_not_match(self):
        self.assertFalse(router_doctor.runs_script("/system script run backup", "vpn_health"))


class SchedulersForTestCase(unittest.TestCase):
    def test_matches_on_the_on_event(self):
        _, schedulers, _ = router_doctor.parse_report(REPORT)
        found = router_doctor.schedulers_for("backup", schedulers)
        self.assertEqual([s["name"] for s in found], ["backup"])

    def test_matches_a_scheduler_named_after_the_script(self):
        schedulers = [{"name": "vpn_health", "interval": "5m", "on_event": ":log info x"}]
        self.assertEqual(len(router_doctor.schedulers_for("vpn_health", schedulers)), 1)

    def test_returns_nothing_when_no_entry_runs_it(self):
        _, schedulers, _ = router_doctor.parse_report(REPORT)
        self.assertEqual(router_doctor.schedulers_for("health_check", schedulers), [])


class GlobalStateTestCase(unittest.TestCase):
    def test_a_length_means_set(self):
        self.assertEqual(router_doctor.global_state("TgChatId", {"TgChatId": 9}), "set")

    def test_zero_length_means_empty(self):
        # `:global TgChatId ""` in a startup script looks configured and is
        # not, which is worth telling apart from never having been set.
        self.assertEqual(router_doctor.global_state("TgChatId", {"TgChatId": 0}), "empty")

    def test_an_unknown_name_is_absent(self):
        self.assertEqual(router_doctor.global_state("TgChatId", {}), "absent")


class ProbeIsReadOnlyTestCase(unittest.TestCase):
    def test_the_probe_asks_for_the_length_of_a_global_not_its_value(self):
        # The one line in this tool that could leak a Telegram token. It asks
        # the router to measure the value, so nothing secret is ever returned.
        self.assertIn(":len", router_doctor.PROBE)
        self.assertIn("/system script environment get $e name", router_doctor.PROBE)
        self.assertNotIn('. [/system script environment get $e value]',
                         router_doctor.PROBE)

    def test_the_probe_only_reads(self):
        for verb in (" set ", " add ", " remove ", " enable ", " disable "):
            self.assertNotIn(verb, router_doctor.PROBE)

    def test_the_non_secret_pause_control_is_reported_explicitly(self):
        self.assertNotIn(":global OpsToolboxPaused", router_doctor.PROBE)
        self.assertIn("/system script environment", router_doctor.PROBE)
        self.assertIn("CTL:OpsToolboxPaused", router_doctor.PROBE)


class LocalScriptNamesTestCase(unittest.TestCase):
    def test_lua_files_become_router_script_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("backup.lua", "tg_send.lua", "README.md", "export_config.py"):
                with open(os.path.join(tmp, name), "w", encoding="utf-8") as fh:
                    fh.write("x")
            self.assertEqual(router_doctor.local_script_names(tmp), ["backup", "tg_send"])

    def test_a_missing_directory_is_not_an_error(self):
        # The script has to survive being copied on its own into ~/bin.
        self.assertEqual(router_doctor.local_script_names("/nonexistent/mikrotik"), [])

    def test_an_unreadable_subdirectory_raises_rather_than_shortening(self):
        """A partial list is the worst answer here, so it is not an answer.

        os.walk swallows a per-directory scandir error by default and keeps
        going, which returns a list that looks complete. build_findings() then
        reports every script it could not read as one the router has and the
        package does not - with core/ unreadable, the three deployed scripts
        come back as strangers, under 'info', in a tool whose whole job is to
        say what is missing.
        """
        with tempfile.TemporaryDirectory() as tmp:
            core = os.path.join(tmp, "core")
            os.mkdir(core)
            for path in (os.path.join(core, "backup.lua"),
                         os.path.join(tmp, "tg_send.lua")):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write("x")
            # chmod cannot revoke read access from root, which is who the
            # container suite runs as, so the failure is injected where os.walk
            # meets the filesystem.
            real_scandir = os.scandir

            def refuse_core(path=".", *args, **kwargs):
                if str(path) == core:
                    raise PermissionError(13, "Permission denied", str(path))
                return real_scandir(path, *args, **kwargs)

            with mock.patch("os.scandir", refuse_core), self.assertRaises(OSError):
                router_doctor.local_script_names(tmp)

    def test_this_repository_ships_the_scripts_it_documents(self):
        names = router_doctor.local_script_names(os.path.join(REPO_ROOT, "mikrotik"))
        self.assertIn("tg_send", names)
        self.assertIn("backup", names)


class BuildFindingsTestCase(unittest.TestCase):
    def parsed(self, text=REPORT):
        return router_doctor.parse_report(text)

    def test_installed_but_unscheduled_is_a_warning(self):
        installed, schedulers, env = self.parsed()
        findings = router_doctor.build_findings(PACKAGE, installed, schedulers, env)
        self.assertEqual(levels_for(findings, "health_check is installed but no scheduler"),
                         ["warn"])

    def test_a_scheduler_for_a_missing_script_is_a_failure(self):
        # The scheduler runs, finds nothing, and logs. Nothing else says so.
        installed = ["tg_send", "health_check"]
        schedulers = [{"name": "backup", "interval": "1d",
                       "on_event": "/system script run backup"}]
        findings = router_doctor.build_findings(
            PACKAGE, installed, schedulers, {"TgBotToken": 46, "TgChatId": 9}
        )
        self.assertEqual(levels_for(findings, "backup is scheduled but not in"), ["fail"])

    def test_a_missing_tg_send_fails_the_whole_package(self):
        installed = ["backup", "health_check"]
        schedulers = [{"name": "backup", "interval": "1d",
                       "on_event": "/system script run backup"},
                      {"name": "health_check", "interval": "5m",
                       "on_event": "/system script run health_check"}]
        findings = router_doctor.build_findings(
            PACKAGE, installed, schedulers, {"TgBotToken": 46, "TgChatId": 9}
        )
        self.assertEqual(levels_for(findings, "tg_send is not installed"), ["fail"])

    def test_a_script_that_is_simply_not_installed_is_context_not_a_finding(self):
        # Nobody wants ddns_update without Cloudflare. Warning about it would
        # train people to ignore the output.
        installed, schedulers, env = self.parsed()
        findings = router_doctor.build_findings(
            PACKAGE + ["ddns_update"], installed, schedulers, env
        )
        self.assertEqual(levels_for(findings, "ddns_update"), ["info"])

    def test_scheduling_a_manual_script_is_a_warning(self):
        installed = ["tg_send", "reboot-and-flush"]
        schedulers = [{"name": "nightly-reboot", "interval": "1d",
                       "on_event": "/system script run reboot-and-flush"}]
        findings = router_doctor.build_findings(
            ["tg_send", "reboot-and-flush"], installed, schedulers,
            {"TgBotToken": 46, "TgChatId": 9},
        )
        self.assertEqual(levels_for(findings, "reboot-and-flush is meant to be run by hand"),
                         ["warn"])

    def test_a_manual_script_without_a_scheduler_says_nothing(self):
        findings = router_doctor.build_findings(
            ["tg_send", "detect_internet"], ["tg_send", "detect_internet"], [],
            {"TgBotToken": 46, "TgChatId": 9},
        )
        self.assertEqual(findings, [])

    def test_a_scheduler_calling_tg_send_is_not_a_warning(self):
        # notify-boot is documented in README.md and works exactly this way.
        schedulers = [{
            "name": "notify-boot",
            "interval": "00:00:00",
            "on_event": ":local S [:parse [/system script get tg_send source]];",
        }]
        findings = router_doctor.build_findings(
            ["tg_send"], ["tg_send"], schedulers, {"TgBotToken": 46, "TgChatId": 9}
        )
        self.assertEqual(findings, [])

    def test_an_unset_telegram_global_is_a_warning(self):
        installed, schedulers, _ = self.parsed()
        findings = router_doctor.build_findings(PACKAGE, installed, schedulers, {})
        self.assertEqual(levels_for(findings, "TgBotToken is not set"), ["warn"])
        self.assertEqual(levels_for(findings, "TgChatId is not set"), ["warn"])

    def test_an_empty_telegram_global_is_reported_separately(self):
        installed, schedulers, _ = self.parsed()
        findings = router_doctor.build_findings(
            PACKAGE, installed, schedulers, {"TgBotToken": 0, "TgChatId": 9}
        )
        self.assertEqual(levels_for(findings, "TgBotToken is defined but empty"), ["warn"])

    def test_no_finding_ever_carries_the_length_of_a_global(self):
        installed, schedulers, _ = self.parsed()
        findings = router_doctor.build_findings(
            PACKAGE, installed, schedulers, {"TgBotToken": 46, "TgChatId": 9}
        )
        for _, message in findings:
            self.assertNotIn("46", message)

    def test_mac_allowlist_without_its_global_does_nothing_and_says_so(self):
        installed = ["tg_send", "mac_allowlist_dhcp"]
        schedulers = [{"name": "mac_allowlist_dhcp", "interval": "5m",
                       "on_event": "/system script run mac_allowlist_dhcp"}]
        findings = router_doctor.build_findings(
            ["tg_send", "mac_allowlist_dhcp"], installed, schedulers,
            {"TgBotToken": 46, "TgChatId": 9},
        )
        self.assertEqual(levels_for(findings, "MAC_ALLOWLIST"), ["warn"])

    def test_that_global_is_not_demanded_when_the_script_is_absent(self):
        installed, schedulers, env = self.parsed()
        findings = router_doctor.build_findings(PACKAGE, installed, schedulers, env)
        self.assertEqual(levels_for(findings, "MAC_ALLOWLIST"), [])

    def test_a_script_on_the_router_but_not_in_the_folder_is_context(self):
        installed, schedulers, env = self.parsed()
        findings = router_doctor.build_findings(PACKAGE, installed, schedulers, env)
        self.assertEqual(levels_for(findings, "on the router but not in this folder"),
                         ["info"])

    def test_a_lone_copy_still_judges_what_the_router_has(self):
        # Copied on its own into ~/bin there are no .lua files to compare
        # against, which must not silence the scheduling check.
        installed, schedulers, env = self.parsed()
        findings = router_doctor.build_findings([], installed, schedulers, env)
        self.assertEqual(levels_for(findings, "health_check is installed but no scheduler"),
                         ["warn"])
        self.assertEqual(levels_for(findings, "not in this folder"), [])

    def test_a_healthy_router_produces_no_problems(self):
        installed = ["tg_send", "backup", "health_check"]
        schedulers = [
            {"name": "backup", "interval": "1d", "on_event": "/system script run backup"},
            {"name": "health_check", "interval": "5m",
             "on_event": "/system script run health_check"},
        ]
        findings = router_doctor.build_findings(
            ["tg_send", "backup", "health_check"], installed, schedulers,
            {"TgBotToken": 46, "TgChatId": 9},
        )
        self.assertEqual(findings, [])
        self.assertFalse(router_doctor.has_problems(findings))

    def test_context_alone_is_not_a_problem(self):
        # An exit code that says "something is wrong" for a router that chose
        # not to install two scripts would be worthless.
        installed, schedulers, env = self.parsed()
        findings = router_doctor.build_findings(
            PACKAGE + ["ddns_update", "vpn_health"],
            ["tg_send", "backup", "backup_file_cleanup"],
            [
                {"name": "backup", "interval": "1d",
                 "on_event": "/system script run backup"},
                {"name": "backup_file_cleanup", "interval": "1d",
                 "on_event": "/system script run backup_file_cleanup"},
            ],
            env,
        )
        self.assertTrue(findings)
        self.assertFalse(router_doctor.has_problems(findings))

    def test_fleet_pause_is_a_visible_warning(self):
        installed, schedulers, env = self.parsed()
        env[router_doctor.PAUSE_STATE_KEY] = True
        findings = router_doctor.build_findings(PACKAGE, installed, schedulers, env)
        self.assertEqual(levels_for(findings, "OpsToolboxPaused is true"), ["warn"])


class CompatibilityTestCase(unittest.TestCase):
    """Whether an installed script can run on the router's release at all.

    RouterOS 7.24 refuses any script declaring an underscored :global/:local,
    in the parser, before the script logs a line. A doctor that only compares
    names calls that router healthy, which is the quietest failure the package
    has. These pin the verdict, and pin the embedded fallback list to the files
    so it cannot drift from them.
    """

    HEALTHY_ENV = {"TgBotToken": 46, "TgChatId": 9}

    def env_on(self, version):
        env = dict(self.HEALTHY_ENV)
        env[router_doctor.VERSION_KEY] = version
        return env

    def test_parse_version_accepts_release_suffixes_and_rejects_garbage(self):
        self.assertEqual(router_doctor.parse_version("7.24.5 (stable)"), (7, 24))
        self.assertEqual(router_doctor.parse_version("7.24"), (7, 24))
        self.assertEqual(router_doctor.parse_version("7.16rc2 (testing)"), (7, 16))
        self.assertEqual(router_doctor.parse_version("7.25beta1"), (7, 25))
        self.assertIsNone(router_doctor.parse_version(""))
        self.assertIsNone(router_doctor.parse_version("stable"))
        self.assertIsNone(router_doctor.parse_version("v7"))

    def test_declares_underscored_name_matches_global_and_local_only_when_a_declaration(self):
        self.assertTrue(router_doctor.declares_underscored_name(":global TG_BOT_TOKEN;\n"))
        self.assertTrue(router_doctor.declares_underscored_name("  :local Max_Wait 3;\n"))
        self.assertFalse(router_doctor.declares_underscored_name(":global TgBotToken;\n"))
        # Using an underscored name is not declaring one.
        self.assertFalse(router_doctor.declares_underscored_name(
            ':log info "update_check done";\n:put $x_y;\n'
        ))

    def test_a_comment_mentioning_an_underscored_name_is_not_a_declaration(self):
        source = "# :global TG_BOT_TOKEN is no longer read\n:global TgBotToken;\n"
        self.assertFalse(router_doctor.declares_underscored_name(source))

    def test_underscored_script_names_walks_core_and_features_and_skips_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            for folder in ("core", "features", "tests"):
                os.mkdir(os.path.join(tmp, folder))
            files = {
                os.path.join(tmp, "core", "old_core.lua"): ":global OLD_NAME;\n",
                os.path.join(tmp, "core", "clean.lua"): ":global CleanName;\n",
                os.path.join(tmp, "features", "old_feature.lua"): ":local My_Var 1;\n",
                os.path.join(tmp, "tests", "fixture.lua"): ":global FIX_TURE;\n",
            }
            for path, body in files.items():
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(body)
            self.assertEqual(router_doctor.underscored_script_names(tmp),
                             ["old_core", "old_feature"])
        self.assertEqual(router_doctor.underscored_script_names("/nonexistent/mikrotik"), [])

    def test_an_unreadable_subdirectory_raises_rather_than_shortening(self):
        with tempfile.TemporaryDirectory() as tmp:
            core = os.path.join(tmp, "core")
            os.mkdir(core)
            for path in (os.path.join(core, "update_check.lua"),
                         os.path.join(tmp, "tg_send.lua")):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(":global UPDATE_CHECK_BACKUP;\n")
            real_scandir = os.scandir

            def refuse_core(path=".", *args, **kwargs):
                if str(path) == core:
                    raise PermissionError(13, "Permission denied", str(path))
                return real_scandir(path, *args, **kwargs)

            with mock.patch("os.scandir", refuse_core), self.assertRaises(OSError):
                router_doctor.underscored_script_names(tmp)

    def test_installed_scheduled_underscored_script_fails_on_724(self):
        schedulers = [{"name": "vpn_health", "interval": "2m",
                       "on_event": "/system script run vpn_health"}]
        findings = router_doctor.build_findings(
            ["tg_send", "vpn_health"], ["tg_send", "vpn_health"], schedulers,
            self.env_on((7, 24)),
        )
        self.assertEqual(levels_for(findings, "vpn_health is installed but RouterOS 7.24"),
                         ["fail"])
        self.assertTrue(router_doctor.has_problems(findings))

    def test_installed_unscheduled_underscored_script_warns_on_724(self):
        findings = router_doctor.build_findings(
            ["tg_send", "vpn_health"], ["tg_send", "vpn_health"], [],
            self.env_on((7, 25)),
        )
        self.assertEqual(levels_for(findings, "vpn_health is installed but RouterOS 7.25"),
                         ["warn"])

    def test_update_check_finding_names_backup_update_check(self):
        schedulers = [{"name": "update_check", "interval": "1d",
                       "on_event": "/system script run update_check"}]
        findings = router_doctor.build_findings(
            ["tg_send", "update_check"], ["tg_send", "update_check"], schedulers,
            self.env_on((7, 24)),
        )
        messages = [m for _, m in findings if "update_check is installed" in m]
        self.assertEqual(len(messages), 1)
        self.assertIn("replacement: backup_update_check", messages[0])

    def test_724_clean_scripts_produce_no_compat_finding(self):
        installed = ["tg_send", "backup", "health_check"]
        schedulers = [
            {"name": "backup", "interval": "1d", "on_event": "/system script run backup"},
            {"name": "health_check", "interval": "5m",
             "on_event": "/system script run health_check"},
        ]
        findings = router_doctor.build_findings(
            installed, installed, schedulers, self.env_on((7, 24)),
        )
        self.assertEqual(findings, [])

    def test_723_router_gets_one_info_line_and_no_problem(self):
        schedulers = [{"name": "vpn_health", "interval": "2m",
                       "on_event": "/system script run vpn_health"},
                      {"name": "update_check", "interval": "1d",
                       "on_event": "/system script run update_check"}]
        installed = ["tg_send", "vpn_health", "update_check"]
        findings = router_doctor.build_findings(
            installed, installed, schedulers, self.env_on((7, 23)),
        )
        infos = [m for level, m in findings if "7.24" in m]
        self.assertEqual(len(infos), 1)
        self.assertEqual(levels_for(findings, "will stop running on RouterOS 7.24"), ["info"])
        self.assertIn("update_check", infos[0])
        self.assertIn("vpn_health", infos[0])
        self.assertFalse(router_doctor.has_problems(findings))

    def test_missing_version_line_is_silent(self):
        schedulers = [{"name": "vpn_health", "interval": "2m",
                       "on_event": "/system script run vpn_health"}]
        findings = router_doctor.build_findings(
            ["tg_send", "vpn_health"], ["tg_send", "vpn_health"], schedulers,
            dict(self.HEALTHY_ENV),
        )
        self.assertEqual(findings, [])
        _, _, env = router_doctor.parse_report(REPORT)
        self.assertNotIn(router_doctor.VERSION_KEY, env)

    def test_a_version_line_is_parsed_into_the_reserved_key(self):
        _, _, env = router_doctor.parse_report(REPORT + "VER:7.24.5 (stable)\n")
        self.assertEqual(env[router_doctor.VERSION_KEY], (7, 24))
        self.assertEqual(env[router_doctor.VERSION_TEXT_KEY], "7.24.5 (stable)")
        _, _, env = router_doctor.parse_report(REPORT + "VER:garbage\n")
        self.assertNotIn(router_doctor.VERSION_KEY, env)

    def test_the_derived_set_is_used_when_given(self):
        # A script renamed clean in the package must stop being reported even
        # though the embedded fallback still names it.
        findings = router_doctor.build_findings(
            ["tg_send", "vpn_health"], ["tg_send", "vpn_health"], [],
            self.env_on((7, 24)), underscored=[],
        )
        self.assertEqual(levels_for(findings, "refuses to execute"), [])

    def test_embedded_fallback_equals_the_set_derived_from_this_repository(self):
        derived = router_doctor.underscored_script_names(os.path.join(REPO_ROOT, "mikrotik"))
        self.assertTrue(derived, "derived nothing - the walk is not reading the scripts")
        self.assertEqual(sorted(router_doctor.UNDERSCORED_FALLBACK), derived)

    def test_the_probe_requests_the_version_and_still_only_reads(self):
        self.assertIn('"VER:"', router_doctor.PROBE)
        self.assertIn("/system resource get version", router_doctor.PROBE)
        for verb in (" set ", " add ", " remove ", " enable ", " disable "):
            self.assertNotIn(verb, router_doctor.PROBE)

    def test_json_carries_routeros_version_and_leaves_schedulers_untouched(self):
        report = (
            "SCR:tg_send\nSCR:update_check\n"
            "SCH:update_check|1d|/system script run update_check\n"
            "ENV:TgBotToken|46\nENV:TgChatId|9\n"
            "VER:7.24.5 (stable)\n"
        )
        stdout = io.StringIO()
        with mock.patch.object(router_doctor, "probe", return_value=(0, report, "")), \
             mock.patch.object(router_doctor, "local_script_names",
                               return_value=["tg_send", "update_check"]), \
             contextlib.redirect_stdout(stdout):
            rc = router_doctor.main(["--host", "router.test", "--format", "json"])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 0)
        self.assertEqual(payload["routeros_version"], "7.24.5 (stable)")
        self.assertEqual(payload["incompatible_scripts"], ["update_check"])
        self.assertEqual(payload["schedulers"], [{"name": "update_check", "interval": "1d"}])
        self.assertTrue(any(f["level"] == "fail" and "update_check" in f["message"]
                            for f in payload["findings"]))

    def test_json_without_a_version_reports_null(self):
        stdout = io.StringIO()
        with mock.patch.object(router_doctor, "probe", return_value=(0, REPORT, "")), \
             mock.patch.object(router_doctor, "local_script_names", return_value=PACKAGE), \
             contextlib.redirect_stdout(stdout):
            router_doctor.main(["--host", "router.test", "--format", "json"])
        payload = json.loads(stdout.getvalue())
        self.assertIsNone(payload["routeros_version"])
        self.assertEqual(payload["incompatible_scripts"], [])


class DurationTestCase(unittest.TestCase):
    def test_parses_week_day_clock_form(self):
        self.assertEqual(router_doctor.duration_seconds("1w2d03:04:05"),
                         604800 + 2 * 86400 + 3 * 3600 + 4 * 60 + 5)
        self.assertEqual(router_doctor.duration_seconds("3d04:12:05"),
                         3 * 86400 + 4 * 3600 + 12 * 60 + 5)

    def test_parses_letter_form(self):
        self.assertEqual(router_doctor.duration_seconds("5m"), 300)
        self.assertEqual(router_doctor.duration_seconds("1d"), 86400)
        self.assertEqual(router_doctor.duration_seconds("1h30m"), 5400)
        self.assertEqual(router_doctor.duration_seconds("30s"), 30)
        self.assertEqual(router_doctor.duration_seconds("1w2d3h4m5s"),
                         604800 + 2 * 86400 + 3 * 3600 + 4 * 60 + 5)

    def test_clock_only_form(self):
        self.assertEqual(router_doctor.duration_seconds("00:05:00"), 300)
        self.assertEqual(router_doctor.duration_seconds("01:00:00"), 3600)

    def test_zero_and_garbage(self):
        self.assertEqual(router_doctor.duration_seconds("0"), 0)
        self.assertEqual(router_doctor.duration_seconds("00:00:00"), 0)
        self.assertIsNone(router_doctor.duration_seconds(""))
        self.assertIsNone(router_doctor.duration_seconds("garbage"))
        self.assertIsNone(router_doctor.duration_seconds("5x"))


class SchedulerHealthTestCase(unittest.TestCase):
    """The other half of 'installed but unscheduled'.

    A disabled entry still counted as scheduled, an enabled entry whose policy
    is too narrow never fires (RouterOS logs "not enough permissions" and
    nothing else says so), and a token set by hand today is gone after the
    next reboot. Each check runs only on fields the probe returned, so an
    older probe, or the existing healthy-router fixtures, stay quiet.
    """

    HEALTHY_ENV = {"TgBotToken": 46, "TgChatId": 9}

    def scheduler(self, name, interval="5m", on_event=None, disabled=False,
                  run_count=7, start_time="jan/01/1970 00:00:00"):
        return {
            "name": name,
            "interval": interval,
            "on_event": on_event if on_event is not None else "/system script run %s" % name,
            "disabled": disabled,
            "run_count": run_count,
            "start_time": start_time,
        }

    def restorer(self):
        return self.scheduler("startup", interval="0s", on_event="/system script run startup",
                              start_time="startup", run_count=1)

    def env(self, uptime=None, declares=("startup",), chat_declares=None):
        """declares: scripts mentioning TgBotToken; chat_declares: TgChatId
        (the same scripts unless given)."""
        env = dict(self.HEALTHY_ENV)
        if uptime is not None:
            env[router_doctor.UPTIME_KEY] = uptime
        chat = declares if chat_declares is None else chat_declares
        env[router_doctor.DECLARES_TG_KEY] = list(declares)
        env[router_doctor.DECLARES_KEY] = {
            "TgBotToken": list(declares), "TgChatId": list(chat),
        }
        return env

    def test_scx_record_merges_into_its_scheduler_and_keeps_the_three_tuple(self):
        text = REPORT + (
            "SCX:backup|false|12|04:00:00\n"
            "SCX:startup|true|0|startup\n"
            "UPT:3d04:12:05\n"
            "DECL:startup|TgBotToken\n"
            "DECL:startup|TgChatId\n"
            "DECL:tg_send|TgBotToken\n"
            "DECL:legacy\n"
            "DECL:other|NotRequired\n"
        )
        result = router_doctor.parse_report(text)
        self.assertEqual(len(result), 3)
        _, schedulers, env = result
        backup = schedulers[0]
        self.assertIs(backup["disabled"], False)
        self.assertEqual(backup["run_count"], 12)
        self.assertEqual(backup["start_time"], "04:00:00")
        self.assertEqual(backup["on_event"], "/system script run backup")
        self.assertIs(schedulers[2]["disabled"], True)
        self.assertNotIn("disabled", schedulers[1])
        self.assertEqual(env[router_doctor.UPTIME_KEY], 3 * 86400 + 4 * 3600 + 12 * 60 + 5)
        self.assertEqual(env[router_doctor.DECLARES_TG_KEY], ["legacy", "startup", "tg_send"])
        self.assertEqual(env[router_doctor.DECLARES_KEY], {
            "TgBotToken": ["legacy", "startup", "tg_send"], "TgChatId": ["startup"],
        })

    def test_scx_for_an_unknown_scheduler_is_ignored(self):
        _, schedulers, _ = router_doctor.parse_report(REPORT + "SCX:nosuch|true|0|startup\n")
        self.assertEqual([s["name"] for s in schedulers],
                         ["backup", "backup_file_cleanup", "startup"])
        for entry in schedulers:
            self.assertNotIn("disabled", entry)

    def test_disabled_scheduler_is_a_warning_not_a_silent_pass(self):
        schedulers = [self.scheduler("health_check", disabled=True), self.restorer()]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers, self.env(),
        )
        self.assertEqual(levels_for(findings, "that scheduler is disabled"), ["warn"])
        self.assertTrue(router_doctor.has_problems(findings))

    def test_disabled_entry_does_not_double_report_unscheduled(self):
        schedulers = [self.scheduler("health_check", disabled=True), self.restorer()]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers, self.env(),
        )
        self.assertEqual(levels_for(findings, "no scheduler runs it"), [])
        self.assertEqual(len([f for f in findings if "health_check" in f[1]]), 1)

    def test_enabled_zero_run_count_after_long_uptime_warns(self):
        schedulers = [self.scheduler("health_check", run_count=0), self.restorer()]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            self.env(uptime=86400),
        )
        self.assertEqual(levels_for(findings, '"health_check" has never fired'), ["warn"])
        self.assertEqual(levels_for(findings, "not enough permissions"), ["warn"])

    def test_zero_run_count_just_after_boot_is_quiet(self):
        # 5m interval: 2 x 300 + 60 = 660 seconds before it can be accused.
        schedulers = [self.scheduler("health_check", run_count=0), self.restorer()]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            self.env(uptime=600),
        )
        self.assertEqual(levels_for(findings, "has never fired"), [])
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            self.env(uptime=None),
        )
        self.assertEqual(levels_for(findings, "has never fired"), [])

    def test_startup_and_zero_interval_entries_are_not_judged(self):
        schedulers = [
            self.scheduler("notify-boot", interval="0s", run_count=0, start_time="startup",
                           on_event=":local S [:parse [/system script get tg_send source]];"),
            self.scheduler("oneshot", interval="00:00:00", run_count=0),
            self.restorer(),
        ]
        findings = router_doctor.build_findings(
            ["tg_send"], ["tg_send"], schedulers, self.env(uptime=10 * 86400),
        )
        self.assertEqual(levels_for(findings, "has never fired"), [])

    def test_tg_global_set_with_no_startup_restore_warns(self):
        schedulers = [self.scheduler("health_check")]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            self.env(uptime=3600, declares=()),
        )
        self.assertEqual(
            levels_for(findings, "TgBotToken and TgChatId are set now but nothing re-declares"),
            ["warn"],
        )

    def test_inline_startup_on_event_declaring_tgbottoken_satisfies_it(self):
        schedulers = [
            self.scheduler("health_check"),
            self.scheduler("set-globals", interval="0s", start_time="startup",
                           on_event=':global TgBotToken "x"; :global TgChatId "y";'),
        ]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            self.env(uptime=3600, declares=()),
        )
        self.assertEqual(levels_for(findings, "re-declares"), [])

    def test_startup_script_listed_in_decl_satisfies_it(self):
        schedulers = [self.scheduler("health_check"), self.restorer()]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check", "startup"], schedulers,
            self.env(uptime=3600, declares=("startup", "tg_send")),
        )
        self.assertEqual(levels_for(findings, "re-declares"), [])

    def test_tg_send_in_decl_does_not_count_as_a_restorer(self):
        # notify-boot runs tg_send at startup, and tg_send's source mentions
        # TgBotToken - because it reads it, not because it sets it.
        schedulers = [
            self.scheduler("health_check"),
            self.scheduler("notify-boot", interval="0s", start_time="startup",
                           on_event=":local S [:parse [/system script get tg_send source]];"),
        ]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            self.env(uptime=3600, declares=("tg_send", "tg_send_new")),
        )
        self.assertEqual(levels_for(findings, "re-declares"), ["warn"])

    def test_a_disabled_startup_scheduler_does_not_restore(self):
        restorer = self.restorer()
        restorer["disabled"] = True
        findings = router_doctor.build_findings(
            ["tg_send"], ["tg_send", "startup"], [restorer], self.env(uptime=3600),
        )
        self.assertEqual(levels_for(findings, "re-declares"), ["warn"])

    def test_startup_restoring_only_the_token_still_warns_about_the_chat_id(self):
        schedulers = [self.scheduler("health_check"), self.restorer()]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check", "startup"], schedulers,
            self.env(uptime=3600, declares=("startup",), chat_declares=()),
        )
        self.assertEqual(levels_for(findings, "TgChatId is set now but nothing re-declares it"),
                         ["warn"])
        self.assertEqual(levels_for(findings, "TgBotToken"), [])

    def test_inline_startup_restoring_only_the_token_warns_about_the_chat_id(self):
        schedulers = [
            self.scheduler("health_check"),
            self.scheduler("set-token", interval="0s", start_time="startup",
                           on_event=':global TgBotToken "x";'),
        ]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            self.env(uptime=3600, declares=()),
        )
        self.assertEqual(levels_for(findings, "TgChatId is set now but nothing re-declares it"),
                         ["warn"])
        self.assertEqual(levels_for(findings, "TgBotToken is set now"), [])

    def test_check_is_silent_when_probe_gave_no_start_time(self):
        schedulers = [{"name": "health_check", "interval": "5m",
                       "on_event": "/system script run health_check"}]
        findings = router_doctor.build_findings(
            ["tg_send", "health_check"], ["tg_send", "health_check"], schedulers,
            dict(self.HEALTHY_ENV),
        )
        self.assertEqual(findings, [])

    def test_existing_healthy_router_still_has_no_findings(self):
        installed = ["tg_send", "backup", "health_check"]
        schedulers = [
            self.scheduler("backup", interval="1d", start_time="04:00:00"),
            self.scheduler("health_check"),
            self.restorer(),
        ]
        findings = router_doctor.build_findings(
            installed, installed + ["startup"], schedulers, self.env(uptime=10 * 86400),
        )
        self.assertEqual(levels_for(findings, ""), ["info"])
        self.assertFalse(router_doctor.has_problems(findings))

    def test_probe_adds_no_write_verbs_and_never_returns_script_source(self):
        probe = router_doctor.PROBE
        for verb in (" set ", " add ", " remove ", " enable ", " disable "):
            self.assertNotIn(verb, probe)
        # The only place a script source is touched is inside the :find the
        # router evaluates; what is :put is the script's name.
        self.assertEqual(probe.count(" source]"), 1)
        self.assertIn('[:find [/system script get $s source] $g]', probe)
        # one DECL record per script and required global, from a literal
        # array of exactly REQUIRED_GLOBALS
        self.assertIn(":foreach g in={%s}" % ";".join(
            '"%s"' % g for g in router_doctor.REQUIRED_GLOBALS), probe)
        self.assertIn('. "|" . $g)', probe)
        for record in re.findall(r":put \(([^;]*)\)", probe):
            # Whole word: "/system resource" holds the letters, not a read.
            self.assertIsNone(re.search(r"\bsource\b", record), record)
        self.assertIn('"SCX:"', probe)
        self.assertIn('"UPT:"', probe)
        self.assertIn('"DECL:"', probe)

    def test_json_scheduler_state_is_separate_from_schedulers(self):
        report = (
            "SCR:tg_send\nSCR:backup\n"
            "SCH:backup|1d|/system script run backup\n"
            "ENV:TgBotToken|46\nENV:TgChatId|9\n"
            "SCX:backup|true|0|04:00:00\n"
            "UPT:2d00:00:00\n"
        )
        stdout = io.StringIO()
        with mock.patch.object(router_doctor, "probe", return_value=(0, report, "")), \
             mock.patch.object(router_doctor, "local_script_names",
                               return_value=["tg_send", "backup"]), \
             contextlib.redirect_stdout(stdout):
            rc = router_doctor.main(["--host", "router.test", "--format", "json"])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 0)
        self.assertEqual(payload["schedulers"], [{"name": "backup", "interval": "1d"}])
        self.assertEqual(payload["scheduler_state"], [
            {"name": "backup", "disabled": True, "run_count": 0, "start_time": "04:00:00"},
        ])
        self.assertEqual(payload["uptime_seconds"], 2 * 86400)


class JsonOutputTestCase(unittest.TestCase):
    def test_json_is_structured_and_keeps_exit_semantics(self):
        report = REPORT + "CTL:OpsToolboxPaused|true\n"
        stdout = io.StringIO()
        with mock.patch.object(router_doctor, "probe", return_value=(0, report, "")), \
             mock.patch.object(router_doctor, "local_script_names", return_value=PACKAGE), \
             contextlib.redirect_stdout(stdout):
            rc = router_doctor.main(["--host", "router.test", "--format", "json"])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 0)
        self.assertEqual(payload["host"], "router.test")
        self.assertIs(payload["controls"]["ops_toolbox_paused"], True)
        self.assertFalse(payload["healthy"])
        self.assertTrue(any(f["level"] == "warn" for f in payload["findings"]))
        self.assertNotIn("46", stdout.getvalue())

    def test_json_never_emits_free_form_scheduler_source(self):
        hidden_marker = "token-that-must-stay-on-router"
        report = (
            "SCR:backup\n"
            "SCH:backup|1d|/system script run backup; :local secret=%s\n"
            "ENV:TgBotToken|46\nENV:TgChatId|9\n"
        ) % hidden_marker
        stdout = io.StringIO()
        with mock.patch.object(router_doctor, "probe", return_value=(0, report, "")), \
             mock.patch.object(router_doctor, "local_script_names", return_value=["backup"]), \
             contextlib.redirect_stdout(stdout):
            router_doctor.main(["--host", "router.test", "--format", "json"])
        payload = json.loads(stdout.getvalue())
        self.assertNotIn(hidden_marker, stdout.getvalue())
        self.assertEqual(payload["schedulers"], [{"name": "backup", "interval": "1d"}])

    def test_unreachable_json_is_still_machine_readable(self):
        stdout = io.StringIO()
        with mock.patch.object(
            router_doctor, "probe", return_value=(255, "", "connection refused")
        ), contextlib.redirect_stdout(stdout):
            rc = router_doctor.main(["--host", "router.test", "--format", "json"])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 2)
        self.assertIs(payload["reachable"], False)



class HostsFileTestCase(unittest.TestCase):
    def test_parses_comments_blank_lines_and_trailing_comments(self):
        text = (
            "# the office routers\n"
            "\n"
            "   \n"
            "192.0.2.1\n"
            "router.lan   # the one in the hall\n"
        )
        self.assertEqual(router_doctor.parse_hosts_file(text),
                         [("admin", "192.0.2.1", 22), ("admin", "router.lan", 22)])

    def test_user_host_port_forms_and_ipv6_brackets(self):
        text = (
            "ops@192.0.2.1\n"
            "router.lan:2222\n"
            "ops@router.lan:2200\n"
            "[2001:db8::1]:2022\n"
            "ops@[2001:db8::2]\n"
        )
        self.assertEqual(router_doctor.parse_hosts_file(text), [
            ("ops", "192.0.2.1", 22),
            ("admin", "router.lan", 2222),
            ("ops", "router.lan", 2200),
            ("admin", "2001:db8::1", 2022),
            ("ops", "2001:db8::2", 22),
        ])

    def test_defaults_come_from_the_flags(self):
        routers = router_doctor.parse_hosts_file("a.lan\nroot@b.lan:23\n",
                                                 default_user="ops", default_port=2222)
        self.assertEqual(routers, [("ops", "a.lan", 2222), ("root", "b.lan", 23)])

    def test_duplicates_collapse_in_order(self):
        text = "b.lan\na.lan\nb.lan\nadmin@a.lan:22\nops@a.lan\n"
        self.assertEqual(router_doctor.parse_hosts_file(text), [
            ("admin", "b.lan", 22), ("admin", "a.lan", 22), ("ops", "a.lan", 22),
        ])

    def test_empty_file_is_usage(self):
        self.assertEqual(router_doctor.parse_hosts_file("# nothing yet\n\n"), [])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "hosts")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("# nothing yet\n")
            probe = mock.Mock()
            with mock.patch.object(router_doctor, "probe", probe), \
                 contextlib.redirect_stderr(io.StringIO()), \
                 self.assertRaises(SystemExit) as raised:
                router_doctor.main(["--hosts-file", path])
            self.assertEqual(raised.exception.code, 3)
            probe.assert_not_called()

    def test_a_token_starting_with_a_dash_is_rejected(self):
        for text in ("-oProxyCommand=evil\n", "-oProxyCommand=x@router.lan\n",
                     "admin@-oProxyCommand=x\n"):
            with self.assertRaises(ValueError, msg=text):
                router_doctor.parse_hosts_file(text)

    def test_malformed_line_reports_its_line_number(self):
        with self.assertRaises(ValueError) as raised:
            router_doctor.parse_hosts_file("a.lan\n\nb.lan c.lan\n")
        self.assertEqual(raised.exception.args[0], 3)
        for bad_line in ("a.lan:99999", "a.lan:0", "a b", "a.lan:port", "2001:db8::1"):
            with self.assertRaises(ValueError, msg=bad_line):
                router_doctor.parse_hosts_file("ok.lan\n" + bad_line + "\n")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "hosts")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("a.lan\nb.lan:0\n")
            errout = io.StringIO()
            probe = mock.Mock()
            with mock.patch.object(router_doctor, "probe", probe), \
                 contextlib.redirect_stderr(errout), \
                 self.assertRaises(SystemExit) as raised:
                router_doctor.main(["--hosts-file", path])
            self.assertEqual(raised.exception.code, 3)
            self.assertIn("line 2", errout.getvalue())
            probe.assert_not_called()


# One router per outcome: a healthy one, one with a finding, one that cannot be
# reached, and one that answered but whose probe failed.
FLEET_REPORTS = {
    "healthy.lan": (0, (
        "SCR:tg_send\nSCR:backup\n"
        "SCH:backup|1d|/system script run backup\n"
        "ENV:TgBotToken|46\nENV:TgChatId|9\n"
    ), ""),
    "finding.lan": (0, REPORT, ""),
    "down.lan": (255, "", "ssh: connect to host down.lan port 22: Connection refused"),
    "broken.lan": (1, "", "bad command name"),
}


class FleetRunTestCase(unittest.TestCase):
    def run_fleet(self, hosts, extra=()):
        def fake_probe(host, user, identity, port, timeout, command=router_doctor.PROBE):
            return FLEET_REPORTS[host]

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "hosts")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("".join(h + "\n" for h in hosts))
            stdout = io.StringIO()
            local = mock.Mock(return_value=["tg_send", "backup", "health_check"])
            with mock.patch.object(router_doctor, "probe", side_effect=fake_probe), \
                 mock.patch.object(router_doctor, "local_script_names", local), \
                 contextlib.redirect_stdout(stdout):
                rc = router_doctor.main(["--hosts-file", path] + list(extra))
        return rc, stdout.getvalue(), local

    def test_host_and_hosts_file_are_mutually_exclusive_exit_3(self):
        with contextlib.redirect_stderr(io.StringIO()), \
             self.assertRaises(SystemExit) as raised:
            router_doctor.main(["--host", "a.lan", "--hosts-file", "/nonexistent"])
        self.assertEqual(raised.exception.code, 3)

    def test_neither_given_is_exit_3(self):
        with contextlib.redirect_stderr(io.StringIO()), \
             self.assertRaises(SystemExit) as raised:
            router_doctor.main([])
        self.assertEqual(raised.exception.code, 3)

    def test_one_unreachable_host_does_not_stop_the_rest(self):
        rc, out, _ = self.run_fleet(["down.lan", "healthy.lan", "finding.lan"])
        self.assertIn("== down.lan ==", out)
        self.assertIn("== healthy.lan ==", out)
        self.assertIn("== finding.lan ==", out)
        self.assertIn("== fleet ==", out)
        table = out.split("== fleet ==", 1)[1]
        self.assertRegex(table, r"down\.lan\s+unreachable")
        self.assertRegex(table, r"healthy\.lan\s+reachable\s+fail=0 warn=0")
        self.assertRegex(table, r"finding\.lan\s+reachable\s+fail=0 warn=1")

    def test_exit_is_2_when_any_host_is_unreachable(self):
        rc, _, _ = self.run_fleet(["healthy.lan", "broken.lan", "down.lan", "finding.lan"])
        self.assertEqual(rc, 2)

    def test_exit_is_1_when_a_probe_failed_and_none_unreachable(self):
        rc, out, _ = self.run_fleet(["healthy.lan", "broken.lan", "finding.lan"])
        self.assertEqual(rc, 1)
        self.assertRegex(out.split("== fleet ==", 1)[1], r"broken\.lan\s+probe-failed")

    def test_exit_is_0_when_any_findings(self):
        rc, _, _ = self.run_fleet(["healthy.lan", "finding.lan"])
        self.assertEqual(rc, 0)

    def test_exit_is_4_only_when_every_host_is_clean(self):
        rc, _, _ = self.run_fleet(["healthy.lan"])
        self.assertEqual(rc, 4)

    def test_json_has_hosts_and_summary_and_no_scheduler_source(self):
        rc, out, _ = self.run_fleet(["healthy.lan", "finding.lan", "down.lan", "broken.lan"],
                                    extra=["--format", "json"])
        payload = json.loads(out)
        self.assertEqual(rc, 2)
        self.assertIs(payload["fleet"], True)
        self.assertEqual([h["host"] for h in payload["hosts"]],
                         ["healthy.lan", "finding.lan", "down.lan", "broken.lan"])
        self.assertEqual(payload["summary"], {
            "total": 4, "unreachable": 1, "probe_failed": 1,
            "with_findings": 1, "healthy": 1,
        })
        self.assertNotIn("/system script run", out)
        self.assertNotIn("46", out)

    def test_local_scan_runs_once(self):
        _, _, local = self.run_fleet(["healthy.lan", "finding.lan", "down.lan"])
        self.assertEqual(local.call_count, 1)

    def test_single_host_output_is_unchanged(self):
        # The single-router paths go through the same run_one() the fleet
        # uses; what they print must not have moved. Colour is decided at
        # import from the terminal, so it is switched off for the comparison.
        plain = mock.patch.multiple(router_doctor, C_RESET="", C_RED="", C_GREEN="",
                                    C_YELLOW="", C_DIM="", C_BOLD="")
        stdout = io.StringIO()
        with plain, mock.patch.object(router_doctor, "probe",
                                      return_value=FLEET_REPORTS["down.lan"]), \
             contextlib.redirect_stdout(stdout):
            rc = router_doctor.main(["--host", "down.lan"])
        self.assertEqual(rc, 2)
        self.assertEqual(stdout.getvalue(), (
            "[fail] cannot reach down.lan over ssh\n"
            "        ssh: connect to host down.lan port 22: Connection refused\n"
            "[info] check the host and key, and that SSH is enabled under IP -> Services\n"
            "[info] ../git/git_ssh_doctor.py --host down.lan --test-auth will say which "
            "key works\n"
        ))
        stdout = io.StringIO()
        with plain, mock.patch.object(router_doctor, "probe",
                                      return_value=FLEET_REPORTS["healthy.lan"]), \
             mock.patch.object(router_doctor, "local_script_names",
                               return_value=["tg_send", "backup"]), \
             contextlib.redirect_stdout(stdout):
            rc = router_doctor.main(["--host", "healthy.lan"])
        self.assertEqual(rc, 4)
        self.assertEqual(stdout.getvalue(), (
            "\n== router ==\n"
            "[info] admin@healthy.lan:22 answered\n"
            "[info] /system script holds 2 entries; /system scheduler holds 1\n"
            "\n== findings ==\n"
            "[ ok ] nothing to fix: everything installed is scheduled and has the "
            "globals it needs\n"
        ))


def unescape_routeros(text):
    """The inverse of escape_routeros_string, for the fake router below."""
    out = bytearray()
    i = 0
    simple = {"\\": 0x5C, '"': 0x22, "$": 0x24, "?": 0x3F, "n": 0x0A, "r": 0x0D, "t": 0x09}
    while i < len(text):
        ch = text[i]
        if ch != "\\":
            out += ch.encode("ascii")
            i += 1
        elif text[i + 1] in simple:
            out.append(simple[text[i + 1]])
            i += 2
        else:
            out.append(int(text[i + 1:i + 3], 16))
            i += 3
    return bytes(out)


def fake_router(stored):
    """A run(command) that answers a drift command the way the router would.

    stored maps a script name to the bytes in the router's Source. It applies
    the same rule as DRIFT_BLOCK to the name and text it finds in the command,
    and records every command it was sent.
    """
    sent = []

    def run(command):
        sent.append(command)
        lines = []
        for name, expected in re.findall(
            r'where name="((?:[^"\\]|\\.)*)"\].*?:local exp "((?:[^"\\]|\\.)*)";',
            command,
        ):
            name = unescape_routeros(name).decode()
            want = unescape_routeros(expected)
            if name not in stored:
                word = "missing"
            else:
                cur = stored[name]
                if cur in (want, want + b"\n", want + b"\r\n"):
                    word = "same"
                else:
                    word = "changed-cr" if b"\r" in cur else "changed"
            lines.append("DRF:%s|%s" % (name, word))
        return 0, "\n".join(lines) + "\n"

    run.sent = sent
    return run


class EscapeRouterosStringTestCase(unittest.TestCase):
    def test_special_characters_are_escaped(self):
        self.assertEqual(router_doctor.escape_routeros_string('a"b'), 'a\\"b')
        self.assertEqual(router_doctor.escape_routeros_string("a\\b"), "a\\\\b")
        self.assertEqual(router_doctor.escape_routeros_string("$x ?"), "\\$x \\?")
        self.assertEqual(router_doctor.escape_routeros_string("a\r\nb\tc"), "a\\r\\nb\\tc")

    def test_other_control_and_non_ascii_bytes_become_hex(self):
        self.assertEqual(router_doctor.escape_routeros_string(b"\x00\x1b\x7f"), "\\00\\1B\\7F")
        self.assertEqual(router_doctor.escape_routeros_string("\u00e9"), "\\C3\\A9")

    def test_plain_text_is_unchanged_and_result_is_one_ascii_line(self):
        self.assertEqual(router_doctor.escape_routeros_string(":log info foo;"), ":log info foo;")
        nasty = ':local a "q\\$b?\r\n\t\x01\u00e9 {} [] ;"\n'
        escaped = router_doctor.escape_routeros_string(nasty)
        self.assertTrue(escaped.isascii())
        self.assertNotIn("\n", escaped)
        self.assertNotIn("\r", escaped)
        self.assertEqual(unescape_routeros(escaped), nasty.encode("utf-8"))

    def test_no_unescaped_quote_dollar_or_question_mark_survives(self):
        escaped = router_doctor.escape_routeros_string(bytes(range(256)))
        stripped = escaped.replace("\\\\", "")
        for char in '"$?':
            for i, c in enumerate(stripped):
                if c == char:
                    self.assertEqual(stripped[i - 1], "\\", char)
        self.assertEqual(unescape_routeros(escaped), bytes(range(256)))


class DriftTestCase(unittest.TestCase):
    """--drift: which installed scripts differ from the files in this checkout.

    The expected source goes into the router in the command and the router
    answers with a word per script, so no source comes back. What the report
    may say is a verdict, never a source.
    """

    BODY = b':global OpsToolboxPaused;\n:log info "x $y \\ ?";\n'

    def package(self, tmp, body=BODY):
        features = os.path.join(tmp, "mikrotik", "features")
        os.makedirs(features)
        path = os.path.join(features, "health_check.lua")
        with open(path, "wb") as fh:
            fh.write(body)
        return os.path.join(tmp, "mikrotik"), path

    def verdict(self, stored, body=BODY):
        return router_doctor.drift_verdicts({"health_check": body},
                                            fake_router({"health_check": stored}))

    def test_identical_source_is_same_even_with_nasty_characters(self):
        self.assertEqual(self.verdict(self.BODY), {"health_check": "same"})

    def test_a_trailing_newline_or_crlf_difference_is_still_same(self):
        bare = self.BODY.rstrip(b"\n")
        for pasted in (self.BODY, bare, bare + b"\n", self.BODY.replace(b"\n", b"\r\n"),
                       bare.replace(b"\n", b"\r\n")):
            self.assertEqual(self.verdict(pasted), {"health_check": "same"}, pasted)

    def test_edited_source_is_changed(self):
        self.assertEqual(self.verdict(self.BODY.replace(b"x", b"tuned")),
                         {"health_check": "changed"})
        self.assertEqual(self.verdict(self.BODY.replace(b"x", b"tuned").replace(b"\n", b"\r\n")),
                         {"health_check": "changed"})

    def test_crlf_copy_is_asked_again_with_crlf_line_ends(self):
        run = fake_router({"health_check": self.BODY.replace(b"\n", b"\r\n")})
        router_doctor.drift_verdicts({"health_check": self.BODY}, run)
        self.assertEqual(len(run.sent), 2)
        self.assertIn("\\r\\n", run.sent[1])

    def test_missing_script_and_failed_command_give_missing_and_unknown(self):
        run = fake_router({})
        self.assertEqual(router_doctor.drift_verdicts({"health_check": self.BODY}, run),
                         {"health_check": "missing"})
        self.assertEqual(router_doctor.drift_verdicts({"health_check": self.BODY},
                                                      lambda cmd: (1, "")),
                         {"health_check": "unknown"})
        self.assertEqual(router_doctor.drift_verdicts({"health_check": self.BODY},
                                                      lambda cmd: (0, "DRF:health_check|error\n")),
                         {"health_check": "unknown"})

    def test_commands_are_batched_under_the_limit(self):
        sources = {"s%d" % i: b"x" * 1000 for i in range(10)}
        batches = router_doctor.drift_commands(sources, limit=2500)
        self.assertGreater(len(batches), 1)
        self.assertEqual(sorted(n for names, _ in batches for n in names), sorted(sources))
        for _, command in batches:
            self.assertLess(len(command), 2500 + len(router_doctor.DRIFT_BLOCK) * 2)
        big = router_doctor.drift_commands({"a": b"y" * 5000, "b": b"z"}, limit=100)
        self.assertEqual([names for names, _ in big], [["a"], ["b"]])

    def test_expected_source_drops_one_trailing_line_end(self):
        self.assertEqual(router_doctor.expected_source(b"a\nb\n"), b"a\nb")
        self.assertEqual(router_doctor.expected_source(b"a\r\nb\r\n"), b"a\nb")
        self.assertEqual(router_doctor.expected_source(b"a\nb\n", crlf=True), b"a\r\nb")

    def test_parse_drift_reads_words(self):
        self.assertEqual(
            router_doctor.parse_drift("noise\nDRF:a|same\nDRF:b|c|changed\r\nDRF:|x\n"),
            {"a": "same", "b|c": "changed"},
        )

    def test_edited_script_is_reported_as_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            package_dir, _ = self.package(tmp)
            paths = router_doctor.local_script_paths(package_dir)
            verdicts, findings = router_doctor.drift_findings(
                {"health_check": "changed"}, paths, package_dir)
        self.assertEqual(verdicts, {"health_check": "changed"})
        warns = [m for level, m in findings if level == "warn"]
        self.assertEqual(len(warns), 1)
        self.assertIn("health_check on the router differs from mikrotik/features/"
                      "health_check.lua", warns[0])

    def test_unknown_script_warns_and_is_not_counted(self):
        with tempfile.TemporaryDirectory() as tmp:
            package_dir, _ = self.package(tmp)
            paths = router_doctor.local_script_paths(package_dir)
            _, findings = router_doctor.drift_findings(
                {"health_check": "unknown"}, paths, package_dir)
        warns = [m for lv, m in findings if lv == "warn"]
        self.assertIn("could not compare health_check", warns[0])

    def test_identical_script_is_silent_and_counted_in_the_info_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            package_dir, _ = self.package(tmp)
            paths = router_doctor.local_script_paths(package_dir)
            verdicts, findings = router_doctor.drift_findings(
                {"health_check": "same"}, paths, package_dir)
        self.assertEqual(verdicts, {"health_check": "same"})
        self.assertEqual(findings, [
            ("info", "1 of 1 compared package scripts match the files in this checkout"),
        ])

    def test_script_not_in_the_package_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            package_dir, _ = self.package(tmp)
            paths = router_doctor.local_script_paths(package_dir)
            verdicts, findings = router_doctor.drift_findings(
                {"startup": "changed"}, paths, package_dir)
        self.assertEqual(verdicts, {})
        self.assertEqual([lv for lv, _ in findings], ["info"])

    def test_local_script_paths_walks_core_and_features_skips_tests_and_raises_on_unreadable(self):
        with tempfile.TemporaryDirectory() as tmp:
            for folder in ("core", "features", "tests"):
                os.mkdir(os.path.join(tmp, folder))
            for rel in ("core/tg_send.lua", "features/backup.lua", "tests/fixture.lua",
                        "features/notes.md"):
                with open(os.path.join(tmp, rel), "w", encoding="utf-8") as fh:
                    fh.write("x")
            paths = router_doctor.local_script_paths(tmp)
            self.assertEqual(sorted(paths), ["backup", "tg_send"])
            self.assertEqual(paths["tg_send"], os.path.join(tmp, "core", "tg_send.lua"))

            core = os.path.join(tmp, "core")
            real_scandir = os.scandir

            def refuse_core(path=".", *args, **kwargs):
                if str(path) == core:
                    raise PermissionError(13, "Permission denied", str(path))
                return real_scandir(path, *args, **kwargs)

            with mock.patch("os.scandir", refuse_core), self.assertRaises(OSError):
                router_doctor.local_script_paths(tmp)
        self.assertEqual(router_doctor.local_script_paths("/nonexistent/mikrotik"), {})

    def test_drift_command_only_reads_and_writes_nothing(self):
        command = router_doctor.drift_commands({"health_check": b"plain\n"})[0][1]
        block = router_doctor.DRIFT_BLOCK
        for text in (command, block):
            for verb in (" set ", ":set", ":global", " add ", " remove ", " enable ",
                         " disable ", ":convert", ":parse"):
                self.assertNotIn(verb, text)
        self.assertEqual(command.count("\n"), 0)
        # no function call with named arguments: the text is inline
        self.assertNotIn("[$", command)
        # the only things printed are the name and the router's one-word answer
        self.assertEqual(command.count(":put ("), 4)
        self.assertEqual(
            re.findall(r':put \("DRF:health_check\|(\w[\w-]*)"\)', command),
            ["missing", "same", "changed-cr", "changed"],
        )
        self.assertNotIn(":put $", block)

    def test_default_probe_does_not_contain_the_drift_probe(self):
        self.assertNotIn("DRF:", router_doctor.PROBE)
        self.assertNotIn("expected", router_doctor.PROBE)
        calls = []

        def fake_probe(host, user, identity, port, timeout, command=router_doctor.PROBE):
            calls.append(command)
            return 0, REPORT, ""

        with mock.patch.object(router_doctor, "probe", side_effect=fake_probe), \
             mock.patch.object(router_doctor, "local_script_names", return_value=PACKAGE), \
             contextlib.redirect_stdout(io.StringIO()):
            router_doctor.main(["--host", "router.test"])
        self.assertEqual(calls, [router_doctor.PROBE])

    def test_json_drift_contains_verdicts_only_not_sources(self):
        report = (
            "SCR:tg_send\nSCR:health_check\n"
            "SCH:health_check|5m|/system script run health_check\n"
            "ENV:TgBotToken|46\nENV:TgChatId|9\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            package_dir = os.path.join(tmp, "mikrotik")
            os.makedirs(os.path.join(package_dir, "core"))
            for name, body in (("health_check", b"secret-looking-body\n"),
                               ("tg_send", b"tg body\n")):
                with open(os.path.join(package_dir, "core", name + ".lua"), "wb") as fh:
                    fh.write(body)
            router = fake_router({"health_check": b"ROUTER-ONLY-SOURCE-7f3a\n",
                                  "tg_send": b"tg body\n"})

            def fake_probe(host, user, identity, port, timeout, command=router_doctor.PROBE):
                if command == router_doctor.PROBE:
                    return 0, report, ""
                rc, out = router(command)
                return rc, out, ""

            stdout = io.StringIO()
            with mock.patch.object(router_doctor, "probe", side_effect=fake_probe), \
                 contextlib.redirect_stdout(stdout):
                rc = router_doctor.main(["--host", "router.test", "--format", "json",
                                         "--drift", "--scripts-dir", package_dir])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 0)
        self.assertEqual(payload["drift"], {"health_check": "changed", "tg_send": "same"})
        self.assertNotIn("secret-looking-body", stdout.getvalue())
        self.assertNotIn("ROUTER-ONLY-SOURCE-7f3a", stdout.getvalue())
        self.assertNotIn("tg body", stdout.getvalue())

    def test_lone_copy_without_lua_files_gives_one_info_and_no_warn(self):
        verdicts, findings = router_doctor.drift_findings(
            {"health_check": "changed"}, {}, "/nonexistent/mikrotik"
        )
        self.assertEqual(verdicts, {})
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0][0], "info")
        self.assertIn("no .lua files to compare against", findings[0][1])

if __name__ == "__main__":
    unittest.main()

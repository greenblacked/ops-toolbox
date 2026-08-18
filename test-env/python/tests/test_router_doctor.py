"""Tests for mikrotik/router_doctor.py.

Only the layer between the router's answer and the verdict is covered, which is
where all the judgement lives: what counts as "scheduled", what counts as a
finding rather than a choice, and what the tool is allowed to know about a
secret. The ssh call either reaches a router or it does not, and stubbing it
would test the stub.

Two of these guard mistakes the tool exists to catch, so they are worth naming:
`backup` must not be reported as scheduled because some other entry mentions
`backup_file_cleanup`, and a global's value must never be fetched — only its
length, which is what makes "TG_BOT_TOKEN is set" printable at all.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
sys.path.insert(0, os.path.join(REPO_ROOT, "mikrotik"))

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
ENV:TG_BOT_TOKEN|46
ENV:TG_CHAT_ID|9
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
        self.assertEqual(env, {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9})

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
            "ENV:TG_CHAT_ID|9\n"
        )
        _, schedulers, env = router_doctor.parse_report(text)
        self.assertEqual(len(schedulers), 1)
        self.assertIn("tg_send", schedulers[0]["on_event"])
        self.assertIn("back online", schedulers[0]["on_event"])
        self.assertEqual(env, {"TG_CHAT_ID": 9})

    def test_carriage_returns_do_not_end_up_in_names(self):
        scripts, _, env = router_doctor.parse_report("SCR:backup\r\nENV:TG_CHAT_ID|9\r\n")
        self.assertEqual(scripts, ["backup"])
        self.assertEqual(env, {"TG_CHAT_ID": 9})

    def test_an_unreadable_length_is_treated_as_empty(self):
        _, _, env = router_doctor.parse_report("ENV:TG_CHAT_ID|nan\n")
        self.assertEqual(env, {"TG_CHAT_ID": 0})

    def test_empty_output_parses_to_nothing(self):
        self.assertEqual(router_doctor.parse_report(""), ([], [], {}))

    def test_pause_control_is_parsed_without_exposing_secrets(self):
        _, _, env = router_doctor.parse_report(
            "ENV:TG_BOT_TOKEN|46\nCTL:OpsToolboxPaused|true\n"
        )
        self.assertEqual(env["TG_BOT_TOKEN"], 46)
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
        self.assertEqual(router_doctor.global_state("TG_CHAT_ID", {"TG_CHAT_ID": 9}), "set")

    def test_zero_length_means_empty(self):
        # `:global TG_CHAT_ID ""` in a startup script looks configured and is
        # not, which is worth telling apart from never having been set.
        self.assertEqual(router_doctor.global_state("TG_CHAT_ID", {"TG_CHAT_ID": 0}), "empty")

    def test_an_unknown_name_is_absent(self):
        self.assertEqual(router_doctor.global_state("TG_CHAT_ID", {}), "absent")


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
            PACKAGE, installed, schedulers, {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9}
        )
        self.assertEqual(levels_for(findings, "backup is scheduled but not in"), ["fail"])

    def test_a_missing_tg_send_fails_the_whole_package(self):
        installed = ["backup", "health_check"]
        schedulers = [{"name": "backup", "interval": "1d",
                       "on_event": "/system script run backup"},
                      {"name": "health_check", "interval": "5m",
                       "on_event": "/system script run health_check"}]
        findings = router_doctor.build_findings(
            PACKAGE, installed, schedulers, {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9}
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
            {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9},
        )
        self.assertEqual(levels_for(findings, "reboot-and-flush is meant to be run by hand"),
                         ["warn"])

    def test_a_manual_script_without_a_scheduler_says_nothing(self):
        findings = router_doctor.build_findings(
            ["tg_send", "detect_internet"], ["tg_send", "detect_internet"], [],
            {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9},
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
            ["tg_send"], ["tg_send"], schedulers, {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9}
        )
        self.assertEqual(findings, [])

    def test_an_unset_telegram_global_is_a_warning(self):
        installed, schedulers, _ = self.parsed()
        findings = router_doctor.build_findings(PACKAGE, installed, schedulers, {})
        self.assertEqual(levels_for(findings, "TG_BOT_TOKEN is not set"), ["warn"])
        self.assertEqual(levels_for(findings, "TG_CHAT_ID is not set"), ["warn"])

    def test_an_empty_telegram_global_is_reported_separately(self):
        installed, schedulers, _ = self.parsed()
        findings = router_doctor.build_findings(
            PACKAGE, installed, schedulers, {"TG_BOT_TOKEN": 0, "TG_CHAT_ID": 9}
        )
        self.assertEqual(levels_for(findings, "TG_BOT_TOKEN is defined but empty"), ["warn"])

    def test_no_finding_ever_carries_the_length_of_a_global(self):
        installed, schedulers, _ = self.parsed()
        findings = router_doctor.build_findings(
            PACKAGE, installed, schedulers, {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9}
        )
        for _, message in findings:
            self.assertNotIn("46", message)

    def test_mac_allowlist_without_its_global_does_nothing_and_says_so(self):
        installed = ["tg_send", "mac_allowlist_dhcp"]
        schedulers = [{"name": "mac_allowlist_dhcp", "interval": "5m",
                       "on_event": "/system script run mac_allowlist_dhcp"}]
        findings = router_doctor.build_findings(
            ["tg_send", "mac_allowlist_dhcp"], installed, schedulers,
            {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9},
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
            {"TG_BOT_TOKEN": 46, "TG_CHAT_ID": 9},
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
        secret_marker = "token-that-must-stay-on-router"
        report = (
            "SCR:backup\n"
            "SCH:backup|1d|/system script run backup; :local secret=%s\n"
            "ENV:TG_BOT_TOKEN|46\nENV:TG_CHAT_ID|9\n"
        ) % secret_marker
        stdout = io.StringIO()
        with mock.patch.object(router_doctor, "probe", return_value=(0, report, "")), \
             mock.patch.object(router_doctor, "local_script_names", return_value=["backup"]), \
             contextlib.redirect_stdout(stdout):
            router_doctor.main(["--host", "router.test", "--format", "json"])
        payload = json.loads(stdout.getvalue())
        self.assertNotIn(secret_marker, stdout.getvalue())
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


if __name__ == "__main__":
    unittest.main()

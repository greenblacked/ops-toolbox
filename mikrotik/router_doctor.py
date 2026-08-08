#!/usr/bin/env python3
"""Say what is actually installed and scheduled on a RouterOS router.

Every script in this folder is pasted into `/system script` by hand and given a
`/system scheduler` entry by hand, and both halves fail quietly. A script that
was never installed under the name its scheduler calls, a script installed but
scheduled nowhere, an unset `TG_BOT_TOKEN` — all three look exactly like a
router with nothing to report. The router knows the answer; nothing asks it.

Read-only, like the other diagnostics here: it runs `find`/`get` over ssh, it
never writes to the router, and it prints the command that fixes what it found.

Secrets are never fetched. The check on `TG_BOT_TOKEN` and `TG_CHAT_ID` asks the
router for the *length* of each global, so no token value crosses the wire or
reaches this process, let alone the terminal.

    ./router_doctor.py --host 192.168.88.1
    ./router_doctor.py --host router.lan --user admin --identity ~/.ssh/keys/mikrotik
    ./router_doctor.py --host router.lan --port 2222

Exit codes: 0 findings printed, 1 connected but the probe failed, 2 could not
connect, 4 nothing wrong.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Scripts that are meant to be run by hand. "No scheduler" is the correct state
# for these, and print_schedulers.sh does not emit entries for them either —
# scheduling reboot-and-flush in particular is a surprise nobody wants twice.
MANUAL_ONLY = (
    "tg_send",
    "detect_internet",
    "reboot-and-flush",
    "firewall_drift_baseline",
    "change_WIFI_pw",
)

# Read by tg_send, so effectively by every script that notifies. An unset global
# is not proof of a broken router — tg_send also has placeholders in its own
# source — but on an unedited script it means every alert is silently dropped.
REQUIRED_GLOBALS = ("TG_BOT_TOKEN", "TG_CHAT_ID")

# Globals a single script cannot work without. mac_allowlist_dhcp refuses to act
# on an empty allowlist by design, so without this it is installed, scheduled,
# and doing nothing at all.
SCRIPT_GLOBALS = (("mac_allowlist_dhcp", "MAC_ALLOWLIST"),)

# One ssh round trip, three tagged record types. Tags rather than section
# headers because an on-event is free-form and may contain newlines: an untagged
# line is a continuation of the scheduler being read, not a new record.
PROBE = (
    ':foreach s in=[/system script find] do={'
    ':put ("SCR:" . [/system script get $s name])};'
    ' :foreach k in=[/system scheduler find] do={'
    ':put ("SCH:" . [/system scheduler get $k name]'
    ' . "|" . [:tostr [/system scheduler get $k interval]]'
    ' . "|" . [:tostr [/system scheduler get $k on-event]])};'
    ' :foreach e in=[/system script environment find] do={'
    ':put ("ENV:" . [/system script environment get $e name]'
    ' . "|" . [:tostr [:len [:tostr [/system script environment get $e value]]]])}'
)

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = C_BOLD = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"


def ok(msg):
    print("%s[ ok ]%s %s" % (C_GREEN, C_RESET, msg))


def warn(msg):
    print("%s[warn]%s %s" % (C_YELLOW, C_RESET, msg))


def bad(msg):
    print("%s[fail]%s %s" % (C_RED, C_RESET, msg))


def info(msg):
    print("%s[info]%s %s" % (C_DIM, C_RESET, msg))


def head(msg):
    print("\n%s== %s ==%s" % (C_BOLD, msg, C_RESET))


PRINTER = {"fail": bad, "warn": warn, "info": info}


# --------------------------------------------------------------------------
# parsing — everything below takes strings and returns data, so it is testable
# without a router
# --------------------------------------------------------------------------
def parse_report(text):
    """Turn the router's tagged output into (scripts, schedulers, globals).

    scripts is a list of names in /system script, schedulers a list of dicts
    with name/interval/on_event, globals a dict of name -> value *length*. The
    length is what the router was asked for; the value itself is never read.
    """
    scripts = []
    schedulers = []
    env = {}
    current = None

    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line.startswith("SCR:"):
            current = None
            name = line[4:].strip()
            if name:
                scripts.append(name)
        elif line.startswith("SCH:"):
            fields = line[4:].split("|", 2)
            current = {
                "name": fields[0].strip(),
                "interval": fields[1].strip() if len(fields) > 1 else "",
                "on_event": fields[2] if len(fields) > 2 else "",
            }
            schedulers.append(current)
        elif line.startswith("ENV:"):
            current = None
            name, _, length = line[4:].partition("|")
            name = name.strip()
            if name:
                env[name] = _as_int(length)
        elif current is not None:
            # A multi-line on-event. Keeping the newlines means the text stays
            # searchable for a script name that sits on a later line.
            current["on_event"] += "\n" + line

    return scripts, schedulers, env


def _as_int(text):
    try:
        return int(text.strip())
    except ValueError:
        return 0


def runs_script(on_event, name):
    """Whether an on-event body runs the named script.

    Substring matching is not enough: the on-event that runs
    backup_file_cleanup contains "backup", and reporting backup as scheduled
    when it is not is the exact failure this tool exists to catch.
    """
    pattern = r"(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])" % re.escape(name)
    return re.search(pattern, on_event) is not None


def schedulers_for(name, schedulers):
    """The scheduler entries that run the named script.

    A scheduler whose own name matches counts too: print_schedulers.sh names
    each entry after its script, and an entry someone wrote by hand around
    inline code is still that script being scheduled.
    """
    return [
        s for s in schedulers
        if s.get("name") == name or runs_script(s.get("on_event", ""), name)
    ]


def global_state(name, env):
    """'set', 'empty' or 'absent', decided from the length alone."""
    if name not in env:
        return "absent"
    return "set" if env[name] > 0 else "empty"


def local_script_names(directory):
    """The .lua scripts next to this file, under the names they take on the router."""
    try:
        entries = os.listdir(directory)
    except OSError:
        return []
    return sorted(name[:-4] for name in entries if name.endswith(".lua"))


def build_findings(local, installed, schedulers, env):
    """Compare what should be on the router with what is.

    Pure: no ssh, no filesystem, no clock. Returns a list of (level, message)
    with level in {'fail', 'warn', 'info'}; 'info' is context rather than a
    finding, and does not count towards the exit code.
    """
    findings = []
    local = list(local)
    installed_set = set(installed)
    local_set = set(local)

    # --- installed at all ---
    # Not installing a script is a choice — nobody wants ddns_update without
    # Cloudflare — so a missing one is context, not a finding. What is never a
    # choice is a scheduler calling a script that is not there.
    missing = []
    for name in local:
        if name in installed_set:
            continue
        if schedulers_for(name, schedulers):
            findings.append((
                "fail",
                "%s is scheduled but not in /system script — that scheduler "
                "fails at every run" % name,
            ))
        elif name == "tg_send" and installed_set & local_set:
            findings.append((
                "fail",
                "tg_send is not installed — every other script here notifies "
                "through it, so every alert is a no-op",
            ))
        else:
            missing.append(name)

    # --- installed but never run ---
    # Only judge scripts this package ships. When the .lua files are not next to
    # this one (a lone copy in ~/bin), fall back to what the router has, minus
    # the manual ones — anything else would be guessing about someone else's
    # scripts.
    candidates = sorted(local_set & installed_set) if local else sorted(installed_set)
    for name in candidates:
        if name in MANUAL_ONLY:
            continue
        if not schedulers_for(name, schedulers):
            findings.append((
                "warn",
                "%s is installed but no scheduler runs it" % name,
            ))

    # --- run but meant to be manual ---
    for name in MANUAL_ONLY:
        if name == "tg_send":
            # A scheduler calling tg_send is how the notify-boot entry works.
            continue
        entries = schedulers_for(name, schedulers)
        if entries and name in installed_set:
            findings.append((
                "warn",
                "%s is meant to be run by hand, but scheduler \"%s\" runs it"
                % (name, entries[0].get("name", "?")),
            ))

    # --- globals ---
    for name in REQUIRED_GLOBALS:
        state = global_state(name, env)
        if state == "absent":
            findings.append((
                "warn",
                "%s is not set on the router — tg_send falls back to the "
                "placeholder in its own source" % name,
            ))
        elif state == "empty":
            findings.append(("warn", "%s is defined but empty" % name))

    for script, name in SCRIPT_GLOBALS:
        if script not in installed_set:
            continue
        if global_state(name, env) != "set":
            findings.append((
                "warn",
                "%s needs %s, which is not set — it refuses to act on an empty "
                "list, so it currently does nothing" % (script, name),
            ))

    # --- context ---
    if missing:
        findings.append((
            "info",
            "in this folder but not installed, which may well be deliberate: %s"
            % ", ".join(missing),
        ))
    if local:
        strangers = sorted(installed_set - local_set)
        if strangers:
            findings.append((
                "info",
                "on the router but not in this folder: %s" % ", ".join(strangers),
            ))

    return findings


def has_problems(findings):
    return any(level in ("fail", "warn") for level, _ in findings)


# --------------------------------------------------------------------------
# the one part that needs a router
# --------------------------------------------------------------------------
def probe(host, user, identity, port, timeout, command=PROBE):
    """Run one read-only command over ssh. Returns (rc, stdout, stderr)."""
    cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        "-p", str(port),
    ]
    if identity:
        cmd += ["-o", "IdentitiesOnly=yes", "-i", os.path.expanduser(identity)]
    cmd.append("%s@%s" % (user, host))
    cmd.append(command)

    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        # ssh reserves 255 for its own failures, so a missing binary or a
        # timeout is reported the same way it would report a refused
        # connection: as never having got there.
        return 255, "", str(exc)
    return (
        p.returncode,
        p.stdout.decode("utf-8", "replace"),
        p.stderr.decode("utf-8", "replace"),
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read-only check of which RouterOS scripts are installed, "
                    "scheduled, and configured.",
        epilog="Exit codes: 0 findings printed, 1 connected but the probe failed, "
               "2 could not connect, 4 nothing wrong.",
    )
    parser.add_argument("--host", required=True, help="router hostname or address")
    parser.add_argument("--user", default="admin", help="RouterOS user (default: admin)")
    parser.add_argument("--identity", help="ssh private key to use")
    parser.add_argument("--port", type=int, default=22, help="ssh port (default: 22)")
    parser.add_argument("--timeout", type=int, default=30, help="seconds (default: 30)")
    parser.add_argument("--scripts-dir", default=HERE, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    rc, out, err = probe(args.host, args.user, args.identity, args.port, args.timeout)

    if rc == 255:
        bad("cannot reach %s over ssh" % args.host)
        for line in err.strip().splitlines()[:5]:
            print("        %s" % line)
        info("check the host and key, and that SSH is enabled under IP -> Services")
        info("../git/git_ssh_doctor.py --host %s --test-auth will say which key "
             "works" % args.host)
        return 2

    if rc != 0 or not out.strip():
        bad("reached %s but the read-only probe failed (exit %d)" % (args.host, rc))
        for line in err.strip().splitlines()[:5]:
            print("        %s" % line)
        info("the user needs read access to /system script, /system scheduler "
             "and /system script environment")
        return 1

    installed, schedulers, env = parse_report(out)
    local = local_script_names(args.scripts_dir)

    head("router")
    info("%s@%s:%d answered" % (args.user, args.host, args.port))
    info("/system script holds %d entries; /system scheduler holds %d"
         % (len(installed), len(schedulers)))
    if not local:
        warn("no .lua files next to this script — only what the router has can "
             "be checked")

    head("findings")
    findings = build_findings(local, installed, schedulers, env)
    for level, message in findings:
        PRINTER[level](message)

    if not has_problems(findings):
        ok("nothing to fix: everything installed is scheduled and has the "
           "globals it needs")
        return 4

    head("fix")
    info("scheduler lines for every script here: ./print_schedulers.sh")
    info("to install a missing script, paste the .lua body into System > Scripts "
         "with policy read,write,policy,test,sensitive,ftp")
    info("to set a global once at boot, see the startup snippet in README.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Say what is actually installed and scheduled on a RouterOS router.

Every script in this folder is pasted into `/system script` by hand and given a
`/system scheduler` entry by hand, and both halves fail quietly. A script that
was never installed under the name its scheduler calls, a script installed but
scheduled nowhere, an unset `TgBotToken` — all three look exactly like a
router with nothing to report. The router knows the answer; nothing asks it.

Read-only, like the other diagnostics here: it runs `find`/`get` over ssh, it
never writes to the router, and it prints the command that fixes what it found.

Secrets are never fetched. The check on `TgBotToken` and `TgChatId` asks the
router for the *length* of each global, so no token value crosses the wire or
reaches this process, let alone the terminal.

It also asks which RouterOS release the router runs. From 7.24 that release
refuses to execute any script declaring an underscored :global or :local, and
the refusal is silent, so an installed script on that list is reported by name.
The verdict comes from the package's own .lua files; the router's copies are
never read.

    ./router_doctor.py --host 192.168.88.1
    ./router_doctor.py --host router.lan --user admin --identity ~/.ssh/keys/mikrotik
    ./router_doctor.py --host router.lan --port 2222
    ./router_doctor.py --hosts-file ~/routers.txt --format json
    ./router_doctor.py --host router.lan --drift    # which scripts are stale

Exit codes: 0 findings printed, 1 connected but the probe failed, 2 could not
connect, 3 usage, 4 nothing wrong. With --hosts-file each router is audited in
turn and the run exits with the worst of them: 2 if any router could not be
reached, else 1 if any probe failed, else 0 if any printed findings, else 4.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# The package root, one level up: this file lives in features/ and the scripts
# it compares the router against are split across core/ and features/.
PACKAGE_DIR = os.path.dirname(HERE)

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
REQUIRED_GLOBALS = ("TgBotToken", "TgChatId")

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
    ':local n [/system script environment get $e name];'
    ':if ($n = "OpsToolboxPaused") do={'
    ':local v [/system script environment get $e value];'
    ':put ("CTL:OpsToolboxPaused|" . [:tostr (([:typeof $v] = "bool") and $v)])'
    '} else={'
    ':put ("ENV:" . $n'
    ' . "|" . [:tostr [:len [:tostr [/system script environment get $e value]]]])}};'
    # The release decides whether half the package can run at all, so it is
    # asked for once. A version string is not a secret.
    ' :put ("VER:" . [/system resource get version]);'
    # Scheduler state on single-line records of their own, so the free-form
    # on-event of the SCH record above is untouched: a boolean, a counter and
    # a time, nothing an operator wrote.
    ' :foreach k in=[/system scheduler find] do={'
    ':put ("SCX:" . [/system scheduler get $k name]'
    ' . "|" . [:tostr [/system scheduler get $k disabled]]'
    ' . "|" . [:tostr [/system scheduler get $k run-count]]'
    ' . "|" . [:tostr [/system scheduler get $k start-time]])};'
    ' :put ("UPT:" . [:tostr [/system resource get uptime]]);'
    # Which scripts mention each required global, one DECL:script|global
    # record per pair. The router does the search and returns only names: a
    # source can hold a pasted token, so no source ever crosses the wire.
    ' :foreach g in={%s} do={'
    ':foreach s in=[/system script find] do={'
    ':if ([:typeof [:find [/system script get $s source] $g]] = "num") do={'
    ':put ("DECL:" . [/system script get $s name] . "|" . $g)}}};'
    % ";".join('"%s"' % g for g in REQUIRED_GLOBALS)
)

# Asked only under --drift, and not part of PROBE: one ssh command per batch of
# scripts, built by drift_commands(). The comparison runs on the router. The
# expected source (the file in this checkout) travels INTO the router as a
# string literal in the command, and the router answers with one word per
# script: same, changed-cr, changed or missing. No script source leaves the
# router (a source can hold a pasted token) and nothing is written: no
# :global, no :set, no function, no :parse. Each script gets one self-contained
# block of plain :local, :if and :put, so the command uses no call syntax
# beyond what the other scripts in this package already rely on.
#
# changed-cr means "differs, and the router's copy has CR line ends". The
# first round sends the checkout's text with LF line ends; those scripts are
# asked again with CRLF line ends, so a copy stored as CRLF is not drift. A
# trailing newline more or less is not drift either: the block accepts the
# expected text bare, with "\n" and with "\r\n" appended.
#
# Two earlier versions did not run on the pinned release. RouterOS 7.24
# rejects every :convert spelling that was tried for a hash, and the CI
# router rejected a call of a :parse'd function that took the script name
# and the file as two named string arguments (syntax error at the second
# argument), so the comparison is inline and needs neither.
#
# %(n)s is the script name and %(e)s the expected text, both already
# escaped by escape_routeros_string().
DRIFT_BLOCK = (
    ' :do {:local ids [/system script find where name="%(n)s"];'
    ' :if ([:len $ids] = 0) do={:put ("DRF:%(n)s|missing")} else={'
    ':local cur [/system script get $ids source];'
    ' :local exp "%(e)s";'
    ' :if (($cur = $exp) || ($cur = ($exp . "\\n"))'
    ' || ($cur = ($exp . "\\r\\n"))) do={:put ("DRF:%(n)s|same")} else={'
    ':if ([:typeof [:find $cur "\\r"]] = "num") do={:put ("DRF:%(n)s|changed-cr")}'
    ' else={:put ("DRF:%(n)s|changed")}}}}'
    ' on-error={:put "DRF:%(n)s|error"};'
)
# Per ssh command, in characters of escaped source. The whole package is about
# 200 KB, and RouterOS's ssh server is not documented to take a command that
# long, so scripts are sent in batches; one bigger than this goes alone.
DRIFT_BATCH_CHARS = 24000

PAUSE_STATE_KEY = "__control_ops_toolbox_paused"
# Reserved like PAUSE_STATE_KEY: the (major, minor) the router reported, and
# the string it reported it as. Both are absent when the probe returned no VER
# line, which keeps every check that depends on them quiet.
VERSION_KEY = "__routeros_version"
VERSION_TEXT_KEY = "__routeros_version_text"
# Also reserved, also absent unless the probe returned them: the router's
# uptime in seconds, and the scripts whose source mentions TgBotToken.
UPTIME_KEY = "__uptime_seconds"
DECLARES_TG_KEY = "__declares_tg"
# Same, per required global: {global name: [script names whose source mentions
# it]}. DECLARES_TG_KEY is its TgBotToken entry, kept for the older reader.
DECLARES_KEY = "__declares"

# Scripts that read the Telegram globals rather than set them. Mentioning
# TgBotToken does not make them a startup script.
TG_READERS = ("tg_send", "tg_send_new")

# RouterOS 7.24 refuses to execute a script that declares a :global or :local
# whose name contains an underscore. It stops in the parser, so the script logs
# nothing of its own and a scheduler that fires it looks like one with nothing
# to report. The README's per-script compatibility list says which scripts
# that is; this turns the list into a verdict for one router.
UNDERSCORE_REFUSED_FROM = (7, 24)

# Where a 7.24-safe script does the same job. The others have none yet.
REPLACED_BY = {"update_check": "backup_update_check"}

# The scripts that declare an underscored name, as the README lists them
# today. Used only when this file has no package beside it to read (a lone
# copy in ~/bin); with the package present the set is derived from the .lua
# files, and a unit test pins this tuple to that derived set so it cannot rot.
UNDERSCORED_FALLBACK = (
    "bandwidth_spike",
    "brute_force_block",
    "ddns_update",
    "dhcp_lease_watch",
    "firewall_drift",
    "firewall_drift_baseline",
    "latency_monitor",
    "mac_allowlist_dhcp",
    "traffic_quota",
    "update_check",
    "vpn_health",
    "wan_failover_notify",
    "wan_link_flap_notify",
    "wireless_client_watch",
)

# The declaration the convention suite and the CHR suite both test for.
# Comment lines start with '#', so a comment naming an old global never matches.
_UNDERSCORED_DECLARATION = re.compile(r"^\s*:(?:global|local)\s+[A-Za-z0-9]*_", re.M)
_VERSION = re.compile(r"^\s*(\d+)\.(\d+)")
# Both spellings RouterOS uses for a duration: '1w2d03:04:05' in the console
# and '1w2d3h4m5s' from some properties, plus the bare forms '5m' and '1d'.
_DURATION = re.compile(
    r"^(?:(?P<w>\d+)w)?(?:(?P<d>\d+)d)?"
    r"(?:(?P<clock_h>\d+):(?P<clock_m>\d{1,2}):(?P<clock_s>\d{1,2})(?:\.\d+)?"
    r"|(?:(?P<h>\d+)h)?(?:(?P<m>\d+)m)?(?:(?P<s>\d+)s)?)$"
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
    with name/interval/on_event, and globals maps secret names to value lengths.
    The reserved PAUSE_STATE_KEY maps to the computed non-secret boolean pause
    predicate; malformed/non-boolean values are reported as inactive exactly as
    the scripts enforce them. VERSION_KEY holds the RouterOS (major, minor)
    when the router reported one. A scheduler gains disabled, run_count and
    start_time when the probe returned them, and the reserved UPTIME_KEY and
    DECLARES_TG_KEY hold the uptime in seconds and the scripts that mention
    TgBotToken; DECLARES_KEY holds that per required global, from DECL:script|
    global records (a bare DECL:script is read as TgBotToken).
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
                # Secret globals remain lengths only. The fleet pause is a
                # non-secret boolean and arrives through its explicit CTL row.
                env[name] = _as_int(length)
        elif line.startswith("CTL:OpsToolboxPaused|"):
            current = None
            value = line.partition("|")[2].strip()
            env[PAUSE_STATE_KEY] = value == "true"
        elif line.startswith("SCX:"):
            current = None
            # From the right, so a '|' in a scheduler name cannot shift fields.
            fields = line[4:].rsplit("|", 3)
            if len(fields) == 4:
                name, disabled, run_count, start_time = fields
                for entry in schedulers:
                    if entry["name"] == name.strip():
                        entry["disabled"] = disabled.strip() == "true"
                        entry["run_count"] = _as_int(run_count)
                        entry["start_time"] = start_time.strip()
                        break
        elif line.startswith("UPT:"):
            current = None
            seconds = duration_seconds(line[4:])
            if seconds is not None:
                env[UPTIME_KEY] = seconds
        elif line.startswith("DECL:"):
            current = None
            name, sep, glob = line[5:].rpartition("|")
            if not sep:
                name, glob = glob, "TgBotToken"
            name, glob = name.strip(), glob.strip()
            if name and glob in REQUIRED_GLOBALS:
                declares = env.setdefault(DECLARES_KEY, {})
                declares[glob] = sorted(set(declares.get(glob, [])) | {name})
                if glob == "TgBotToken":
                    env[DECLARES_TG_KEY] = declares[glob]
        elif line.startswith("VER:"):
            current = None
            text_value = line[4:].strip()
            version = parse_version(text_value)
            if version is not None:
                env[VERSION_KEY] = version
                env[VERSION_TEXT_KEY] = text_value
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


def parse_version(text):
    """(major, minor) from a RouterOS version string, or None.

    Accepts what /system resource reports - '7.24.5 (stable)', '7.16rc2
    (testing)', '7.25beta1' - and a bare '7.24'. The patch level is dropped:
    the parser that refuses underscored names changed between minor releases.
    """
    match = _VERSION.match(text or "")
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def format_version(version):
    return "%d.%d" % version


def duration_seconds(text):
    """Seconds in a RouterOS duration, or None when it is not one."""
    text = (text or "").strip()
    if not text:
        return None
    if text.isdigit():
        return int(text)
    match = _DURATION.match(text)
    if match is None or not any(v is not None for v in match.groupdict().values()):
        return None
    parts = {k: int(v) for k, v in match.groupdict().items() if v is not None}
    return (
        parts.get("w", 0) * 604800
        + parts.get("d", 0) * 86400
        + (parts.get("h", 0) + parts.get("clock_h", 0)) * 3600
        + (parts.get("m", 0) + parts.get("clock_m", 0)) * 60
        + parts.get("s", 0) + parts.get("clock_s", 0)
    )


def format_duration(seconds):
    days, rest = divmod(int(seconds), 86400)
    clock = "%02d:%02d:%02d" % (rest // 3600, rest % 3600 // 60, rest % 60)
    return "%dd%s" % (days, clock) if days else clock


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


def active_schedulers_for(name, schedulers):
    """schedulers_for(), minus the entries the router reports as disabled."""
    return [s for s in schedulers_for(name, schedulers) if s.get("disabled") is not True]


def global_state(name, env):
    """'set', 'empty' or 'absent', decided from the length alone."""
    if name not in env:
        return "absent"
    return "set" if env[name] > 0 else "empty"


def local_script_names(directory):
    """The package's .lua scripts, under the names they take on the router.

    Walks, because the scripts live in core/ and features/ rather than in one
    flat directory, and this file sits in one of them. A router script's name
    has no folder in it - core/backup is `backup` on the router - so the names
    this returns are unchanged by how the files are arranged. tests/ is skipped:
    a fixture .lua there is not a script anyone installs.

    A directory that is not there returns [] - this file has to survive being
    copied on its own into ~/bin, with no package beside it, and main() says
    so. A directory that is there and cannot be read raises instead. os.walk
    swallows those by default, one directory at a time, and the result is the
    worst answer this function can give: a list that looks complete and is
    short. Every name it lost is then reported as a script the router has and
    the package does not - with core/ unreadable, the three deployed scripts
    come back as strangers.
    """
    def fail(exc):
        raise exc

    if not os.path.isdir(directory):
        return []

    names = []
    for _root, dirs, files in os.walk(directory, onerror=fail):
        dirs[:] = [d for d in dirs if d != "tests"]
        names.extend(name[:-4] for name in files if name.endswith(".lua"))
    return sorted(names)


def local_script_paths(directory):
    """{router name: path} for the package's .lua scripts.

    The same walk as local_script_names(), with the same refusal to return a
    short answer for a directory it cannot read.
    """
    def fail(exc):
        raise exc

    if not os.path.isdir(directory):
        return {}

    paths = {}
    for root, dirs, files in os.walk(directory, onerror=fail):
        dirs[:] = [d for d in dirs if d != "tests"]
        for name in files:
            if name.endswith(".lua"):
                paths[name[:-4]] = os.path.join(root, name)
    return paths


_ROUTEROS_ESCAPES = {
    0x5C: "\\\\",  # backslash
    0x22: '\\"',
    0x24: "\\$",   # would start a variable
    0x0A: "\\n",
    0x0D: "\\r",
    0x09: "\\t",
}


def escape_routeros_string(value):
    """The inside of a RouterOS double-quoted string literal for value.

    value is bytes, or str (taken as UTF-8). Backslash, double quote and
    dollar get a backslash (a question mark is left as it is, as in the
    package's own scripts); CR, LF and tab become \\r, \\n, \\t;
    any other control character, DEL and every non-ASCII byte becomes \\XX
    (two uppercase hex digits), so the result is printable ASCII on one line.
    The caller adds the surrounding quotes.
    """
    if isinstance(value, str):
        value = value.encode("utf-8")
    out = []
    for byte in value:
        if byte in _ROUTEROS_ESCAPES:
            out.append(_ROUTEROS_ESCAPES[byte])
        elif byte < 0x20 or byte >= 0x7F:
            out.append("\\%02X" % byte)
        else:
            out.append(chr(byte))
    return "".join(out)


def expected_source(raw, crlf=False):
    """The text the router is asked to compare a script against.

    One trailing line end is dropped (the router's function adds it back in
    each spelling), and the line ends are LF, or CRLF when crlf is set.
    """
    if raw.endswith(b"\r\n"):
        raw = raw[:-2]
    elif raw.endswith(b"\n"):
        raw = raw[:-1]
    text = raw.replace(b"\r\n", b"\n")
    return text.replace(b"\n", b"\r\n") if crlf else text


def drift_commands(sources, crlf=False, limit=DRIFT_BATCH_CHARS):
    """[(names, ssh command)] asking the router to compare scripts in place.

    sources maps a script name to the bytes of its file. The command compiles
    DRIFT_BLOCK once per script and prints one 'DRF:name|word' line for each;
    a script whose comparison raises is reported as 'error'. Nothing in a
    command is written to the router.
    """
    batches = []
    names = []
    parts = []
    size = 0
    for name in sorted(sources):
        part = DRIFT_BLOCK % {
            "n": escape_routeros_string(name),
            "e": escape_routeros_string(expected_source(sources[name], crlf)),
        }
        if parts and size + len(part) > limit:
            batches.append((names, "".join(parts)))
            names, parts, size = [], [], 0
        names.append(name)
        parts.append(part)
        size += len(part)
    if parts:
        batches.append((names, "".join(parts)))
    return batches


def parse_drift(text):
    """{script name: word} from the 'DRF:name|word' lines of a drift probe."""
    words = {}
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line.startswith("DRF:"):
            name, sep, word = line[4:].rpartition("|")
            if sep and name.strip():
                words[name.strip()] = word.strip()
    return words


def drift_verdicts(sources, run):
    """{name: 'same' | 'changed' | 'missing' | 'unknown'} by asking the router.

    run(command) returns (exit code, stdout). A script the router did not
    answer for (a failed command, an error in the comparison, an unknown
    word) is 'unknown', never guessed.
    """
    answers = {}

    def ask(subset, crlf):
        for names, command in drift_commands(subset, crlf):
            rc, out = run(command)
            if rc != 0:
                continue
            got = parse_drift(out)
            for name in names:
                if name in got:
                    answers[name] = got[name]

    ask(sources, False)
    again = {n: sources[n] for n, w in answers.items() if w == "changed-cr"}
    if again:
        for name in again:
            del answers[name]
        ask(again, True)
        for name in again:
            if answers.get(name) == "changed-cr":
                answers[name] = "changed"
    verdicts = {}
    for name in sources:
        word = answers.get(name)
        verdicts[name] = word if word in ("same", "changed", "missing") else (
            "changed" if word == "changed-cr" else "unknown")
    return verdicts


def drift_findings(verdicts, paths, package_dir):
    """(verdicts, findings) for the installed scripts this package ships.

    verdicts is what drift_verdicts() returned, paths what local_script_paths()
    found. A script on the router that is not in the package is someone
    else's, and is skipped. A 'missing' one vanished between the two probes
    and is skipped too. Pure.
    """
    if not paths:
        return {}, [("info", "no .lua files to compare against; --drift needs the "
                              "package beside this file")]
    result = {}
    findings = []
    unknown = []
    for name in sorted(verdicts):
        if name not in paths or verdicts[name] == "missing":
            continue
        result[name] = verdicts[name]
        if verdicts[name] == "changed":
            relative = os.path.relpath(
                paths[name], os.path.dirname(os.path.normpath(package_dir))
            )
            findings.append((
                "warn",
                "%s on the router differs from %s: edited in place or out of "
                "date (tuned thresholds also show here)" % (name, relative),
            ))
        elif verdicts[name] == "unknown":
            unknown.append(name)
    if unknown:
        findings.append((
            "warn",
            "--drift could not compare %s: the router gave no answer for %s"
            % (", ".join(unknown), "it" if len(unknown) == 1 else "them"),
        ))
    compared = [v for v in result.values() if v != "unknown"]
    findings.append((
        "info",
        "%d of %d compared package scripts match the files in this checkout"
        % (compared.count("same"), len(compared)),
    ))
    return result, findings


def declares_underscored_name(source_text):
    """Whether a script declares a :global or :local with an underscore.

    The same pattern the convention suite and the CHR suite use, so the three
    cannot disagree about which scripts 7.24 refuses.
    """
    return _UNDERSCORED_DECLARATION.search(source_text) is not None


def underscored_script_names(directory):
    """The package scripts RouterOS 7.24 refuses to run, by router name.

    Walks exactly the way local_script_names() does, and for the same reason
    raises on a directory it cannot read: a short list here would clear a
    script that never runs.
    """
    def fail(exc):
        raise exc

    if not os.path.isdir(directory):
        return []

    names = []
    for root, dirs, files in os.walk(directory, onerror=fail):
        dirs[:] = [d for d in dirs if d != "tests"]
        for name in files:
            if not name.endswith(".lua"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                if declares_underscored_name(fh.read()):
                    names.append(name[:-4])
    return sorted(names)


def incompatible_scripts(installed, env, underscored=None):
    """The installed scripts this router's release refuses to run.

    Judged by name only: the router's copy is never read, so a script an
    operator renamed or rewrote in place is not inspected. Empty when the
    probe returned no version, or the version predates the refusal.
    """
    version = env.get(VERSION_KEY)
    if version is None or version < UNDERSCORE_REFUSED_FROM:
        return []
    names = UNDERSCORED_FALLBACK if underscored is None else underscored
    return sorted(set(names) & set(installed))


def build_findings(local, installed, schedulers, env, underscored=None):
    """Compare what should be on the router with what is.

    Pure: no ssh, no filesystem, no clock. Returns a list of (level, message)
    with level in {'fail', 'warn', 'info'}; 'info' is context rather than a
    finding, and does not count towards the exit code.

    underscored names the scripts that declare an underscored :global/:local;
    None means UNDERSCORED_FALLBACK, the list for a lone copy with no package.
    """
    findings = []
    local = list(local)
    installed_set = set(installed)
    local_set = set(local)

    if env.get(PAUSE_STATE_KEY) is True:
        findings.append((
            "warn",
            "OpsToolboxPaused is true — scheduled ops-toolbox RouterOS scripts "
            "will return without acting",
        ))

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

    # --- scheduled, but does the scheduler run ---
    # Everything here is judged only on what the probe returned: a scheduler
    # dict without these keys, from an older probe, is never accused.
    judged = [n for n in candidates if n not in MANUAL_ONLY]
    for name in judged:
        for entry in schedulers_for(name, schedulers):
            if entry.get("disabled") is True:
                findings.append((
                    "warn",
                    "%s is scheduled by \"%s\", but that scheduler is disabled "
                    "— it never runs" % (name, entry.get("name", "?")),
                ))

    uptime = env.get(UPTIME_KEY)
    for entry in schedulers:
        if entry.get("disabled") is not False or entry.get("run_count") != 0:
            continue
        if entry.get("start_time") == "startup":
            continue
        interval = duration_seconds(entry.get("interval", ""))
        if not interval or uptime is None:
            continue
        # Twice the interval and a minute more, so a router that has just
        # rebooted, or an entry anchored later in the day, is not accused.
        if uptime > 2 * interval + 60:
            findings.append((
                "warn",
                "\"%s\" has never fired in %s of uptime; check /log for \"not "
                "enough permissions\" and that the scheduler policy covers the "
                "script policy" % (entry.get("name", "?"), format_duration(uptime)),
            ))

    # Globals are runtime state. Set by hand today, they are gone after the
    # next reboot unless a startup scheduler declares them again - the trap the
    # 7.24 migration in README.md walks into.
    probe_saw_start_times = UPTIME_KEY in env or any("start_time" in s for s in schedulers)
    set_now = [n for n in REQUIRED_GLOBALS if global_state(n, env) == "set"]
    if set_now and probe_saw_start_times:
        # Each name is judged on its own: a startup entry that restores only
        # TgBotToken leaves TgChatId gone after a reboot.
        declared = env.get(DECLARES_KEY, {})
        not_restored = []
        for glob in set_now:
            if glob in declared:
                names = declared[glob]
            elif glob == "TgBotToken":
                names = env.get(DECLARES_TG_KEY, [])
            else:
                names = []
            declarers = set(names) - set(local) - set(TG_READERS)
            restored = False
            for entry in schedulers:
                if entry.get("start_time") != "startup" or entry.get("disabled") is True:
                    continue
                on_event = entry.get("on_event", "")
                if (glob in on_event or entry.get("name") in declarers
                        or any(runs_script(on_event, d) for d in declarers)):
                    restored = True
                    break
            if not restored:
                not_restored.append(glob)
        if not_restored:
            findings.append((
                "warn",
                "%s %s set now but nothing re-declares %s after a reboot: globals "
                "do not survive one (see Installation step 4 in README.md)"
                % (" and ".join(not_restored), "is" if len(not_restored) == 1 else "are",
                   "it" if len(not_restored) == 1 else "them"),
            ))

    # --- will it run on this release ---
    # Only when the router said which release it runs: an older probe, or one
    # whose version line did not parse, stays silent rather than guessing.
    version = env.get(VERSION_KEY)
    if version is not None:
        names = UNDERSCORED_FALLBACK if underscored is None else underscored
        affected = sorted(set(names) & installed_set)
        if version >= UNDERSCORE_REFUSED_FROM:
            for name in affected:
                replacement = REPLACED_BY.get(name)
                if replacement:
                    instead = "replacement: %s" % replacement
                else:
                    instead = "no replacement yet, see Scripts overview in README.md"
                # fail only for the case that is silent for certain: it is
                # scheduled, so it is being run, and every run dies unlogged.
                level = "fail" if active_schedulers_for(name, schedulers) else "warn"
                findings.append((
                    level,
                    "%s is installed but RouterOS %s refuses to execute scripts "
                    "that declare an underscored :global/:local; it fails "
                    "silently every time it runs (%s)"
                    % (name, format_version(version), instead),
                ))
        elif affected:
            findings.append((
                "info",
                "these installed scripts will stop running on RouterOS 7.24, "
                "migrate before upgrading: %s" % ", ".join(affected),
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


class Usage3Parser(argparse.ArgumentParser):
    """An ArgumentParser that exits 3 on a usage error, the way the rest of the
    tree does.

    CONTRIBUTING.md asks the same thing of every command-line script here: an
    unknown flag prints a message on stderr, then the usage, then exits 3. The
    Bash half of the repository does that and is held to it. Argparse exits 2
    instead, which this repository spends on "wrong environment" — so a
    mistyped flag came back indistinguishable from a machine that could not
    answer, and in the diagnostics that document an exit 2 of their own,
    literally the same number for a typo and for a finding.

    Copied rather than shared, like require_value() in the shell scripts: what
    is asserted about the copies is their contract, not their bytes.
    """

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(3, "%s: error: %s\n" % (self.prog, message))


def scan_package(directory):
    """(local script names, underscored names) for the package under directory.

    Raises OSError when a directory there cannot be read; see
    local_script_names() for why a partial answer is refused.
    """
    local = local_script_names(directory)
    # The underscore verdict comes from the files themselves whenever they are
    # here; the embedded list is only for a copy with no package.
    underscored = underscored_script_names(directory) if local else None
    return local, underscored


def emit(lines):
    """Print what run_one() collected, through the same helpers as ever."""
    for kind, message in lines:
        if kind == "head":
            head(message)
        elif kind == "ok":
            ok(message)
        elif kind == "raw":
            print(message)
        else:
            PRINTER[kind](message)


def run_one(user, host, port, args, package=None):
    """Probe one router. Returns (exit code, JSON payload, text lines).

    Nothing is printed here, so a fleet can put each router under its own
    heading and still total them up. package is (local, underscored) when the
    caller has already scanned it once for a whole fleet; None scans it after
    the probe, which is the order a single router has always had.
    """
    lines = []
    rc, out, err = probe(host, user, args.identity, port, args.timeout)
    errors = err.strip().splitlines()[:5]

    if rc == 255:
        lines.append(("fail", "cannot reach %s over ssh" % host))
        lines.extend(("raw", "        %s" % line) for line in errors)
        lines.append(("info", "check the host and key, and that SSH is enabled under "
                              "IP -> Services"))
        lines.append(("info", "../git/git_ssh_doctor.py --host %s --test-auth will say "
                              "which key works" % host))
        return 2, {
            "host": host,
            "reachable": False,
            "probe_ok": False,
            "errors": errors,
        }, lines

    if rc != 0 or not out.strip():
        lines.append(("fail", "reached %s but the read-only probe failed (exit %d)"
                              % (host, rc)))
        lines.extend(("raw", "        %s" % line) for line in errors)
        lines.append(("info", "the user needs read access to /system script, /system "
                              "scheduler and /system script environment"))
        return 1, {
            "host": host,
            "reachable": True,
            "probe_ok": False,
            "probe_exit": rc,
            "errors": errors,
        }, lines

    installed, schedulers, env = parse_report(out)
    if package is None:
        # Preflight, even though it runs after the ssh probe: the comparison
        # below is only meaningful against the whole package, and half of it
        # read is worse than none - every script that could not be read is
        # reported as one the router has and the package does not.
        try:
            package = scan_package(args.scripts_dir)
        except OSError as exc:
            lines.append(("fail", "cannot read the scripts under %s: %s"
                                  % (args.scripts_dir, exc)))
            lines.append(("info", "pass --scripts-dir to point at the mikrotik package"))
            return 2, {
                "host": host,
                "reachable": True,
                "probe_ok": True,
                "scripts_dir": args.scripts_dir,
                "errors": ["cannot read the scripts: %s" % exc],
            }, lines
    local, underscored = package

    findings = build_findings(local, installed, schedulers, env, underscored=underscored)
    verdicts = None
    if args.drift:
        try:
            paths = local_script_paths(args.scripts_dir) if local else {}
            sources = {}
            for name in installed:
                if name in paths:
                    with open(paths[name], "rb") as fh:
                        sources[name] = fh.read()

            def ask_router(command):
                got = probe(host, user, args.identity, port, args.timeout, command=command)
                return got[0], got[1]

            verdicts, extra = drift_findings(
                drift_verdicts(sources, ask_router) if sources else {},
                paths, args.scripts_dir)
        except OSError as exc:
            verdicts, extra = {}, [("warn", "--drift could not read the package files: %s"
                                    % exc)]
        findings.extend(extra)
    rc = 0 if has_problems(findings) else 4

    # Scheduler on-event bodies are free-form RouterOS source and may embed
    # credentials. They are inspected in memory to match script names, but
    # never returned in the report.
    public_schedulers = [
        {"name": item.get("name", ""), "interval": item.get("interval", "")}
        for item in schedulers
    ]
    payload = {
        "host": host,
        "user": user,
        "port": port,
        "reachable": True,
        "probe_ok": True,
        "installed_scripts": installed,
        "schedulers": public_schedulers,
        "local_scripts": local,
        "controls": {
            "ops_toolbox_paused": env.get(PAUSE_STATE_KEY),
        },
        "routeros_version": env.get(VERSION_TEXT_KEY),
        "scheduler_state": [
            {
                "name": item.get("name", ""),
                "disabled": item.get("disabled"),
                "run_count": item.get("run_count"),
                "start_time": item.get("start_time"),
            }
            for item in schedulers
            if "disabled" in item
        ],
        "uptime_seconds": env.get(UPTIME_KEY),
        "incompatible_scripts": incompatible_scripts(installed, env, underscored),
        "findings": [
            {"level": level, "message": message}
            for level, message in findings
        ],
        "healthy": not has_problems(findings),
    }
    if verdicts is not None:
        # Verdicts only (same, changed, unknown): the router never sends a
        # source back, and neither does this report.
        payload["drift"] = verdicts

    lines.append(("head", "router"))
    lines.append(("info", "%s@%s:%d answered" % (user, host, port)))
    lines.append(("info", "/system script holds %d entries; /system scheduler holds %d"
                          % (len(installed), len(schedulers))))
    if env.get(VERSION_TEXT_KEY):
        lines.append(("info", "RouterOS %s" % env[VERSION_TEXT_KEY]))
    if not local:
        lines.append(("warn", "no .lua files under %s — only what the router has can "
                              "be checked" % args.scripts_dir))

    lines.append(("head", "findings"))
    lines.extend(findings)

    if rc == 4:
        lines.append(("ok", "nothing to fix: everything installed is scheduled and has "
                            "the globals it needs"))
        return rc, payload, lines

    lines.append(("head", "fix"))
    lines.append(("info", "scheduler lines for every script here: ./print_schedulers.sh"))
    lines.append(("info", "to install a missing script, paste the .lua body into System > "
                          "Scripts with policy read,write,policy,test,sensitive,ftp"))
    lines.append(("info", "to set the globals again at every boot: ./print_startup.sh "
                          "prints the startup script and its start-time=startup "
                          "scheduler"))
    if payload["incompatible_scripts"]:
        lines.append(("info", "on 7.24, remove or replace what cannot run (Scripts "
                              "overview in README.md lists what runs); rollback is "
                              "pasting the previous source"))
    for name, verdict in sorted((verdicts or {}).items()):
        if verdict == "changed":
            lines.append(("info", "paste the file body into System > Scripts > %s > Source"
                                  % name))
    return rc, payload, lines


# --------------------------------------------------------------------------
# a fleet: one router per line of a hosts file
# --------------------------------------------------------------------------
_HOST_WORD = re.compile(
    r"^(?:(?P<user>[^@\s]+)@)?"
    r"(?:\[(?P<v6>[0-9A-Fa-f:.%]+)\]|(?P<host>[A-Za-z0-9._-]+))"
    r"(?::(?P<port>\d{1,5}))?$"
)
_USER = re.compile(r"^[A-Za-z0-9._+][A-Za-z0-9._+-]*$")

# Worst first. The fleet exits with the first of these that any router got,
# and 4 only when every router did.
FLEET_RC_ORDER = (2, 1, 0)


def parse_hosts_file(text, default_user="admin", default_port=22):
    """[(user, host, port)] from a hosts file, in file order, duplicates dropped.

    One router per line: `host`, `user@host`, `host:port`, `user@host:port`,
    `[v6addr]` or `[v6addr]:port`. Blank lines and everything after '#' are
    ignored. Raises ValueError(line number, message) on the first line that is
    none of those. A word that starts with '-' is refused outright: each one
    becomes an ssh argument, and ssh would read it as an option.
    """
    routers = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        words = line.split()
        if len(words) != 1:
            raise ValueError(number, "expected one router per line, got %d words" % len(words))
        word = words[0]
        if word.startswith("-"):
            raise ValueError(number, "a router may not start with '-'")
        match = _HOST_WORD.match(word)
        if match is None:
            if word.count(":") > 1 and "[" not in word:
                raise ValueError(number, "write an IPv6 address in brackets, [addr]:port")
            raise ValueError(number, "not a host, user@host or host:port")
        user = match.group("user") or default_user
        host = match.group("v6") or match.group("host")
        if not _USER.match(user):
            raise ValueError(number, "not a RouterOS user name")
        if host.startswith("-"):
            raise ValueError(number, "a host may not start with '-'")
        port = default_port
        if match.group("port"):
            port = int(match.group("port"), 10)
            if not 1 <= port <= 65535:
                raise ValueError(number, "the port must be from 1 to 65535")
        entry = (user, host, port)
        if entry not in routers:
            routers.append(entry)
    return routers


def fleet_status(payload):
    if payload.get("reachable") is False:
        return "unreachable"
    if payload.get("probe_ok") is False:
        return "probe-failed"
    return "reachable"


def fleet_row_summary(payload):
    """(fails, warns, the first thing worth reading, at most 70 characters)."""
    findings = payload.get("findings", [])
    fails = sum(1 for f in findings if f["level"] == "fail")
    warns = sum(1 for f in findings if f["level"] == "warn")
    first = next((f["message"] for f in findings if f["level"] in ("fail", "warn")), "")
    if not first and payload.get("errors"):
        first = payload["errors"][0]
    if len(first) > 70:
        first = first[:67] + "..."
    return fails, warns, first


def fleet_rc(codes):
    for code in FLEET_RC_ORDER:
        if code in codes:
            return code
    return 4


def run_fleet(routers, args):
    """Audit every router in turn and total the fleet. Returns the exit code."""
    # Scanned once, before any router is contacted: the package does not
    # change between routers, and a fleet whose comparison is half-read would
    # report the same wrong answer once per router.
    try:
        package = scan_package(args.scripts_dir)
    except OSError as exc:
        if args.format == "json":
            print(json.dumps({
                "fleet": True,
                "scripts_dir": args.scripts_dir,
                "errors": ["cannot read the scripts: %s" % exc],
            }, sort_keys=True))
            return 2
        bad("cannot read the scripts under %s: %s" % (args.scripts_dir, exc))
        info("pass --scripts-dir to point at the mikrotik package")
        return 2

    hosts = [host for _, host, _ in routers]
    results = []
    for user, host, port in routers:
        label = host if hosts.count(host) == 1 else "%s@%s:%d" % (user, host, port)
        rc, payload, lines = run_one(user, host, port, args, package)
        results.append((label, rc, payload))
        if args.format == "text":
            head(label)
            emit(lines)

    codes = [rc for _, rc, _ in results]
    summary = {
        "total": len(results),
        "unreachable": sum(1 for _, _, p in results if fleet_status(p) == "unreachable"),
        "probe_failed": sum(1 for _, _, p in results if fleet_status(p) == "probe-failed"),
        "with_findings": codes.count(0),
        "healthy": codes.count(4),
    }
    if args.format == "json":
        print(json.dumps({
            "fleet": True,
            "hosts": [payload for _, _, payload in results],
            "summary": summary,
        }, sort_keys=True))
        return fleet_rc(codes)

    head("fleet")
    width = max(len(label) for label, _, _ in results)
    for label, _, payload in results:
        fails, warns, first = fleet_row_summary(payload)
        print(("%-*s  %-12s  fail=%d warn=%d  %s"
               % (width, label, fleet_status(payload), fails, warns, first)).rstrip())
    info("%d router(s): %d healthy, %d with findings, %d unreachable, %d probe failed"
         % (summary["total"], summary["healthy"], summary["with_findings"],
            summary["unreachable"], summary["probe_failed"]))
    return fleet_rc(codes)


def main(argv=None):
    parser = Usage3Parser(
        description="Read-only check of which RouterOS scripts are installed, "
                    "scheduled, and configured.",
        epilog="Exit codes: 0 findings printed, 1 connected but the probe failed, "
               "2 could not connect, 3 usage, 4 nothing wrong. With --hosts-file the "
               "fleet exits with its worst router: 2 if any was unreachable, else 1 "
               "if any probe failed, else 0 if any printed findings, else 4.",
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--host", help="router hostname or address")
    target.add_argument(
        "--hosts-file",
        metavar="FILE",
        help="audit every router listed in FILE, one per line: host, user@host, "
             "host:port or [v6addr]:port; '#' starts a comment",
    )
    parser.add_argument("--user", default="admin", help="RouterOS user (default: admin)")
    parser.add_argument("--identity", help="ssh private key to use")
    parser.add_argument("--port", type=int, default=22, help="ssh port (default: 22)")
    parser.add_argument("--timeout", type=int, default=30,
                        help="seconds per router (default: 30)")
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="output format (default: text)",
    )
    parser.add_argument(
        "--drift",
        action="store_true",
        help="also compare each installed package script with the file here; the "
             "router does the comparison and answers same or changed, so no "
             "source is fetched",
    )
    parser.add_argument("--scripts-dir", default=PACKAGE_DIR, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if args.hosts_file is not None:
        # Everything about the file is settled before the first ssh call: a
        # typo on line 40 must not cost 39 probes first.
        try:
            with open(os.path.expanduser(args.hosts_file), encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeError) as exc:
            parser.error("cannot read --hosts-file %s: %s" % (args.hosts_file, exc))
        try:
            routers = parse_hosts_file(text, args.user, args.port)
        except ValueError as exc:
            number, message = exc.args
            parser.error("%s line %d: %s" % (args.hosts_file, number, message))
        if not routers:
            parser.error("%s lists no routers" % args.hosts_file)
        return run_fleet(routers, args)

    rc, payload, lines = run_one(args.user, args.host, args.port, args)
    if args.format == "json":
        print(json.dumps(payload, sort_keys=True))
    else:
        emit(lines)
    return rc


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Starting point for a new Python helper in this repository.

Copy it, rename it, and delete what you do not need. As it stands it is a
working no-op that reports whether one command is installed and which version
it claims to be, which is enough to exercise every convention below:

  * Standard library only, and 3.9-clean - `/usr/bin/python3` on macOS is 3.9
    and that is what CI pins. No third-party imports, ever: these helpers are
    called by shell scripts on machines with no virtualenv.
  * Read-only. A helper here explains and prints the command that fixes the
    problem; it does not edit config, touch an agent, or write a file. That is
    why there is no --dry-run in this file - there is nothing to preview.
  * Pure logic takes its input as arguments. Everything under "findings" below
    is given the PATH string, the command output and the version rather than
    reading them itself, so the tests are fixture data and no test depends on
    the host it runs on or rots with the calendar.

The impure edge is deliberately small and sits in one place: `run()` and
`locate()`. Anything that shells out stays untested by design.

    ./new_helper.py                 # check the default target
    ./new_helper.py --target jq
    ./new_helper.py --path "$PATH"  # ask about a PATH other than this process's

Exit codes: 0 findings printed, 4 nothing to report. A usage error exits 2,
which is argparse's own convention rather than this repository's 3 - see the
unknown-flag section of test-env/static/check_conventions.sh, which exempts
Python helpers for exactly that reason.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

# The command the no-op reports on. Replace it, or delete the default and make
# --target required.
DEFAULT_TARGET = "git"

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
# findings - pure functions. Every one of these takes the ambient state it
# needs as a parameter, so a test calls them with a string and gets an answer.
# --------------------------------------------------------------------------
def path_entries(path_value):
    """The directories in a PATH string, in order, without duplicates.

    An empty element means the current directory to the shell, which is a
    misconfiguration worth reporting rather than silently resolving.
    """
    seen = []
    for entry in (path_value or "").split(os.pathsep):
        if entry not in seen:
            seen.append(entry)
    return seen


def parse_version(text):
    """The first dotted version in a --version banner, or None.

    Tools disagree about the shape of that banner ("git version 2.43.0",
    "jq-1.7.1", "Python 3.9.6"), so match the number rather than the layout.
    """
    match = re.search(r"(\d+\.\d+(?:\.\d+)*)", text or "")
    return match.group(1) if match else None


def build_findings(target, found, version):
    """Compare what should be true with what is.

    Pure: no subprocess, no filesystem, no clock. Returns a list of
    (level, message) with level in {'fail', 'warn', 'info'}; 'info' is context
    rather than a finding and does not count towards the exit code.
    """
    findings = []

    if not found:
        findings.append((
            "fail",
            "%s is not on PATH - install it, or pass --target with the name "
            "you actually use" % target,
        ))
        return findings

    if len(found) > 1:
        findings.append((
            "warn",
            "%s resolves to %d entries on PATH; the first one wins: %s"
            % (target, len(found), ", ".join(found)),
        ))

    if version is None:
        findings.append((
            "warn",
            "%s ran but printed no recognisable version" % found[0],
        ))
    else:
        findings.append(("info", "%s reports version %s" % (found[0], version)))

    return findings


def has_problems(findings):
    return any(level in ("fail", "warn") for level, _ in findings)


# --------------------------------------------------------------------------
# the parts that touch the machine
# --------------------------------------------------------------------------
def locate(name, entries):
    """Every distinct executable called `name` in `entries`, in PATH order.

    Deduplicated by real path: /bin is a symlink to /usr/bin on most Linux
    distributions now, so a PATH holding both is one installation reached two
    ways, not two installations shadowing each other.
    """
    hits = []
    seen = set()
    for entry in entries:
        candidate = os.path.join(entry or ".", name)
        if not (os.path.isfile(candidate) and os.access(candidate, os.X_OK)):
            continue
        real = os.path.realpath(candidate)
        if real in seen:
            continue
        seen.add(real)
        hits.append(candidate)
    return hits


def run(cmd, timeout=15):
    """Run a command, returning (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 255, "", str(exc)
    return (
        p.returncode,
        p.stdout.decode("utf-8", "replace"),
        p.stderr.decode("utf-8", "replace"),
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read-only report on whether a command is installed and "
                    "which version it claims to be.",
        epilog="Exit codes: 0 findings printed, 4 nothing to report.",
    )
    parser.add_argument(
        "--target",
        default=DEFAULT_TARGET,
        help="command to look for (default: %s)" % DEFAULT_TARGET,
    )
    parser.add_argument(
        "--path",
        default=os.environ.get("PATH", ""),
        help="PATH to search (default: this process's PATH)",
    )
    args = parser.parse_args(argv)

    entries = path_entries(args.path)
    found = locate(args.target, entries)

    version = None
    if found:
        rc, out, err = run([found[0], "--version"])
        if rc == 0:
            version = parse_version(out or err)

    head(args.target)
    info("%d directory(ies) on the PATH searched" % len(entries))

    head("findings")
    findings = build_findings(args.target, found, version)
    for level, message in findings:
        PRINTER[level](message)

    if not has_problems(findings):
        ok("nothing to fix")
        return 4

    head("fix")
    info("print the command that repairs this, do not run it - these helpers "
         "are read-only")
    return 0


if __name__ == "__main__":
    sys.exit(main())

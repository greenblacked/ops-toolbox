#!/usr/bin/env python3
"""Export a RouterOS configuration and keep it under version control.

firewall_drift.lua compares the live firewall against a baseline that is
maintained by hand, which means drift is only ever detected against whatever
someone last remembered to write down. This exports the real configuration on
demand and commits it, so the baseline has actual history behind it and any
change — intended or not — shows up as a diff.

Transport is ssh, not the RouterOS API, so this needs nothing installed: no
routeros-api, no pip, no venv. The tests in tests/ use the API because they
drive the router; this only reads.

The normalisation step is the point. `/export` writes a header naming the export
time and the router's uptime-dependent state, so two exports of an unchanged
router differ. Left alone, every commit is noise and a real change is invisible
among it.

    ./export_config.py --host 192.168.88.1
    ./export_config.py --host router.lan --user admin --identity ~/.ssh/keys/mikrotik
    ./export_config.py --host router.lan --commit
    ./export_config.py --host router.lan --stdout        # print, write nothing

Exit codes:

    0   success; under --diff, the live configuration matches the stored file
    1   an error, or — under --diff — the live configuration has drifted
    2   preflight failed (ssh missing, router unreachable)
    3   bad CLI arguments

--diff follows `git diff --exit-code`: 0 means no drift, so it can be used
directly in a scheduled check. The other modes exit 0 on success regardless of
whether anything changed.
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "config-history")

# The header RouterOS stamps on every export. Both the timestamp and the version
# line change independently of the configuration itself.
_HEADER_DATE = re.compile(
    r"^#\s*(?:\w{3}/\d{1,2}/\d{4}|\d{4}-\d{2}-\d{2})\s+\d{2}:\d{2}:\d{2}\b.*$"
)
_BY_ROUTEROS = re.compile(r"^#\s*(?:model|software id|serial number).*$", re.IGNORECASE)

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_DIM = "\033[0m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"


def ok(msg):
    print("%s[ ok ]%s %s" % (C_GREEN, C_RESET, msg))


def warn(msg):
    print("%s[warn]%s %s" % (C_YELLOW, C_RESET, msg))


def bad(msg):
    print("%s[fail]%s %s" % (C_RED, C_RESET, msg), file=sys.stderr)


def info(msg):
    print("%s[info]%s %s" % (C_DIM, C_RESET, msg))


def normalise(text):
    """Strip the parts of an export that change without the config changing.

    Kept deliberately narrow: only lines that are provably volatile are dropped.
    Removing anything else would hide a real change, which defeats the purpose.
    """
    out = []
    for line in text.splitlines():
        if _HEADER_DATE.match(line):
            continue
        if _BY_ROUTEROS.match(line):
            continue
        out.append(line.rstrip())
    # Collapse trailing blank lines so a stray newline is not a diff.
    while out and not out[-1]:
        out.pop()
    return "\n".join(out) + "\n"


def fetch_export(host, user, identity, port, timeout, sensitive):
    """Run /export over ssh. Returns (rc, text, stderr)."""
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
    # RouterOS 7 hides secrets unless asked; be explicit either way so the
    # behaviour does not depend on the firmware's default.
    cmd.append("/export show-sensitive" if sensitive else "/export")

    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 255, "", str(exc)
    return (
        p.returncode,
        p.stdout.decode("utf-8", "replace"),
        p.stderr.decode("utf-8", "replace"),
    )


def git(args, cwd):
    p = subprocess.run(["git"] + args, cwd=cwd, capture_output=True)
    return (
        p.returncode,
        p.stdout.decode("utf-8", "replace"),
        p.stderr.decode("utf-8", "replace"),
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Export a RouterOS config over ssh and version it."
    )
    parser.add_argument("--host", required=True, help="router hostname or address")
    parser.add_argument("--user", default="admin", help="RouterOS user (default: admin)")
    parser.add_argument("--identity", help="ssh private key to use")
    parser.add_argument("--port", type=int, default=22, help="ssh port (default: 22)")
    parser.add_argument("--timeout", type=int, default=60, help="seconds (default: 60)")
    parser.add_argument("--out", default=DEFAULT_OUT, help="output directory")
    parser.add_argument("--name", help="basename for the file (default: the host)")
    parser.add_argument(
        "--show-sensitive",
        action="store_true",
        help="include secrets. Do NOT combine with --commit unless the repo is private.",
    )
    parser.add_argument("--stdout", action="store_true", help="print, write nothing")
    parser.add_argument(
        "--diff",
        action="store_true",
        help="show the live export diff against the stored file; write nothing",
    )
    parser.add_argument("--commit", action="store_true", help="git commit if changed")
    parser.add_argument(
        "--no-normalise",
        action="store_true",
        help="keep the volatile export header (every run will then differ)",
    )
    args = parser.parse_args(argv)

    if sum((args.stdout, args.diff, args.commit)) > 1:
        bad("--stdout, --diff and --commit are mutually exclusive")
        return 2

    if args.show_sensitive and args.commit:
        bad("--show-sensitive with --commit would write router secrets into git history")
        info("drop one of the two; secrets do not belong in a repository")
        return 2

    rc, text, err = fetch_export(
        args.host, args.user, args.identity, args.port, args.timeout,
        args.show_sensitive,
    )
    if rc != 0 or not text.strip():
        bad("export failed (exit %d)" % rc)
        for line in err.strip().splitlines()[:5]:
            print("      %s" % line, file=sys.stderr)
        if "Permission denied" in err:
            info("if this is an ssh key problem, ../git/git_ssh_doctor.py --host %s "
                 "--test-auth will say which key works" % args.host)
        return 1

    content = text if args.no_normalise else normalise(text)

    if args.stdout:
        sys.stdout.write(content)
        return 0

    out_dir = os.path.abspath(os.path.expanduser(args.out))
    name = args.name or args.host.replace("/", "_")
    if not name.endswith(".rsc"):
        name += ".rsc"
    dest = os.path.join(out_dir, name)

    previous = None
    if os.path.exists(dest):
        try:
            with open(dest, encoding="utf-8") as fh:
                previous = fh.read()
        except OSError as exc:
            bad("could not read existing %s: %s" % (dest, exc))
            return 1

    if previous == content:
        ok("no change: %s" % dest)
        return 0

    if args.diff:
        before = previous.splitlines(keepends=True) if previous is not None else []
        after = content.splitlines(keepends=True)
        sys.stdout.writelines(difflib.unified_diff(
            before,
            after,
            fromfile=dest if previous is not None else "/dev/null",
            tofile="%s (live)" % dest,
        ))
        # Reaching here means the live configuration and the stored file differ;
        # the matching case returned 0 above. Returning 0 here too made --diff
        # unable to report the one thing it exists to find, so a scheduled
        # `export_config.py --diff || alert` could never fire. 1 is what
        # `git diff --exit-code` uses and what every check script in this
        # repository uses for "findings"; see the exit table in the docstring.
        return 1

    try:
        os.makedirs(out_dir, exist_ok=True)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(content)
    except OSError as exc:
        bad("could not write %s: %s" % (dest, exc))
        return 1

    if previous is None:
        ok("created %s (%d lines)" % (dest, content.count("\n")))
    else:
        added = content.count("\n") - previous.count("\n")
        ok("updated %s (%+d lines)" % (dest, added))

    if not args.commit:
        info("review with: git diff -- %s" % dest)
        return 0

    rc, _, _ = git(["rev-parse", "--git-dir"], cwd=HERE)
    if rc != 0:
        warn("not a git repository — wrote the file but did not commit")
        return 0

    rc, _, err = git(["add", dest], cwd=HERE)
    if rc != 0:
        bad("git add failed: %s" % err.strip())
        return 1
    rc, out, _ = git(["diff", "--cached", "--stat", "--", dest], cwd=HERE)
    if not out.strip():
        ok("nothing staged — file matched what is already committed")
        return 0
    message = "Update RouterOS export for %s" % args.host
    rc, _, err = git(["commit", "-m", message, "--", dest], cwd=HERE)
    if rc != 0:
        bad("git commit failed: %s" % err.strip())
        return 1
    ok("committed: %s" % message)
    return 0


if __name__ == "__main__":
    sys.exit(main())

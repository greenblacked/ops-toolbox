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
    ./export_config.py --host router.lan --scan-secrets  # report secrets, write nothing
    ./export_config.py --host router.lan --diff --summary  # changes per menu, no text
    ./export_config.py --scan-file config-history/router.lan.rsc
    ./export_config.py --host router.lan --commit --redact-secrets

Plain /export hides the router's own credentials, but not the source of a
/system script or the on-event of a scheduler, and the package's own install
steps put `:global TgBotToken "..."` in a startup script. So an export can
carry a live bot token into git history. --scan-secrets and --scan-file report
where (line number and kind, never the value); --redact-secrets replaces each
value with `<redacted>` before anything is printed, diffed or written; and
--commit refuses an export that still has one. The scan is a heuristic: it is
a guard against the known shapes, not proof that an export is clean.

Exit codes:

    0   success; under --diff, the live configuration matches the stored file;
        under --scan-secrets/--scan-file, no secret was found
    1   an error; under --diff, the live configuration has drifted; under
        --scan-secrets/--scan-file, a secret was found; --commit refused an
        export that holds one
    2   preflight failed (ssh missing, router unreachable)
    3   bad CLI arguments

--diff follows `git diff --exit-code`: 0 means no drift, so it can be used
directly in a scheduled check, and the scans follow it. The other modes exit 0
on success regardless of whether anything changed.
"""

from __future__ import annotations

import argparse
import collections
import difflib
import os
import re
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# The package root, not this file's folder. The history is an operator's, not
# the package's: it predates the core/features split, and keying the default
# off HERE would have moved it to mikrotik/features/config-history/ when this
# file moved - silently, writing into an empty directory and diffing --diff
# against nothing, with every previous export still sitting where it was.
PACKAGE_DIR = os.path.dirname(HERE)
DEFAULT_OUT = os.path.join(PACKAGE_DIR, "config-history")

# The header RouterOS stamps on every export. Both the timestamp and the version
# line change independently of the configuration itself.
_HEADER_DATE = re.compile(
    r"^#\s*(?:\w{3}/\d{1,2}/\d{4}|\d{4}-\d{2}-\d{2})\s+\d{2}:\d{2}:\d{2}\b.*$"
)
_BY_ROUTEROS = re.compile(r"^#\s*(?:model|software id|serial number).*$", re.IGNORECASE)

# What a secret looks like in an export. Each pattern marks the value it found
# as group "value" (or "quoted"), which is the only part redaction replaces.
# Matching runs on logical lines - an export wraps long lines with a trailing
# backslash, and a token can be split across the wrap. The flag says whether a
# match inside a commented-out script line counts: a token is a token wherever
# it sits, but the package's own comments show `:global RouterBackupPassword
# "s3cret"` as an example, and reporting that on every router would teach
# people to ignore the scan.
_SECRET_PATTERNS = (
    # A Telegram bot token by its shape, wherever it appears - including inside
    # a hand-built https://api.telegram.org/bot<token>/ URL.
    ("telegram bot token", False, re.compile(
        r"(?<![0-9])(?P<value>\d{6,12}:[A-Za-z0-9_-]{30,})(?![A-Za-z0-9_-])"
    )),
    # A secret-named :global, :local or :set given a literal in a script source
    # or an on-event. Inside an export the quotes arrive escaped as \".
    ("secret assigned in a script", True, re.compile(
        r'(?i):(?:global|local|set)\s+[A-Za-z0-9]*'
        r'(?:token|password|secret|apikey|passphrase|psk)[A-Za-z0-9]*\s+\\?"'
        r'(?P<value>[^"\\]+)\\?"'
    )),
    # Fields RouterOS only prints under show-sensitive.
    ("sensitive field", True, re.compile(
        r"\b(?:password|passphrase|private-key|secret|psk|wpa2-pre-shared-key"
        r"|wpa-pre-shared-key|authentication-key|encryption-key)"
        r'=(?:"(?P<quoted>[^"]+)"|(?P<value>[^\s\\"]+))'
    )),
)

REDACTED = "<redacted>"
# The values the package itself ships as placeholders; reporting them would
# teach people to ignore the scan.
_PLACEHOLDERS = ("token", "ID", REDACTED)

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


def warn_stderr(msg):
    # --stdout and --diff own stdout, so a warning about their content goes to
    # stderr, where it cannot end up inside a redirected export.
    print("%s[warn]%s %s" % (C_YELLOW, C_RESET, msg), file=sys.stderr)


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


def _logical_lines(text):
    """Yield (first line number, logical line, offsets) for an export.

    A physical line ending in an odd number of backslashes continues on the
    next one, whose leading whitespace is indentation, not content. offsets[i]
    is where character i of the logical line sits in text, so a match found on
    the joined line can be replaced in the original.
    """
    position = 0
    chars, offsets, first = [], [], None
    for number, raw in enumerate(text.split("\n"), 1):
        start = position
        position += len(raw) + 1
        body = raw[:-1] if raw.endswith("\r") else raw
        if first is None:
            first, column = number, 0
        else:
            column = len(body) - len(body.lstrip(" \t"))
        trailing = len(body) - len(body.rstrip("\\"))
        continued = trailing % 2 == 1
        end = len(body) - 1 if continued else len(body)
        for index in range(column, end):
            chars.append(body[index])
            offsets.append(start + index)
        if not continued:
            yield first, "".join(chars), offsets
            chars, offsets, first = [], [], None
    if first is not None:
        yield first, "".join(chars), offsets


def _in_script_comment(line, index):
    """Whether position index of a logical line sits in a commented-out line
    of script source.

    In an export a script's lines are joined by the two characters \\n, and
    the first one follows the opening `="` of source= or on-event= (quotes
    inside the value are escaped, so the last bare `="` is that opening). In
    any other text, the logical line is the script line.
    """
    start = line.rfind("\\n", 0, index)
    if start >= 0:
        segment = line[start + 2:index]
    else:
        segment = line[:index]
        opening = segment.rfind('="')
        if opening >= 0:
            segment = segment[opening + 2:]
            # A bare quote after the opening closed that value: this is a
            # plain field such as comment="#critical", not script source.
            if re.search(r'(?<!\\)"', segment):
                return False
    return segment.lstrip().startswith("#")


def _secret_spans(line):
    """(kind, start, end) of every secret value on one logical line."""
    for kind, skip_comments, pattern in _SECRET_PATTERNS:
        for match in pattern.finditer(line):
            group = "value"
            if "quoted" in pattern.groupindex and match.group("quoted") is not None:
                group = "quoted"
            value = match.group(group)
            if value is None or value in _PLACEHOLDERS:
                continue
            # <paste token here> is a placeholder; $Password is a variable.
            if value.startswith("<") and value.endswith(">"):
                continue
            if value.startswith(("$", "[", "(")):
                continue
            if skip_comments and _in_script_comment(line, match.start()):
                continue
            yield kind, match.start(group), match.end(group)


def find_secrets(text):
    """[(line number, kind)] for every secret in an export.

    Never returns the value: the findings are printed, logged and asserted on,
    and none of those should be able to leak what they found.
    """
    findings = []
    for number, line, _ in _logical_lines(text):
        for kind, _, _ in _secret_spans(line):
            if (number, kind) not in findings:
                findings.append((number, kind))
    return findings


def redact_secrets(text):
    """Replace every secret value with REDACTED, and nothing else.

    Deterministic, so a redacted history diffs cleanly from one export to the
    next, and idempotent, because REDACTED is skipped as a value. A value that
    crossed a line wrap loses the wrap with it.
    """
    spans = []
    for _, line, offsets in _logical_lines(text):
        for _, start, end in _secret_spans(line):
            spans.append((offsets[start], offsets[end - 1] + 1))
    if not spans:
        return text
    spans.sort()
    merged = [list(spans[0])]
    for start, end in spans[1:]:
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    out, cursor = [], 0
    for start, end in merged:
        out.append(text[cursor:start])
        out.append(REDACTED)
        cursor = end
    out.append(text[cursor:])
    return "".join(out)


# A verb that makes a /path line a command rather than a menu header: the
# terse export form, `/ip firewall filter add chain=input ...`.
_MENU_VERB = re.compile(r"\s(?:add|set|remove)(?:\s|$)")
TOP_MENU = "(top)"


def _menu_lines(text):
    """[(menu, logical line)] for every configuration line of an export.

    Continuations are joined first, so one rule is one line however /export
    wrapped it. Blank lines, comments and the menu headers themselves are not
    configuration and are left out; lines before the first header belong to
    TOP_MENU.
    """
    menu = TOP_MENU
    out = []
    for _, line, _ in _logical_lines(text):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("/"):
            verb = _MENU_VERB.search(line)
            if verb is None and "=" not in line:
                menu = line
                continue
            if verb is not None:
                out.append((line[:verb.start()].strip(), line))
                continue
        out.append((menu, line))
    return out


def summarise_diff(before_text, after_text):
    """[(menu, added, removed)] for every menu whose lines changed.

    Pure. A modified rule is one line removed and one added in the same menu,
    which is the honest signal: the export has no rule identity to say more.
    A menu whose lines only changed order is listed as +0 -0, because in a
    firewall the order is the configuration. Menus come in the order they
    first appear, in the new text and then the old, so the table reads like
    the export.
    """
    before_lines = _menu_lines(before_text)
    after_lines = _menu_lines(after_text)
    before = collections.Counter(before_lines)
    after = collections.Counter(after_lines)
    order = []
    for menu, _ in after_lines + before_lines:
        if menu not in order:
            order.append(menu)
    added = collections.Counter()
    removed = collections.Counter()
    for (menu, _), count in (after - before).items():
        added[menu] += count
    for (menu, _), count in (before - after).items():
        removed[menu] += count
    rows = []
    for menu in order:
        old_order = [line for m, line in before_lines if m == menu]
        new_order = [line for m, line in after_lines if m == menu]
        if added[menu] or removed[menu] or old_order != new_order:
            rows.append((menu, added[menu], removed[menu]))
    return rows


def render_summary(rows):
    """The --summary table: counts only, never a rule, comment or value."""
    if not rows:
        return "total: +0 -0 in 0 menu(s)\n"
    width = max(len(menu) for menu, _, _ in rows)
    lines = [
        ("%-*s  +%d -%d%s" % (width, menu, added, removed,
                              "" if added or removed else "  (order changed)"))
        for menu, added, removed in rows
    ]
    lines.append("total: +%d -%d in %d menu(s)" % (
        sum(r[1] for r in rows), sum(r[2] for r in rows), len(rows),
    ))
    return "\n".join(lines) + "\n"


def describe_lines(findings):
    numbers = sorted({number for number, _ in findings})
    shown = ", ".join(str(n) for n in numbers[:10])
    return shown + (", ..." if len(numbers) > 10 else "")


def report_secrets(findings):
    """Print a scan's findings. Returns the scan's exit code."""
    for number, kind in findings:
        warn("line %d: %s" % (number, kind))
    info("%d finding(s); values are never printed" % len(findings))
    return 1 if findings else 0


def read_stored_export(path):
    """Read an export from disk the way the stored file is read: no symlinks,
    no devices. Returns the text; raises OSError or UnicodeError."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
            raise OSError("not a regular file")
        return fh.read()


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


def write_private_export(dest, content):
    """Publish a complete 0600 file without truncating the previous generation."""
    fd, temporary = tempfile.mkstemp(prefix=".export-", dir=os.path.dirname(dest))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            os.fchmod(fh.fileno(), 0o600)
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        # Replacing a name never follows a symlink created after the read.
        os.replace(temporary, dest)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


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


def main(argv=None):
    parser = Usage3Parser(
        description="Export a RouterOS config over ssh and version it."
    )
    parser.add_argument(
        "--host", help="router hostname or address (required unless --scan-file)"
    )
    parser.add_argument("--user", default="admin", help="RouterOS user (default: admin)")
    parser.add_argument("--identity", help="ssh private key to use")
    parser.add_argument("--port", type=int, default=22, help="ssh port (default: 22)")
    parser.add_argument("--timeout", type=int, default=60, help="seconds (default: 60)")
    parser.add_argument("--out", default=DEFAULT_OUT, help="output directory")
    parser.add_argument("--name", help="basename for the file (default: the host)")
    parser.add_argument(
        "--show-sensitive",
        action="store_true",
        help="include secrets. Do NOT combine with --commit; secrets do not belong in git history.",
    )
    parser.add_argument("--stdout", action="store_true", help="print, write nothing")
    parser.add_argument(
        "--diff",
        action="store_true",
        help="show the live export diff against the stored file; write nothing",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="with --diff: print added and removed line counts per menu instead "
             "of the diff; no configuration text is printed",
    )
    parser.add_argument("--commit", action="store_true", help="git commit if changed")
    parser.add_argument(
        "--no-normalise",
        action="store_true",
        help="keep the volatile export header (every run will then differ)",
    )
    parser.add_argument(
        "--scan-secrets",
        action="store_true",
        help="report secrets in the live export by line and kind; write nothing. "
             "Exit 1 when one is found",
    )
    parser.add_argument(
        "--scan-file",
        metavar="PATH",
        help="scan a stored export instead of the router; needs no --host and no ssh",
    )
    parser.add_argument(
        "--redact-secrets",
        action="store_true",
        help="replace secret values with <redacted> before printing, diffing or writing",
    )
    args = parser.parse_args(argv)

    if not args.host and not args.scan_file:
        parser.error("the following arguments are required: --host")

    # 3, not 2. Both of these are bad CLI arguments, which the exit table in
    # this file's own docstring spends 3 on; 2 is preflight — ssh missing, the
    # router unreachable. They returned 2, so a caller that retried on "could
    # not reach it" retried a flag combination that will never work.
    if sum((args.stdout, args.diff, args.commit)) > 1:
        bad("--stdout, --diff and --commit are mutually exclusive")
        return 3

    if args.summary and not args.diff:
        bad("--summary needs --diff")
        return 3

    scanning = args.scan_secrets or args.scan_file is not None
    if scanning and (args.stdout or args.diff or args.commit or args.redact_secrets):
        bad("--scan-secrets and --scan-file cannot be combined with --stdout, "
            "--diff, --commit or --redact-secrets")
        return 3

    if args.scan_file is not None:
        # A stored export, or an older committed copy: no router, no ssh.
        try:
            stored = read_stored_export(os.path.expanduser(args.scan_file))
        except (OSError, UnicodeError) as exc:
            bad("could not read %s: %s" % (args.scan_file, exc))
            return 1
        return report_secrets(find_secrets(stored))

    if args.show_sensitive and args.commit:
        bad("--show-sensitive with --commit would write router secrets into git history")
        info("drop one of the two; secrets do not belong in a repository")
        return 3

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

    if args.scan_secrets:
        return report_secrets(find_secrets(content))

    if args.redact_secrets:
        content = redact_secrets(content)
    secrets = find_secrets(content)
    if secrets:
        warn_stderr("%d possible secret(s) in the export (lines %s); re-run with "
                    "--redact-secrets" % (len(secrets), describe_lines(secrets)))
        if args.commit:
            # Fail closed, like --show-sensitive: the way past this is the
            # option that removes the values, not one that skips the check.
            bad("refusing to commit an export that holds secrets")
            return 1

    if args.stdout:
        sys.stdout.write(content)
        return 0

    out_dir = os.path.abspath(os.path.expanduser(args.out))
    name = args.name or args.host.replace("/", "_")
    if not name.endswith(".rsc"):
        name += ".rsc"
    dest = os.path.join(out_dir, name)

    previous = None
    previous_mode = None
    try:
        # O_NOFOLLOW also rejects dangling symlinks; fstat rejects devices and
        # directories rather than reading them as an export.
        fd = os.open(dest, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            metadata = os.fstat(fh.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                raise OSError("existing destination is not a regular file")
            previous_mode = stat.S_IMODE(metadata.st_mode)
            previous = fh.read()
    except FileNotFoundError:
        pass
    except (OSError, UnicodeError) as exc:
        bad("could not read existing %s: %s" % (dest, exc))
        return 1

    if previous == content and (args.diff or previous_mode == 0o600):
        ok("no change: %s" % dest)
        return 0

    if args.diff and args.summary:
        # Counts per menu only. Safe to paste into a ticket or an alert, where
        # the unified diff would carry rule bodies, comments and addresses.
        sys.stdout.write(render_summary(summarise_diff(previous or "", content)))
        return 1

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
        write_private_export(dest, content)
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

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

It fails closed. A :global, :local or :set whose name or value the scan cannot
fully tokenize (an unbalanced quote, an escape it does not know, a name it
cannot extract) is reported as unverifiable, and so is a secret-named variable
given anything but nothing, a lone $variable, <redacted> or a shipped
placeholder. --commit refuses it with the line number and the reason, exit 1,
whatever else is given. There is no option to skip that check. The keywords
may lack their colon where they start a statement.

Exit codes:

    0   success; under --diff, the live configuration matches the stored file;
        under --scan-secrets/--scan-file, no secret was found
    1   an error; under --diff, the live configuration has drifted; under
        --scan-secrets/--scan-file, a secret was found or an assignment the
        scan cannot verify; --commit refused an export that holds either
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
# as group "value", "quoted" or "bare", which is the only part redaction
# replaces. Matching runs on logical lines - an export wraps long lines with a
# trailing backslash, and a token can be split across the wrap. The flag says
# whether a match inside a commented-out script line counts: a token is a
# token wherever it sits. A secret-named assignment in a commented-out line is
# not reported here as a leak; the second pass (find_unverifiable) reports it
# as a commented assignment with a literal, and --commit refuses it.
_LEAK_PATTERNS = (
    # A Telegram bot token by its shape, wherever it appears - including inside
    # a hand-built https://api.telegram.org/bot<token>/ URL.
    ("telegram bot token", False, re.compile(
        r"(?<![0-9])(?P<value>\d{6,12}:[A-Za-z0-9_-]{30,})(?![A-Za-z0-9_-])"
    )),
    # A secret-named :global, :local or :set given a literal in a script source
    # or an on-event. Inside an export the quotes arrive escaped as \".
    # A script's own backslash, quote or dollar is itself escaped by the export,
    # so a literal $ arrives as \\\$ (backslash pair, then \$): after a pair
    # the value may continue with another pair, an escaped quote, an escape
    # or a plain character. An unquoted literal (`:global ApiPassword abc`)
    # is one token that stops at whitespace, `;`, a quote, an escape or a
    # closing } ] ) (so `do={:set password abc}` keeps its brace); one that
    # starts with { is an array and one that starts with $, [ or ( is an
    # expression, and none of them is a literal. The variable name may itself
    # be quoted (`:global "api-token" "x"`, escaped inside an export), which is
    # how RouterOS spells a name with a hyphen. The pattern takes any name;
    # _is_secret_name decides whether it is a secret one, the same way for
    # this pass and for find_unverifiable. The keyword may lack its colon
    # (`global x "y"`) where it starts a statement (_statement_start).
    ("secret assigned in a script", True, re.compile(
        r'(?i)(?P<keyword>:(?:global|local|set)|'
        r'(?:(?<![A-Za-z0-9_.$:-])|(?<=\\[nr]))(?:global|local|set))'
        r'(?![A-Za-z0-9_-])\s+'
        r'(?:\\?")?(?P<name>[A-Za-z0-9_-]+)(?:\\?")?\s+'
        r'(?:\\?"'
        r'(?P<value>(?:\\\\(?:\\\\|\\"|\\[^"\\]|[^"\\])|\\[^"\\]|[^"\\])+)\\?"'
        r'|(?P<bare>(?!\{)[^\s;\\"}\])]+))'
    )),
    # Fields RouterOS only prints under show-sensitive. A quoted value runs to
    # the first unescaped quote: a backslash escapes the next character (\\,
    # \", \$, and the first digit of a \XX hex pair), so an escaped quote
    # does not end it. A quote that never closes runs to the end of the line
    # (an unterminated value is a leak, not something to pass over). An
    # unquoted `$"name"` is one expression token, not a value ending at `$`.
    # Inside a script field of an export the script's own quotes arrive
    # escaped: `password=\"x\"` is the `equoted` form, which runs to the
    # matching escaped quote (a script's own backslash pair, escaped quote
    # or escape inside it does not end it) or, unterminated, to the first
    # bare quote or the end of the line.
    ("sensitive field", True, re.compile(
        r"\b(?:password|passphrase|private-key|secret|psk|wpa2-pre-shared-key"
        r"|wpa-pre-shared-key|preshared-key|authentication-key|encryption-key)"
        r'=(?:"(?P<quoted>(?:[^"\\]|\\.)+)(?:"|\\?$)'
        r'|\\"(?P<equoted>(?:\\\\(?:\\\\|\\"|\\[^"\\]|[^"\\])|\\[^"\\]|[^"\\])+)'
        r'|(?P<value>\$"(?:[^"\\]|\\.)*"|[^\s\\"]+))'
    )),
)

REDACTED = "<redacted>"
# The assignments the package itself ships as placeholders, as exact
# (variable, value) pairs; reporting them would teach people to ignore the
# scan. Any other value is a finding, whatever it looks like: a secret does
# not become safe by being wrapped in <...>. REDACTED is the one value that
# is exempt anywhere, so redaction is idempotent.
_PLACEHOLDER_ASSIGNMENTS = frozenset((
    ("BotToken", "token"),                                  # core/tg_send.lua
    ("TgBotToken", "<paste bot token>"),                    # print_startup.sh
    ("RouterBackupPassword", "<paste backup password>"),    # print_startup.sh
))

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


# The RouterOS fields that hold script text, and the shape of an export line
# that carries one (`add ...`, `set ...` or a /menu path first). Only there are
# the escapes \n and \r line breaks; a plain script line that merely holds a
# string like "a=" is not an export, and reading it as one would let a later
# backslash-n and "#" hide a live assignment.
_SCRIPT_FIELDS = frozenset((
    "source", "script", "do",
    # scheduler, traffic-monitor, ppp profile, hotspot, vrrp, dhcp alert
    "on-event", "on-up", "on-down", "on-login", "on-logout",
    "on-master", "on-backup", "on-fault", "on-alert", "on-alarm",
    # netwatch, dhcp-server, dhcp-client
    "up-script", "down-script", "test-script", "lease-script",
))


def _is_script_field(name):
    """Whether a field name holds script text. RouterOS adds these over time,
    so beyond the known names any `*-script` or `on-*` field counts: reading
    a plain field as a script only makes the scan look harder."""
    name = name.lower()
    return name in _SCRIPT_FIELDS or name.endswith("-script") or \
        name.startswith("on-")


_EXPORT_SHAPED = re.compile(r"\s*(?:/|(?:add|set)(?:\s|$))")


def _export_field_start(line, index):
    """Index just past the opening `="` of the quoted export field that is
    still open at position index, or None when index is not inside one.

    In an export a field value is quoted and every quote inside it is escaped,
    so a bare quote closes the field. The last unclosed `name="` wins, and only
    when name is a field that holds a script and the line is shaped like an
    export; a `url="..."` that closed before index does not count, which keeps
    a plain script line from being read as an export. When unsure it says no.
    """
    if not _EXPORT_SHAPED.match(line):
        return None
    for match in reversed(list(re.finditer(r'[\w-]+="', line[:index]))):
        if not _is_script_field(match.group()[:-2]):
            continue
        position, closed = match.end(), False
        while position < index:
            if line[position] == "\\":
                position += 2
                continue
            if line[position] == '"':
                closed = True
                break
            position += 1
        if not closed:
            return match.end()
    return None


def _in_script_comment(line, index):
    """Whether position index of a logical line sits in a commented-out line
    of script source. When unsure it says no, so the line is scanned.

    In plain script text only a real line break ends a line; a backslash and
    n there are a string escape. In an export a script's lines are joined by
    the escapes \\n and \\r, read left to right so that \\\\n, a script's
    own backslash-n, is not a break. The first line follows the opening `="`
    of source= or on-event=.
    """
    start = _export_field_start(line, index)
    if start is None:
        segment = line[:index]
        cut = max(segment.rfind("\n"), segment.rfind("\r"))
        return segment[cut + 1:].lstrip().startswith("#")
    begin, position = start, start
    while position < index:
        if line[position] == "\\":
            if line[position + 1:position + 2] in ("n", "r"):
                begin = position + 2
            position += 2
        else:
            position += 1
    return line[begin:index].lstrip().startswith("#")


_FIELD_EXPRESSION = re.compile(r'\$(?:[A-Za-z_\[("]|\\")')

# What makes a variable name secret. Matched on the name with every _ and -
# removed and lower-cased, so api_key, api-key, API_KEY and ApiKey are one
# spelling; a name is not safe because of how it is separated.
_SECRET_WORDS = (
    "token", "password", "passwd", "secret", "apikey", "passphrase", "psk",
    "privatekey", "accesskey", "sharedkey", "wpakey", "wpa2key", "pincode",
    "credential", "bearer", "hmac",
)
# These are too short to match inside a word (mapping, spinner, bypass,
# compass, credit), so they count only as a word of their own: pin, Pin,
# SimPin, wifi_pin, WIFI-PIN, ApiPass, db_pwd, Cred.
_SECRET_NAME_WORDS = frozenset(("pin", "pass", "pwd", "cred"))
# Words that often name a secret but just as often name a lookup key or an
# auth mode (`:local key ("ipsec-" . $addr)`, `:local auth [...]`). They count
# only as a word of their own, and only a plain literal value is a finding:
# an expression or a variable is not.
_WEAK_NAME_WORDS = frozenset(("key", "auth"))
_NAME_WORDS = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")


def _name_strength(name, loose=False):
    """2 for a name that is secret, 1 for one that is secret only given a
    plain literal, 0 for one that is not."""
    squashed = re.sub(r"[^a-z0-9]" if loose else r"[_-]", "", name.lower())
    if any(word in squashed for word in _SECRET_WORDS):
        return 2
    words = {word.lower() for word in _NAME_WORDS.findall(name)}
    if words & _SECRET_NAME_WORDS:
        return 2
    if not loose and words & _WEAK_NAME_WORDS:
        return 1
    return 0


def _is_secret_name(name, loose=False):
    """Whether a variable name (or, loose, any text) names a secret."""
    return _name_strength(name, loose) > 0


def _statement_start(line, index):
    """Whether the keyword at line[index] starts a statement: at the start of
    the line, after `;` or `{` (so also after `do={`), at the opening quote of
    a script field, after a line-break escape inside one, or as the first word
    of a commented-out line."""
    before = line[:index].rstrip(" \t")
    if not before:
        return True
    last = before[-1]
    if last in ";{#":
        return True
    field = _export_field_start(line, index)
    if field is None:
        return False
    if not line[field:index].strip(" \t"):
        return True
    if last in "nr" and before[-2:-1] == "\\":
        run = len(before) - 1 - len(before[:-1].rstrip("\\"))
        return run % 2 == 1
    return False


def _leak_spans(line):
    """(kind, start, end) of every secret value on one logical line."""
    for kind, skip_comments, pattern in _LEAK_PATTERNS:
        named = "name" in pattern.groupindex
        position = 0
        while True:
            match = pattern.search(line, position)
            if match is None:
                break
            # A name-based pattern takes any name and filters afterwards, so
            # step one character: a match for a harmless assignment must not
            # swallow the secret one that starts inside it.
            position = match.start() + 1 if named else match.end()
            group = next((g for g in ("quoted", "equoted", "value", "bare")
                          if g in pattern.groupindex and match.group(g) is not None),
                         None)
            if group is None:
                continue
            value = match.group(group)
            if value == REDACTED:
                continue
            if named:
                if not _is_secret_name(match.group("name")):
                    continue
                if not match.group("keyword").startswith(":") and \
                        not _statement_start(line, match.start()):
                    continue
                if (match.group("name"), value) in _PLACEHOLDER_ASSIGNMENTS:
                    continue
            if kind == "sensitive field" and group == "equoted":
                # In a script, the export escapes `$` as `\$`: `\$name`,
                # `\$[...]`, `\$(...)` and `\$"name"` start an expression.
                if re.match(r'\\\$(?:[A-Za-z_\[("]|\\")', value):
                    continue
            elif kind == "sensitive field":
                # A field value is plain text: `\$` there is a literal dollar
                # in the secret, so only an unescaped `$name`, `$[...]`,
                # `$(...)` or `$"name"` is an expression, not a value.
                if _FIELD_EXPRESSION.match(value) or value.startswith(("[", "(")):
                    continue
            else:
                # An export escapes a script's `$` as `\$`; strip that one
                # backslash so a variable reference is not mistaken for a value.
                bare = value[1:] if value.startswith("\\") else value
                # Unquoted, a leading $, [ or ( is an expression; quoted,
                # only a leading $ is ("[x]" is a plain string).
                if bare.startswith(("$", "[", "(") if group == "bare" else "$"):
                    continue
            if skip_comments and _in_script_comment(line, match.start()):
                continue
            yield kind, match.start(group), match.end(group)


def find_leaks(text):
    """[(line number, kind)] for every secret in an export.

    Never returns the value: the findings are printed, logged and asserted on,
    and none of those should be able to leak what they found.
    """
    findings = []
    for number, line, _ in _logical_lines(text):
        for kind, _, _ in _leak_spans(line):
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
        for _, start, end in _leak_spans(line):
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


# The scan above is a set of patterns, and a pattern that does not match says
# nothing about the text it skipped. So a second pass reads every :global,
# :local and :set the way the router would, and anything it cannot tokenize
# with confidence is "unverifiable": a name it cannot extract, an unbalanced
# quote, an escape it does not know, a secret-named value that is not exactly
# a variable, a placeholder or <redacted> (no expression is trusted), a value
# the patterns above did not classify. --commit refuses an
# export with one; there is no option to skip the check.
_ASSIGN_KEYWORD = re.compile(
    r"(?i):(?:global|local|set)(?![A-Za-z0-9_-])"
    r"|(?:(?<![A-Za-z0-9_.$:-])|(?<=\\[nr]))(?:global|local|set)(?![A-Za-z0-9_-])"
)
_PLAIN_NAME = re.compile(r"[A-Za-z0-9_-]+")
_QUOTED_NAME = re.compile(r'[A-Za-z0-9_. -]+')
_VAR_REF = re.compile(r'\$(?:[A-Za-z_][A-Za-z0-9_]*|"[^"\\]*")')
_HEX_DIGITS = frozenset("0123456789abcdefABCDEF")
# RouterOS string escapes: \\ \" \$ \? \_ \a \b \f \n \r \t \v and \XX (hex).
_ESCAPES = {
    "\\": "\\", '"': '"', "$": "$", "?": "?", "_": " ", "a": "\a", "b": "\b",
    "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v",
}
_BOUNDARY = frozenset(" \t\r\n;})]")


def _escape_at(text, index):
    """(decoded character, length) of the escape at text[index], or
    (None, reason) when it is not one the parser can read with confidence."""
    nxt = text[index + 1:index + 2]
    after = text[index + 2:index + 3]
    if nxt != "" and after != "" and nxt in _HEX_DIGITS and after in _HEX_DIGITS:
        if nxt in _ESCAPES:
            # \ab is the escape \a then b, or the byte 0xAB: say neither.
            return None, "ambiguous escape"
        return chr(int(text[index + 1:index + 3], 16)), 3
    if nxt != "" and nxt in _ESCAPES:
        return _ESCAPES[nxt], 2
    return None, "unrecognized escape"


def _decode_export_layer(text):
    """Undo the export's own escaping of a script, from the start of text up
    to the quote that ends the field.

    Returns (characters, escaped flags, problem). problem is None, or the
    reason the text after the characters could not be read: an escape that is
    not one RouterOS defines, or a quote that does not end the field (one
    followed by more text, so it is a stray quote inside the script).
    """
    chars, escaped = [], []
    index = 0
    while index < len(text):
        ch = text[index]
        if ch == '"':
            after = text[index + 1:index + 2]
            if after != "" and not after.isspace():
                return chars, escaped, "unescaped quote inside a quoted field"
            return chars, escaped, None
        if ch != "\\":
            chars.append(ch)
            escaped.append(False)
            index += 1
            continue
        char, length = _escape_at(text, index)
        if char is None:
            return chars, escaped, length
        chars.append(char)
        escaped.append(True)
        index += length
    return chars, escaped, None


_NOT_A_VARIABLE = "secret-named value is not a variable, placeholder or <redacted>"


def _check_assignment(rest, export_layer):
    """(reason or None, whether a secret-named literal value was seen) for the
    assignment whose keyword was just before rest."""
    if export_layer:
        chars, escaped, problem = _decode_export_layer(rest)
    else:
        chars, escaped, problem = list(rest), [False] * len(rest), None
    s = "".join(chars)
    size = len(s)

    def skip(index):
        while index < size and s[index] in " \t":
            index += 1
        return index

    index = skip(0)
    if index >= size:
        return (problem or "no variable name after the keyword"), False
    if s[index] in "\r\n;":
        return "no variable name after the keyword", False
    if s[index] == '"':
        close = s.find('"', index + 1)
        if close < 0:
            return (problem or "unbalanced quote around the variable name"), False
        name = s[index + 1:close]
        if not _QUOTED_NAME.fullmatch(name):
            return "cannot extract the variable name", False
        index = close + 1
    else:
        match = _PLAIN_NAME.match(s, index)
        if not match:
            return "cannot extract the variable name", False
        name, index = match.group(), match.end()
    if index < size and s[index] not in _BOUNDARY:
        return "unexpected character after the variable name", False
    strength = _name_strength(name)
    if not strength:
        return None, False
    # A weak name (key, auth) is secret only given a plain literal, so an
    # expression or a variable is not reported for it.
    weak = strength == 1

    index = skip(index)
    if index >= size:
        return problem, False
    first = s[index]
    if first in "\r\n;})]":
        return None, False
    if first == '"':
        end = index + 1
        while True:
            if end >= size:
                return (problem or "unbalanced quote"), False
            ch = s[end]
            if ch == '"':
                break
            if ch in "\r\n":
                return "unbalanced quote", False
            if ch == "\\":
                char, length = _escape_at(s, end)
                if char is None:
                    return "%s in the value" % length, False
                end += length
            else:
                end += 1
        content = s[index + 1:end]
        after = end + 1
        if after < size and s[after] not in _BOUNDARY:
            return "text after the closing quote of the value", False
        if content == "" or content == REDACTED or \
                (name, content) in _PLACEHOLDER_ASSIGNMENTS:
            return None, False
        # Only a lone variable reference is acceptable; "[x]" and "(x)" are
        # plain strings in RouterOS, so they are literals, and anything else
        # that starts with $ is an expression the scan does not evaluate.
        if _VAR_REF.fullmatch(content):
            return None, False
        if content[0] == "$":
            return (None, False) if weak else (_NOT_A_VARIABLE, False)
        return None, True
    if not export_layer and s[index:index + 2] == "\\$":
        index += 1
        first = "$"
    if first in "{$[(":
        # Structural rule: a variable reference with nothing else is the only
        # expression a secret-named variable may be given. A bracket, a
        # paren, a brace, a number or an operator next to it is not.
        match = _VAR_REF.match(s, index)
        if first != "$" or not match or \
                (match.end() < size and s[match.end()] not in _BOUNDARY):
            return (None, False) if weak else (_NOT_A_VARIABLE, False)
        return None, False
    end = index
    while end < size and s[end] not in " \t\r\n;\"})]":
        end += 1
    if end < size and s[end] == '"':
        return "quote inside an unquoted value", False
    if end >= size and problem:
        return problem, False
    if any(escaped[index:end]) or "\\" in s[index:end]:
        return "escape inside an unquoted value", False
    token = s[index:end]
    if token == REDACTED or (name, token) in _PLACEHOLDER_ASSIGNMENTS:
        return None, False
    return None, True


# Reasons that come from reading the variable name, before the scan knows
# whether the variable is secret. In a comment they say nothing about a value.
_NAME_REASONS = frozenset((
    "no variable name after the keyword",
    "unbalanced quote around the variable name",
    "cannot extract the variable name",
    "unexpected character after the variable name",
))


_HEX_ESCAPE = re.compile(r"\\+([0-9A-Fa-f]{2})")


def _comment_text(rest, export_layer):
    """The raw text of a commented-out statement: rest up to the line-break
    escape that ends the comment, when it sits in an export field."""
    if export_layer:
        position = 0
        while position < len(rest):
            if rest[position] == "\\":
                if rest[position + 1:position + 2] in ("n", "r"):
                    return rest[:position]
                position += 2
            else:
                position += 1
    return rest


def _raw_names_a_secret(rest, export_layer):
    """Whether the raw text of a commented statement, hex escapes decoded and
    every separator ignored, names a secret. Used when the name could not be
    parsed: `# :set "Api\\54oken" "x"` is not worth parsing to know it is
    ApiToken."""
    text = _HEX_ESCAPE.sub(lambda m: chr(int(m.group(1), 16)),
                           _comment_text(rest, export_layer))
    return _is_secret_name(text, loose=True)


def _unverifiable_reasons(line):
    """Why a logical line holds an assignment the scan cannot verify."""
    reasons = []
    literals = 0
    for match in _ASSIGN_KEYWORD.finditer(line):
        colonless = not match.group().startswith(":")
        if colonless and not _statement_start(line, match.start()):
            continue
        commented = _in_script_comment(line, match.start())
        rest = line[match.end():]
        export_layer = _export_field_start(line, match.start()) is not None \
            or '\\"' in rest
        reason, literal = _check_assignment(rest, export_layer)
        if reason in _NAME_REASONS and colonless and not commented and \
                match.group().lower() == "set" and not line[:match.start()].strip():
            # A `set [ find ... ] name=x` or `set name=x` that opens an export
            # line is a menu command, not an assignment; the sensitive-field
            # pattern covers its password=, secret= and the like.
            continue
        if commented:
            # Fail closed: a real secret left in a commented-out line is still
            # in git history. A secret-named variable given a literal, or a
            # value the scan cannot read, counts; a name that is not secret,
            # a placeholder, <redacted> and a plain $variable stay quiet, as
            # does prose that only looks like a statement. A name that could
            # not be parsed counts when the raw text names a secret.
            if literal or (reason and reason not in _NAME_REASONS) or \
                    (reason in _NAME_REASONS and _raw_names_a_secret(rest, export_layer)):
                reason = "commented assignment with a literal"
                if reason not in reasons:
                    reasons.append(reason)
            continue
        if reason and reason not in reasons:
            reasons.append(reason)
        literals += bool(literal)
    reported = sum(1 for kind, _, _ in _leak_spans(line)
                   if kind == "secret assigned in a script")
    if literals > reported:
        reasons.append("value the secret scan did not classify")
    return reasons


def find_unverifiable(text):
    """[(line number, reason)] for every assignment the scan cannot verify.

    Fail closed: a :global, :local or :set whose name or value cannot be fully
    tokenized is not "probably fine". Like find_leaks, never returns a value.
    """
    findings = []
    for number, line, _ in _logical_lines(text):
        for reason in _unverifiable_reasons(line):
            if (number, reason) not in findings:
                findings.append((number, reason))
    return findings


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


def report_leaks(findings, unverifiable=()):
    """Print a scan's findings. Returns the scan's exit code."""
    for number, kind in findings:
        warn("line %d: %s" % (number, kind))
    for number, reason in unverifiable:
        warn("line %d: unverifiable: %s" % (number, reason))
    total = len(findings) + len(unverifiable)
    info("%d finding(s); values are never printed" % total)
    return 1 if total else 0


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
        return report_leaks(find_leaks(stored), find_unverifiable(stored))

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
        return report_leaks(find_leaks(content), find_unverifiable(content))

    if args.redact_secrets:
        content = redact_secrets(content)
    hits = find_leaks(content)
    unverifiable = find_unverifiable(content)
    if hits:
        # Only a count and line numbers reach the message, never a value.
        warn_stderr("%d possible secret(s) in the export (lines %s); re-run with "
                    "--redact-secrets" % (len(hits), describe_lines(hits)))
    if unverifiable:
        warn_stderr("%d assignment(s) the secret scan cannot verify (lines %s)"
                    % (len(unverifiable), describe_lines(unverifiable)))
    if args.commit:
        # Fail closed, like --show-sensitive: the way past a leak is the
        # option that removes the values, not one that skips the check. Past
        # something the scan cannot read there is no way at all: redaction
        # would be guessing too, so the script line has to be fixed or removed.
        if hits:
            bad("refusing to commit an export that holds secrets")
        for number, reason in unverifiable:
            bad("refusing to commit: line %d: %s; the secret scan cannot "
                "verify it" % (number, reason))
        if hits or unverifiable:
            if unverifiable:
                info("fix or remove that script line; --redact-secrets does not "
                     "override this")
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

    if args.diff and args.redact_secrets and previous is not None:
        # The stored export may predate redaction or hold a secret from an
        # unredacted run; diffing it raw would print the old value on a
        # removed line.
        previous = redact_secrets(previous)

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

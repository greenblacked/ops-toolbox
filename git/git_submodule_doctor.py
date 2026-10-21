#!/usr/bin/env python3
"""Diagnose submodules: mapping, initialisation, URLs and drift.

Submodule breakage is the commonest checkout failure in CI and the most
opaque one. Each of these has its own error, or none:

  mapping      a gitlink in the index with no .gitmodules entry stops
               `git submodule update` with "no submodule mapping found", and a
               .gitmodules entry with no gitlink is stale.
  state        a submodule never initialised, or checked out at a different
               commit than the superproject records - the everyday
               "modified: lib (new commits)" after a pull without
               --recurse-submodules - or a merge conflict in the pointer.
  URLs         a local path or file:// URL that only works on one machine,
               git:// (unauthenticated, read-only), http://, an ssh URL that
               needs a deploy key on every runner, a relative URL with no
               origin to resolve against.
  drift        .gitmodules changed but .git/config still dials the old URL,
               until `git submodule sync`.

Read-only. It runs git ls-files, git config reads and `git submodule status`
(no network, no recursion, no fetch), works from the repository root whatever
directory it is started in, and never runs `git submodule update`, `sync` or
`init`; it prints them. URLs are printed with any password blanked.

    ./git_submodule_doctor.py
    ./git_submodule_doctor.py --json     # the same verdict as one JSON object
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import shlex
import subprocess
import sys

HOME = os.path.expanduser("~")

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = C_BOLD = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"

# Every line the report prints is also recorded here, as (level, section,
# text), so --json can hand the same verdict to a script. Recording happens in
# the printers, after whatever redaction the caller applied, so the JSON never
# says more than the text did. Copied, not shared, like Usage3Parser below.
EVENTS = []
SECTION = ""
_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def record(level, text):
    EVENTS.append((level, SECTION, _ANSI.sub("", text)))


def ok(msg):
    print("%s[ ok ]%s %s" % (C_GREEN, C_RESET, msg))
    record("ok", msg)


def warn(msg):
    print("%s[warn]%s %s" % (C_YELLOW, C_RESET, msg))
    record("warn", msg)


def bad(msg):
    print("%s[fail]%s %s" % (C_RED, C_RESET, msg))
    record("fail", msg)


def info(msg):
    print("%s[info]%s %s" % (C_DIM, C_RESET, msg))
    record("info", msg)


def head(msg):
    global SECTION
    SECTION = msg
    print("\n%s== %s ==%s" % (C_BOLD, msg, C_RESET))


def raw(text, level="detail"):
    """Print a report line exactly as given, and record it without its indent
    or colour. For the table rows and lists the level helpers do not cover."""
    print(text)
    record(level, _ANSI.sub("", text).strip())


def render_json(tool, events, rc):
    """The report as one JSON object.

    schema 1 is a promise about shape: keys and levels may be added, none is
    ever renamed. `problems` counts the fail-level events.
    """
    return json.dumps({
        "tool": tool,
        "schema": 1,
        "exit_code": rc,
        "problems": sum(1 for event in events if event[0] == "fail"),
        "events": [
            {"level": level, "section": section, "message": message}
            for level, section, message in events
        ],
    }, sort_keys=True)


def shorten(path):
    return path.replace(HOME, "~", 1) if path.startswith(HOME) else path


# The repository root once it is known; every git call after that runs there,
# so .gitmodules and the index are read whole from a subdirectory too.
GIT_CWD = None


def run(cmd, timeout=15):
    """Run a command, returning (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, cwd=GIT_CWD)
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 255, "", str(exc)


# --------------------------------------------------------------------------
# Pure helpers. Everything below this line takes git's output as strings and
# returns data, so it can be unit-tested without a repository. The parts that
# shell out are left untested, because mocking them would only assert that
# the mock was called.
# --------------------------------------------------------------------------
def parse_config_z(text, field_names):
    """{name: {field: value}} from `git config -z --get-regexp` over submodule.*.

    Records are `key\\nvalue` and NUL-terminated. The name is everything between
    `submodule.` and the last dot, because a submodule name may hold dots
    itself (`libs.core`). Whatever follows the last NUL is a record cut short
    and is dropped.
    """
    records = (text or "").split("\0")
    records.pop()
    modules = {}
    for record in records:
        key, _, value = record.partition("\n")
        if not key.startswith("submodule.") or key.count(".") < 2:
            continue
        name, _, field = key[len("submodule."):].rpartition(".")
        field = field.lower()
        if field in field_names:
            modules.setdefault(name, {})[field] = value
    return modules


def parse_gitmodules(text):
    """{name: {'path', 'url', 'branch'}} from .gitmodules, '' where unset."""
    modules = parse_config_z(text, ("path", "url", "branch"))
    return {name: {"path": f.get("path", ""), "url": f.get("url", ""),
                   "branch": f.get("branch", "")} for name, f in modules.items()}


def parse_gitlink_entries(text):
    """{path: recorded sha} for the gitlinks (mode 160000) in `git ls-files -s -z`."""
    entries = {}
    for record in (text or "").split("\0"):
        meta, tab, path = record.partition("\t")
        fields = meta.split()
        if tab and len(fields) == 3 and fields[0] == "160000":
            entries.setdefault(path, fields[1])
    return entries


def parse_gitlinks(text):
    """Sorted paths of the gitlinks in `git ls-files -s -z` output."""
    return sorted(parse_gitlink_entries(text))


_STATES = {" ": "ok", "-": "uninitialized", "+": "changed", "U": "conflict"}
_DESCRIBE = re.compile(r" \([^()]*\)$")


def parse_submodule_status(text):
    """[(state, sha, path)] from `git submodule status`.

    The first column is the state: ' ' checked out at the recorded commit, '-'
    not initialised, '+' a different commit checked out, 'U' a merge conflict.
    The `(describe)` git appends is dropped; a path may hold spaces.
    """
    found = []
    for line in (text or "").splitlines():
        if len(line) < 2 or line[0] not in _STATES:
            continue
        sha, _, rest = line[1:].partition(" ")
        path = _DESCRIBE.sub("", rest)
        if sha and path:
            found.append((_STATES[line[0]], sha, path))
    return found


def classify_submodule_url(url):
    """relative, ssh, scp, https, http, git, file, local or unknown."""
    raw = (url or "").strip()
    if not raw:
        return "unknown"
    if raw.startswith(("./", "../")):
        return "relative"
    if "://" in raw:
        scheme = raw.split("://", 1)[0].lower()
        return {"ssh": "ssh", "git+ssh": "ssh", "https": "https", "http": "http",
                "git": "git", "file": "file"}.get(scheme, "unknown")
    if raw.startswith(("/", "~")) or re.match(r"^[A-Za-z]:[\\/]", raw):
        return "local"
    if ":" in raw:
        return "scp"
    return "unknown"


_USERINFO_PASSWORD = re.compile(r"(\w+://[^/\s:@]+):[^@/\s]+@")
_LONG_USERINFO = re.compile(r"(\w+://)[^/\s:@]{20,}@")


def redact(url):
    """A URL without the password in its userinfo, or a bare token there."""
    return _LONG_USERINFO.sub(r"\1***@", _USERINFO_PASSWORD.sub(r"\1:***@", url or ""))


_URL_FINDINGS = {
    "git": ("fail", "git:// is unauthenticated and read-only",
            "change it to https:// or ssh in .gitmodules, then git submodule sync"),
    "http": ("warn", "http:// sends any credential in the clear",
             "change it to https:// in .gitmodules, then git submodule sync"),
    "file": ("fail", "the URL is a path on one machine; other clones and CI cannot "
                     "reach it", "use the repository's network URL in .gitmodules"),
    "local": ("fail", "the URL is a path on one machine; other clones and CI cannot "
                      "reach it", "use the repository's network URL in .gitmodules"),
    "ssh": ("info", "an ssh URL needs a key on every machine that clones it; a CI "
                    "runner needs a deploy key, or url.<https base>.insteadOf", None),
    "scp": ("info", "an ssh URL needs a key on every machine that clones it; a CI "
                    "runner needs a deploy key, or url.<https base>.insteadOf", None),
}


def submodule_findings(modules, gitlinks, statuses, local_urls, has_origin, recorded=None):
    """[(level, message, fix)] for a superproject's submodules.

    modules is parse_gitmodules() output, gitlinks the gitlink paths in the
    index, statuses parse_submodule_status() output, local_urls {name: url}
    from .git/config, recorded {path: sha} from the index.
    """
    recorded = recorded or {}
    findings = []
    mapped = {m["path"]: name for name, m in modules.items() if m["path"]}

    for path in gitlinks:
        if path not in mapped:
            findings.append((
                "fail",
                "path %s is a submodule in the index but has no .gitmodules entry: git "
                "submodule update stops with no submodule mapping found" % path,
                "add the entry, or git rm --cached -- %s if it was committed by "
                "accident" % shlex.quote(path),
            ))
    for name in sorted(modules):
        path = modules[name]["path"]
        if path and path not in gitlinks:
            findings.append((
                "warn", "stale .gitmodules entry for %s (no submodule at %s)"
                        % (name, path),
                "git config -f .gitmodules --remove-section %s"
                % shlex.quote("submodule." + name),
            ))

    for state, sha, path in statuses:
        if state == "uninitialized":
            findings.append(("warn", "%s is not initialised" % path,
                             "git submodule update --init --recursive"))
        elif state == "changed":
            findings.append((
                "warn",
                "%s is at %s but the superproject records %s (typical after a pull "
                "without --recurse-submodules)"
                % (path, sha[:12], recorded.get(path, "another commit")[:12]),
                "git submodule update   # to match the record, or git add %s to "
                "record the new commit" % shlex.quote(path),
            ))
        elif state == "conflict":
            findings.append(("fail", "merge conflict in the submodule pointer %s" % path,
                             "check out the commit you want in %s, then git add %s"
                             % (shlex.quote(path), shlex.quote(path))))

    for name in sorted(modules):
        url = modules[name]["url"]
        kind = classify_submodule_url(url)
        if kind == "relative":
            if not has_origin:
                findings.append((
                    "warn",
                    "%s: relative URL %s resolves against this repository's own "
                    "directory, because there is no origin remote; that works on this "
                    "machine only" % (name, url),
                    "add the origin remote, or use an absolute URL",
                ))
        elif kind == "unknown":
            findings.append((
                "fail",
                "%s: %s" % (name, "no URL in .gitmodules (No url found for submodule "
                                  "path)" if not url else "cannot tell what transport "
                                  "%r names" % redact(url)),
                "set submodule.%s.url in .gitmodules" % name,
            ))
        elif kind in _URL_FINDINGS:
            level, message, fix = _URL_FINDINGS[kind]
            findings.append((level, "%s: %s" % (name, message), fix))

        configured = local_urls.get(name)
        if (configured and url and configured != url
                and classify_submodule_url(configured) != "relative"
                and kind != "relative"):
            findings.append((
                "warn",
                "%s: .git/config still dials %s, .gitmodules says %s"
                % (name, redact(configured), redact(url)),
                "git submodule sync --recursive",
            ))
    return findings


# --------------------------------------------------------------------------
# git
# --------------------------------------------------------------------------
def could_not_answer(what, rc, err):
    bad("%s could not answer (exit %d)" % (what, rc))
    for line in err.strip().splitlines()[:3]:
        info("        %s" % line)


def run_report(args):
    global GIT_CWD
    rc, out, _ = run(["git", "rev-parse", "--show-toplevel"])
    if rc != 0 or not out.strip():
        bad("not inside a Git repository")
        return 2
    GIT_CWD = out.strip()
    problems = 0

    has_gitmodules = os.path.isfile(os.path.join(GIT_CWD, ".gitmodules"))
    modules = {}
    if has_gitmodules:
        rc, out, err = run(["git", "config", "-f", ".gitmodules", "-z", "--get-regexp",
                            r"^submodule\..*\.(path|url|branch)$"])
        if rc in (0, 1):
            modules = parse_gitmodules(out)
        else:
            could_not_answer("git config -f .gitmodules", rc, err)
            problems += 1

    rc, out, err = run(["git", "ls-files", "-s", "-z"], timeout=120)
    if rc != 0:
        could_not_answer("git ls-files", rc, err)
        return 1
    recorded = parse_gitlink_entries(out)
    gitlinks = sorted(recorded)

    if not gitlinks and not modules and not has_gitmodules:
        head("submodules")
        info("no submodules and no .gitmodules here")
        return 4

    statuses = []
    mapped = {m["path"] for m in modules.values()}
    if gitlinks and all(path in mapped for path in gitlinks):
        rc, out, err = run(["git", "submodule", "status"], timeout=60)
        if rc == 0:
            statuses = parse_submodule_status(out)
        else:
            could_not_answer("git submodule status", rc, err)
            problems += 1
    elif gitlinks:
        info("git submodule status cannot run until every submodule path has a "
             ".gitmodules entry; the state of each is not shown")

    rc, out, _ = run(["git", "config", "--local", "-z", "--get-regexp",
                      r"^submodule\..*\.url$"])
    local_urls = {name: f["url"] for name, f in parse_config_z(
        out if rc == 0 else "", ("url",)).items()}
    rc, out, _ = run(["git", "remote"])
    has_origin = rc == 0 and "origin" in out.split()

    head("submodules")
    state_of = {path: state for state, _, path in statuses}
    for name in sorted(modules):
        module = modules[name]
        raw("        %-24s %-14s %s" % (module["path"] or "(no path)",
                                       state_of.get(module["path"], "-"),
                                       redact(module["url"]) or "(no url)"))
    for path in gitlinks:
        if path not in mapped:
            raw("        %-24s %-14s %s" % (path, "unmapped", "(no .gitmodules entry)"))

    head("findings")
    findings = submodule_findings(modules, gitlinks, statuses, local_urls, has_origin,
                                  recorded)
    for level, message, fix in findings:
        if level == "fail":
            bad(message)
            problems += 1
        elif level == "warn":
            warn(message)
        else:
            info(message)
        if fix:
            info("fix: %s" % fix)
    if not findings:
        ok("no submodule problems found")

    print()
    if problems:
        bad("%d problem(s) found" % problems)
        return 1
    ok("submodules are mapped, initialised and reachable by URL")
    return 0


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
        description="Diagnose submodule mapping, initialisation, URLs and drift.",
        epilog="Exit codes: 0 no fail-level finding, 1 a fail-level finding or a git "
               "command that could not answer, 2 not inside a Git repository, 3 usage, "
               "4 no submodules here.",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--quiet", action="store_true",
                        help="print nothing; communicate the verdict through the exit code")
    output.add_argument("--json", action="store_true",
                        help="print one JSON object (exit code and every finding) "
                             "instead of the report")
    args = parser.parse_args(argv)

    if args.quiet:
        with contextlib.redirect_stdout(io.StringIO()):
            return run_report(args)
    if args.json:
        with contextlib.redirect_stdout(io.StringIO()):
            rc = run_report(args)
        print(render_json(os.path.basename(__file__), EVENTS, rc))
        return rc
    return run_report(args)


if __name__ == "__main__":
    sys.exit(main())

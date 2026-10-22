#!/usr/bin/env python3
"""Audit what a repository has already committed that it should not have.

git_hooks_install.sh --token-scan guards the next commit, and
git_ignore_doctor.py finds tracked files an ignore rule claims. Neither answers
the question an inherited repository raises: is anything in here that should
never have been committed, and was something committed once and then deleted?

  names     tracked files whose names are credential-shaped: .env, id_ed25519,
            *.pem, terraform.tfstate, .git-credentials, kubeconfig, .npmrc ...
            A name ending in .example, .sample or .template is a placeholder
            and passes.
  content   tracked files at HEAD whose content matches a high-confidence
            key or token format. `git grep -l` returns file names only, so a
            matched secret is never read into this report, a log, or JSON.
  history   with --history, the same name rules over every path ever added on
            any ref. A file deleted from the tree is still in every clone, so
            "gone from HEAD but still in history" is the case where the
            credential has to be rotated.

Read-only. It opens no file in the working tree: names come from HEAD
(`git ls-tree`) and the index (`git ls-files`), content from `git grep`
against HEAD, history from `git log`.
It never edits .gitignore, the index or history, and its advice stops at
"rotate the credential".

    ./git_secrets_doctor.py                      # names and content at HEAD
    ./git_secrets_doctor.py --history            # also every path ever added
    ./git_secrets_doctor.py --allow 'tests/fixtures/*'
    ./git_secrets_doctor.py --json               # the same verdict as one JSON object
"""

from __future__ import annotations

import argparse
import contextlib
import fnmatch
import io
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = C_BOLD = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"

# How many findings a section names before it prints a count instead. A
# repository that committed a directory of fixtures can have hundreds.
SCAN_LIMIT = 20
DEFAULT_HISTORY_LIMIT = 20000

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


def bulk_timeout(count):
    """Seconds to allow a git call that walks `count` files or commits."""
    return max(15, min(600, 15 + count // 500))


# The repository root once it is known; every git call after that runs there,
# so `git ls-files` and `git grep` see the whole tree from a subdirectory too.
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
# Pure helpers. Everything below this line takes its input as strings, so it
# can be unit-tested without a repository. The parts that shell out to git
# are left untested, because mocking them would only assert that the mock was
# called.
# --------------------------------------------------------------------------
# Names that hold a credential by convention, as (rule id, level, pattern,
# advice). Each pattern is tried against the file name and against the whole
# repository-relative path, case-insensitively, so `.ENV` and
# `deploy/.kube/config` are both caught. fail is a file whose whole purpose is
# a secret; warn is one that often, but not always, carries one.
PATH_RULES = (
    ("private-key-file", "fail",
     r"^(id_(rsa|dsa|ecdsa|ed25519)(_sk)?|.*\.(pem|key|p12|pfx|jks|keystore))$",
     "a private key or keystore; a .pem may be only a certificate, check it"),
    ("tfstate", "fail", r"\.tfstate(\.backup)?$",
     "Terraform state holds every secret the configuration ever read"),
    ("git-credentials", "fail", r"^\.git-credentials$",
     "git's plaintext credential store"),
    ("netrc", "fail", r"^\.netrc$|^_netrc$", "plaintext machine passwords"),
    ("env-file", "fail", r"^\.env(\.[a-z0-9_-]+)?$",
     "a dotenv file; commit a .env.example with placeholders instead"),
    ("aws-credentials", "fail", r"(^|/)\.aws/credentials$", "AWS access keys"),
    ("docker-auth", "fail", r"(^|/)\.docker/config\.json$", "registry auth tokens"),
    ("kubeconfig", "fail", r"(^|/)(kubeconfig|\.kube/config)$|\.kubeconfig$",
     "cluster credentials"),
    ("htpasswd", "fail", r"^\.htpasswd$", "password hashes"),
    ("npmrc", "warn", r"^\.npmrc$", "may hold a registry auth token"),
    ("pypirc", "warn", r"^\.pypirc$", "may hold an upload token"),
    ("tfvars", "warn", r"^terraform\.tfvars(\.json)?$|\.auto\.tfvars(\.json)?$",
     "variable values, often including secrets"),
    ("credentials-json", "warn", r"^credentials\.json$",
     "often an OAuth client secret"),
    ("service-account", "warn", r"^service-account.*\.json$",
     "often a cloud service-account key"),
    ("secrets-yaml", "warn", r"^secrets?\.ya?ml$",
     "named for secrets; plaintext unless encrypted"),
)
_PATH_RULES = tuple((rid, level, re.compile(rx, re.IGNORECASE), advice)
                    for rid, level, rx, advice in PATH_RULES)

# A name ending in one of these is a template for the real file, so
# .env.example is what a repository should commit, not a finding.
PLACEHOLDER_SUFFIXES = (".example", ".sample", ".template", ".dist", ".tpl", ".tmpl")

# Token formats specific enough that a match is a finding, as (rule id, level,
# ERE for git grep). The literals are assembled from pieces so this file does
# not match its own rules when a repository holding it is scanned. An AWS key
# id is an identifier, not the secret, so it only warns: the secret access
# key is usually on the next line.
CONTENT_RULES = (
    ("private-key-block", "fail",
     "-----BEGIN " + "(RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?" + "PRIVATE KEY"),
    ("aws-access-key-id", "warn", "AKIA" + "[0-9A-Z]{16}"),
    ("github-token", "fail",
     "gh" + "[pousr]_[A-Za-z0-9]{36,}|github" + "_pat_[A-Za-z0-9_]{20,}"),
    ("gitlab-token", "fail", "glpat" + "-[A-Za-z0-9_-]{20,}"),
    ("slack-token", "fail", "xox" + "[baprs]-[A-Za-z0-9-]{10,}"),
    ("stripe-live", "fail", "sk_" + "live_[0-9A-Za-z]{24,}"),
)


def is_placeholder(path):
    return os.path.basename(path).lower().endswith(PLACEHOLDER_SUFFIXES)


def match_path(path):
    """[(rule_id, level, advice)] for one repository-relative path."""
    if is_placeholder(path):
        return []
    name = os.path.basename(path)
    found = []
    for rule_id, level, pattern, advice in _PATH_RULES:
        if rule_id == "private-key-file" and name.lower().endswith(".pub"):
            continue
        if pattern.search(name) or pattern.search(path):
            found.append((rule_id, level, advice))
    return found


def is_allowed(path, globs):
    """Whether an --allow glob covers this path. `*` crosses directories."""
    return any(fnmatch.fnmatchcase(path, glob) for glob in globs)


def parse_grep_files(output):
    """Sorted unique paths from `git grep -l -z ... HEAD --` output.

    Each record is `HEAD:path` and NUL-terminated, so a name holding a space
    or a newline survives. A final record with no terminator is a truncated
    pipe and is dropped rather than guessed at.
    """
    records = (output or "").split("\0")
    records.pop()
    paths = set()
    for record in records:
        if record.startswith("HEAD:"):
            record = record[len("HEAD:"):]
        if record:
            paths.add(record)
    return sorted(paths)


def parse_added_paths(log_text):
    """{path: short sha} from `git log --diff-filter=A --name-only --format=@@%h`.

    git log lists the newest commit first and the first sighting is kept, so
    a path added, deleted and added again is attributed to its newest
    addition. A name git had to quote (it holds a control character or a
    quote) starts with a double quote and is skipped: unquoting it is
    guesswork, and guessing wrong would name a file that does not exist.
    """
    added = {}
    sha = None
    for line in (log_text or "").splitlines():
        if line.startswith("@@"):
            sha = line[2:].strip() or None
            continue
        if not line.strip() or line.startswith('"') or sha is None:
            continue
        added.setdefault(line, sha)
    return added


# --------------------------------------------------------------------------
# git
# --------------------------------------------------------------------------
def could_not_answer(what, rc, err):
    bad("%s could not answer (exit %d)" % (what, rc))
    for line in err.strip().splitlines()[:3]:
        info("        %s" % line)


def print_capped(findings):
    """Print (level, text) findings, naming at most SCAN_LIMIT of them."""
    for level, text in findings[:SCAN_LIMIT]:
        if level == "fail":
            bad(text)
        else:
            warn(text)
    if len(findings) > SCAN_LIMIT:
        info("... and %d more" % (len(findings) - SCAN_LIMIT))
    return sum(1 for level, _ in findings if level == "fail")


def committed_and_staged_paths():
    """(rc, err, paths): every path at HEAD plus every path in the index.

    HEAD is read as well as the index because `git rm --cached` removes a
    file from the index while it is still committed, and the credential is
    still in HEAD until that removal is committed. An unborn HEAD (no
    commits yet) has nothing to list, so only the index is read there.
    """
    paths = set()
    if run(["git", "rev-parse", "--verify", "-q", "HEAD"])[0] == 0:
        rc, out, err = run(["git", "ls-tree", "-r", "-z", "--name-only", "HEAD"],
                           timeout=120)
        if rc != 0:
            return rc, "git ls-tree: " + err, []
        paths.update(p for p in out.split("\0") if p)
    rc, out, err = run(["git", "ls-files", "-z"], timeout=120)
    if rc != 0:
        return rc, "git ls-files: " + err, []
    paths.update(p for p in out.split("\0") if p)
    return 0, "", sorted(paths)


def report_names(allow):
    head("tracked files")
    rc, err, paths = committed_and_staged_paths()
    if rc != 0:
        could_not_answer("git ls-tree / git ls-files", rc, err)
        return 1
    findings = []
    for path in paths:
        if is_allowed(path, allow):
            continue
        for rule_id, level, advice in match_path(path):
            findings.append((level, "%s  [%s] %s" % (path, rule_id, advice)))
    if not findings:
        ok("no tracked or committed file has a credential-shaped name (%d checked)" % len(paths))
        return 0
    problems = print_capped(findings)
    info("fix: git rm --cached -- <path>, then add the path to .gitignore "
         "(git_ignore_doctor.py <path> checks the rule works)")
    return problems


def report_content(allow, tracked_count):
    head("key material in tracked content")
    findings = []
    problems = 0
    for rule_id, level, pattern in CONTENT_RULES:
        # -l: git prints the file name and never the matching line, so the
        # secret itself cannot reach this report.
        rc, out, err = run(["git", "grep", "-l", "-I", "-z", "-E", "-e", pattern,
                            "HEAD", "--"], timeout=bulk_timeout(tracked_count))
        if rc == 1:
            continue
        if rc != 0:
            # An empty answer from a git that failed reads exactly like "no
            # match", so it is a problem rather than a clean result.
            could_not_answer("git grep for %s" % rule_id, rc, err)
            problems += 1
            continue
        for path in parse_grep_files(out):
            if not is_allowed(path, allow):
                findings.append((level, "%s  [%s]" % (path, rule_id)))
    if not findings:
        if not problems:
            ok("no file at HEAD holds a private key block or a known token format")
        return problems
    problems += print_capped(sorted(findings, key=lambda f: f[1]))
    info("reported by path and rule only; the matched text is never printed")
    return problems


def report_history(allow, limit):
    head("history")
    rc, out, err = run(["git", "-c", "core.quotePath=false", "log", "--all",
                        "--diff-filter=A", "--name-only", "--format=@@%h",
                        "-n", str(limit)], timeout=bulk_timeout(limit * 10))
    if rc != 0:
        could_not_answer("git log", rc, err)
        return 1
    added = parse_added_paths(out)
    commits = sum(1 for line in out.splitlines() if line.startswith("@@"))

    rc, tree, err = run(["git", "ls-tree", "-r", "-z", "--name-only", "HEAD"], timeout=120)
    if rc != 0:
        could_not_answer("git ls-tree", rc, err)
        return 1
    in_head = {p for p in tree.split("\0") if p}

    findings = []
    still_tracked = 0
    for path in sorted(added):
        if is_allowed(path, allow):
            continue
        rules = match_path(path)
        if not rules:
            continue
        if path in in_head:
            still_tracked += 1
            continue
        level = "fail" if any(r[1] == "fail" for r in rules) else "warn"
        findings.append((level, "%s [%s] was added in %s and is no longer in the "
                                "tree, but is still in history"
                         % (path, ", ".join(r[0] for r in rules), added[path])))
    if commits >= limit:
        info("stopped after --history-limit %d commits; older history was not read"
             % limit)
    if still_tracked:
        info("%d credential-shaped path(s) in history are still tracked; see "
             "tracked files above" % still_tracked)
    if not findings:
        ok("no credential-shaped path was added and later removed (%d commit(s) read)"
           % commits)
        return 0
    return print_capped(findings)


def run_report(args):
    global GIT_CWD
    rc, out, _ = run(["git", "rev-parse", "--is-bare-repository"])
    if rc == 0 and out.strip() == "true":
        info("n/a: this is a bare repository; there is no work tree for this "
             "doctor to check; --history is not scanned in a bare "
             "repository either (its history exists, but run it from a clone)")
        return 4
    rc, out, _ = run(["git", "rev-parse", "--show-toplevel"])
    if rc != 0 or not out.strip():
        bad("not inside a Git repository")
        return 2
    GIT_CWD = out.strip()

    problems = report_names(args.allow)

    has_head = run(["git", "rev-parse", "--verify", "-q", "HEAD"])[0] == 0
    if not has_head:
        head("key material in tracked content")
        info("no commits yet, so nothing is committed to search")
    elif not args.no_content:
        rc, out, _ = run(["git", "ls-files", "-z"], timeout=120)
        count = len([p for p in out.split("\0") if p]) if rc == 0 else 0
        problems += report_content(args.allow, count)

    if args.history and has_head:
        problems += report_history(args.allow, args.history_limit)

    print()
    if problems:
        info("rotate the credential first; removing the file from the tree does not "
             "remove it from history, and rewriting history is a separate, deliberate "
             "decision this tool never makes")
        bad("%d problem(s) found" % problems)
        return 1
    ok("nothing committed here looks like a credential")
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


def positive_int(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("%r is not a whole number" % value) from None
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive number, not %d" % number)
    return number


def main(argv=None):
    parser = Usage3Parser(
        description="Audit tracked files and history for committed credentials.",
        epilog="Exit codes: 0 nothing at fail level, 1 a fail-level finding or a git "
               "command that could not answer, 2 not inside a Git repository, 3 usage, "
               "4 n/a: a bare repository has no work tree.",
    )
    parser.add_argument("--history", action="store_true",
                        help="also check every path ever added, on any ref")
    parser.add_argument("--history-limit", type=positive_int,
                        default=DEFAULT_HISTORY_LIMIT, metavar="N",
                        help="commits --history reads (default: %d)" % DEFAULT_HISTORY_LIMIT)
    parser.add_argument("--no-content", action="store_true",
                        help="skip the git grep passes over tracked content")
    parser.add_argument("--allow", action="append", default=[], metavar="GLOB",
                        help="repository-relative glob to leave out, e.g. a documented "
                             "fixture (repeatable; * crosses directories)")
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

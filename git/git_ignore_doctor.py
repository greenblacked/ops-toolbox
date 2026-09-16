#!/usr/bin/env python3
"""Diagnose why a path is ignored, or why it stubbornly is not.

Four things go wrong with `.gitignore`, and none of them announces itself:

* **The file is already tracked.** Ignore rules apply to untracked paths only,
  so a `.env` committed once keeps showing up in every diff no matter what the
  rule says. `git check-ignore` agrees with the user's despair here — it skips
  tracked files by default and reports no match at all.
* **A negation under an excluded directory is dead.** Git does not descend into
  an excluded directory, so `!build/keep/note.txt` beneath `build/` can never
  re-include anything. The rule is not an error, it is simply never reached.
* **The rule lives somewhere nobody looked.** A repository has as many ignore
  files as it has directories, plus `.git/info/exclude` and whatever
  `core.excludesFile` points at — and the last one is silent when it points at
  a path that does not exist.
* **The pattern is not the pattern that was typed.** A slash in the middle
  anchors it to its own directory, a trailing space is dropped, a trailing
  slash restricts it to directories.

`git check-ignore -v` answers the first question only — which rule matched —
and it answers it with a `source:line:pattern` triple that says nothing about
why the rule you wrote is not in it. This script asks git that question twice,
once with the index and once without, and explains the difference.

Read-only. It prints the commands that fix what it finds; it never edits an
ignore file, the index, or config.

    ./git_ignore_doctor.py                  # tracked files that a rule claims
    ./git_ignore_doctor.py .env build/keep/note.txt
    ./git_ignore_doctor.py --quiet .env     # verdict via exit code only
"""

from __future__ import annotations

import argparse
import collections
import contextlib
import io
import os
import subprocess
import sys

HOME = os.path.expanduser("~")

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = C_BOLD = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"

# How many tracked-but-matched paths the no-argument scan names before it stops
# listing and prints a count instead. A repository that committed node_modules
# has tens of thousands, and a doctor that prints all of them is not a report.
SCAN_LIMIT = 20


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


def shorten(path):
    return path.replace(HOME, "~", 1) if path.startswith(HOME) else path


def rel(root, path):
    """A path as check-ignore would cite it: relative to the repository root.

    Anything outside the repository — a global excludes file — keeps its own
    shape with the home directory folded back to `~`.
    """
    inside = os.path.relpath(path, root)
    return path if inside.startswith("..") else inside


def bulk_timeout(count):
    """Seconds to allow a git call that is handed `count` paths.

    The fixed 15s default is right for one question about one path and wrong
    for the no-argument scan, which pipes every tracked file through a single
    `check-ignore`. A monorepo blows through it, and before this was a timeout
    that says so it was a timeout that came back empty and got reported as a
    clean bill of health.
    """
    return max(15, min(600, 15 + count // 500))


def run(cmd, stdin=None, timeout=15):
    """Run a command, returning (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(
            cmd,
            input=stdin,
            capture_output=True,
            timeout=timeout,
        )
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 255, "", str(exc)


# --------------------------------------------------------------------------
# parsing — the pure half, and the only half with unit tests
# --------------------------------------------------------------------------
IgnoreMatch = collections.namedtuple("IgnoreMatch", "source lineno pattern path")

PatternShape = collections.namedtuple(
    "PatternShape", "body negated dir_only anchored trailing_space"
)

IgnoreRule = collections.namedtuple("IgnoreRule", "lineno text shape")

# One rule plus where it was read from: `source` is the ignore file for citing
# it, `base` the repository-relative directory that file sits in. The base is
# what makes an anchored pattern comparable to a path — `!keep/note.txt` in
# `build/.gitignore` anchors to `build/keep/note.txt`, and treating it as
# repository-relative would point the reader at a directory that does not exist.
SourcedRule = collections.namedtuple("SourcedRule", "source base rule")


def parse_check_ignore(data):
    """Parse `git check-ignore -z -v --non-matching --stdin` output.

    Each record is four NUL-terminated fields — source, line number, pattern,
    pathname — and a path that matched nothing arrives with the first three
    empty. A trailing partial record (a killed git, a truncated pipe) is
    dropped rather than guessed at.
    """
    fields = data.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    records = []
    for i in range(0, len(fields) - 3, 4):
        source, lineno, pattern, path = fields[i : i + 4]
        records.append(IgnoreMatch(source, lineno, pattern, path))
    return records


def matched(record):
    """Whether a check-ignore record names a rule, rather than reporting none."""
    return record is not None and record.source != ""


def ignores(record):
    """Whether the rule a record names actually ignores the path.

    A negation is a match like any other — `check-ignore -v` reports
    `!build/keep/note.txt` as the pattern that decided the question, and the
    answer it decided was no. Reading a match as an exclusion is how a rule
    that works gets reported as a rule that does not.
    """
    return matched(record) and not classify_pattern(record.pattern).negated


def strip_trailing_space(line):
    """Split a gitignore line into (pattern, dropped trailing spaces).

    Git ignores trailing spaces unless they are escaped with a backslash, so
    `logs ` and `logs` are one rule and `logs\\ ` is another. Reporting the
    dropped run is the point: a pattern that looks right in an editor and does
    not match is usually this.
    """
    i = len(line)
    while i > 0 and line[i - 1] == " ":
        backslashes = 0
        j = i - 2
        while j >= 0 and line[j] == "\\":
            backslashes += 1
            j -= 1
        if backslashes % 2 == 1:
            break
        i -= 1
    return line[:i], line[i:]


def classify_pattern(pattern):
    """Describe what git will do with one gitignore pattern.

    `anchored` is the property people are surprised by: a slash anywhere but
    the end ties the pattern to the directory of the file it is written in,
    so `src/build` in a root `.gitignore` never matches `lib/src/build`.
    """
    body, trailing_space = strip_trailing_space(pattern)
    negated = False
    if body.startswith("!"):
        negated = True
        body = body[1:]
    elif body.startswith("\\!") or body.startswith("\\#"):
        body = body[1:]
    dir_only = len(body) > 1 and body.endswith("/")
    core = body[:-1] if dir_only else body
    anchored = "/" in core
    return PatternShape(body, negated, dir_only, anchored, trailing_space)


def parse_ignore_file(text):
    """Return the effective rules of an ignore file, as [IgnoreRule].

    Blank lines and comments are dropped, with their line numbers preserved on
    what remains so a rule can be cited the way check-ignore cites one. A `#`
    only starts a comment in the first column, and `\\#` escapes it there.
    """
    rules = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw[:-1] if raw.endswith("\r") else raw
        if line.startswith("#") or not line.strip():
            continue
        rules.append(IgnoreRule(lineno, line, classify_pattern(line)))
    return rules


def ancestors(path):
    """Every directory above a repo-relative path, deepest last.

    `a/b/c.txt` -> ['a', 'a/b']. Used to find the excluded directory that a
    negation cannot reach out of.
    """
    parts = path.strip("/").split("/")
    return ["/".join(parts[: i + 1]) for i in range(len(parts) - 1)]


def reinclusion_recipe(excluded_dir, path):
    """The ignore lines that actually re-include `path` under `excluded_dir`.

    Excluding the directory's contents instead of the directory is not enough
    on its own. Git still skips each directory on the way down, so every
    intermediate one needs its own trailing-slash negation before the file's
    negation is ever reached — `build/*` plus `!build/keep/note.txt` leaves the
    file just as ignored as `build/` did. Both arguments are relative to the
    ignore file the lines are going into, since that is what anchors them.
    """
    lines = [excluded_dir.rstrip("/") + "/*"]
    prefix = excluded_dir.rstrip("/") + "/"
    for parent in ancestors(path):
        if parent.startswith(prefix):
            lines.append("!" + parent + "/")
    lines.append("!" + path)
    return lines


def dead_negations(sourced_rules, directory):
    """Negation rules anchored inside `directory`, which git can never reach.

    Takes and returns SourcedRule entries, so a finding can be cited the way
    check-ignore cites a match. Only anchored patterns are
    reported: an unanchored `!note.txt` matches at every depth and deciding
    whether it was meant for this directory would be guesswork, while an
    anchored `!build/keep/note.txt` under an excluded `build/` states its own
    intent.
    """
    prefix = directory.strip("/") + "/"
    found = []
    for entry in sourced_rules:
        shape = entry.rule.shape
        if not shape.negated or not shape.anchored:
            continue
        target = shape.body.lstrip("/")
        if entry.base:
            target = entry.base.strip("/") + "/" + target
        if target.startswith(prefix):
            found.append(entry)
    return found


# --------------------------------------------------------------------------
# git
# --------------------------------------------------------------------------
def repo_root():
    rc, out, _ = run(["git", "rev-parse", "--show-toplevel"])
    return out.strip() if rc == 0 else None


def check_ignore(paths, no_index=False):
    """Ask git about each path, returning {path: IgnoreMatch}.

    Paths go in over stdin and come back NUL-separated, so a filename with a
    newline or a quote in it survives the round trip. `--no-index` is what
    separates "no rule matches" from "a rule matches but the file is tracked":
    without it git declines to answer for anything in the index.
    """
    if not paths:
        return {}
    cmd = ["git", "check-ignore", "--stdin", "-z", "-v", "--non-matching"]
    if no_index:
        cmd.append("--no-index")
    stdin = ("\0".join(paths) + "\0").encode("utf-8")
    # check-ignore exits 1 when nothing matched, which is an answer, not a
    # failure. Anything else is git declining to answer, and returning an empty
    # result for it would be indistinguishable from "no rule matches" — a
    # diagnostic confidently reporting the opposite of what it found out.
    rc, out, err = run(cmd, stdin=stdin, timeout=bulk_timeout(len(paths)))
    if rc not in (0, 1):
        bad("git check-ignore could not answer (exit %d)" % rc)
        for line in err.strip().splitlines()[:3]:
            info("        %s" % line)
        return None
    return {r.path: r for r in parse_check_ignore(out)}


def is_ignored(path):
    """Whether git considers one path ignored, index rules and all."""
    rc, _, _ = run(["git", "check-ignore", "-q", "--", path])
    return rc == 0


def tracked_files():
    """Every tracked path, or None if git could not be asked.

    None and [] are different answers — an empty repository has nothing to
    report, a failed `ls-files` has nothing to say — and the caller tells the
    reader which one it got.
    """
    rc, out, err = run(["git", "ls-files", "-z"], timeout=120)
    if rc != 0:
        bad("git ls-files could not list the tracked files (exit %d)" % rc)
        for line in err.strip().splitlines()[:3]:
            info("        %s" % line)
        return None
    return [p for p in out.split("\0") if p]


def config_origin(key):
    """(value, origin file) for a git config key, or (None, None) if unset."""
    rc, out, _ = run(["git", "config", "--show-origin", "--get", key])
    if rc != 0 or not out.strip():
        return None, None
    line = out.splitlines()[0]
    origin, _, value = line.partition("\t")
    return value, origin[len("file:") :] if origin.startswith("file:") else origin


# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------
def active_ignore_files(root, paths):
    """Ignore files git will consult, outermost first.

    The per-directory ones are only those on the way down to a path under
    question; listing every `.gitignore` in a large checkout would bury the two
    that matter.
    """
    found = [os.path.join(root, ".git", "info", "exclude")]
    directories = {""}
    for path in paths:
        for parent in ancestors(path) + [""]:
            directories.add(parent)
    for directory in sorted(directories):
        candidate = os.path.join(root, directory, ".gitignore")
        if os.path.isfile(candidate):
            found.append(candidate)
    return found


def report_sources(root, paths):
    """Name every ignore file in effect, and fail on one that cannot be read."""
    head("ignore sources")
    problems = 0

    value, origin = config_origin("core.excludesFile")
    if value:
        resolved = os.path.expanduser(value)
        if not os.path.isabs(resolved):
            resolved = os.path.join(root, resolved)
        if os.path.isfile(resolved):
            ok("core.excludesFile %s" % shorten(rel(root, resolved)))
        else:
            bad("core.excludesFile points at %s, which does not exist"
                % shorten(rel(root, resolved)))
            info("git reads no global ignore file at all and says nothing about it")
            problems += 1
        info("set in %s" % shorten(origin or "an unnamed source"))
    else:
        default = os.path.join(
            os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config")),
            "git",
            "ignore",
        )
        if os.path.isfile(default):
            ok("core.excludesFile unset; git falls back to %s" % shorten(default))
        else:
            info("no global ignore file (core.excludesFile unset, no %s)"
                 % shorten(default))

    for path in active_ignore_files(root, paths):
        if os.path.isfile(path):
            ok(rel(root, path))
        elif path.endswith(os.path.join(".git", "info", "exclude")):
            info("no %s — nothing repository-local and uncommitted" % rel(root, path))
    return problems


def read_rules(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return parse_ignore_file(handle.read())
    except OSError:
        return []


def describe_rule(record):
    return "%s:%s: %s" % (shorten(record.source), record.lineno, record.pattern)


def report_pattern_shape(record):
    """Say what the matched pattern actually means, where that is surprising."""
    shape = classify_pattern(record.pattern)
    if shape.anchored:
        source_dir = os.path.dirname(record.source) or "the repository root"
        info("a slash inside the pattern anchors it to %s; it does not match at "
             "other depths" % source_dir)
    if shape.dir_only:
        info("the trailing slash restricts it to directories")


def escaped_trailing_space(body, dropped):
    """The pattern rewritten to keep the trailing spaces git dropped.

    Escaping only the last one is enough — the scan back from the end stops at
    a backslash — so `logs  ` becomes `logs \\ `, which is two trailing spaces
    again. Escaping every space would be wrong in the other direction, since
    `\\ \\ ` is not what the author typed either.
    """
    if not dropped:
        return body
    return body + dropped[:-1] + "\\" + dropped[-1]


def report_rule_lint(sourced_rules):
    """Warn about rules that do not say what they appear to say.

    Only the ignore files' own text can show this: `check-ignore` reports the
    pattern git arrived at, with the trailing space already gone, so a rule
    that matches nothing because of one looks identical there to a rule that
    was written correctly.
    """
    problems = 0
    for entry in sourced_rules:
        dropped = entry.rule.shape.trailing_space
        if not dropped:
            continue
        warn("%s:%d: %s ends in %d space(s), which git drops before matching"
             % (entry.source, entry.rule.lineno, entry.rule.text, len(dropped)))
        info("if it was meant, escape the last one: %s"
             % escaped_trailing_space(entry.rule.shape.body, dropped))
        problems += 1
    return problems


def diagnose_path(path, rule, rule_no_index, all_rules):
    """Explain one path's ignore status. Returns the number of problems found."""
    head(path)

    if not matched(rule) and ignores(rule_no_index):
        bad("not ignored — the file is tracked, so ignore rules do not apply")
        info("the rule that would have matched: %s" % describe_rule(rule_no_index))
        info("fix: git rm --cached -- %s" % path)
        info("     then commit the removal; the working file is left alone")
        return 1

    if not matched(rule):
        info("not ignored — no rule matches it")
        info("nothing in the ignore files above claims this path")
        return 0

    if not ignores(rule):
        ok("not ignored — re-included by %s" % describe_rule(rule))
        report_pattern_shape(rule)
        return 0

    ok("ignored by %s" % describe_rule(rule))
    report_pattern_shape(rule)

    blocked_by = None
    for parent in ancestors(path):
        if is_ignored(parent):
            blocked_by = parent
            break
    if blocked_by is None:
        return 0

    info("the match is on the directory %s, not on the file" % blocked_by)
    dead = dead_negations(all_rules, blocked_by)
    if not dead:
        return 0

    for entry in dead:
        bad("%s:%d: %s can never take effect"
            % (entry.source, entry.rule.lineno, entry.rule.text))
    info("git does not descend into an excluded directory, so no pattern can "
         "re-include anything below %s" % blocked_by)

    # Both lines of the fix are written for the file that holds the exclusion,
    # so they are anchored the same way. Printing the negation as the user
    # typed it in some other ignore file would paste into a rule that points
    # somewhere else.
    base = os.path.dirname(rule.source)
    exclude = os.path.relpath(blocked_by, base) if base else blocked_by
    keep = os.path.relpath(path, base) if base else path
    if exclude == ".":
        exclude, keep = blocked_by, path
    info("fix: in %s, exclude the contents rather than the directory, and "
         "re-include every directory down to the file:" % rule.source)
    for line in reinclusion_recipe(exclude, keep):
        info("     %s" % line)
    return len(dead)


def scan_tracked(root):
    """Name tracked files that an ignore rule claims — the .env case.

    This is what running the script with no arguments is for. A rule written
    after the file was committed looks correct in every editor and does
    nothing, and nothing in git's normal output ever mentions it.
    """
    head("tracked files matched by an ignore rule")
    files = tracked_files()
    if files is None:
        return 1
    if not files:
        info("no tracked files")
        return 0

    matches = check_ignore(files, no_index=True)
    if matches is None:
        info("cannot say which tracked files a rule claims")
        return 1
    claimed = [p for p in files if ignores(matches.get(p))]
    if not claimed:
        ok("none — every ignore rule here applies to untracked paths only")
        return 0

    bad("%d tracked file(s) match an ignore rule and are tracked anyway"
        % len(claimed))
    for path in claimed[:SCAN_LIMIT]:
        print("        %s  (%s)" % (path, describe_rule(matches[path])))
    if len(claimed) > SCAN_LIMIT:
        info("... and %d more" % (len(claimed) - SCAN_LIMIT))
    info("each was committed before its rule existed; the rule has no effect "
         "until the file leaves the index")
    info("fix: git rm --cached -- <path>, then commit")
    return len(claimed)


def run_report(args):
    root = repo_root()
    if root is None:
        bad("not inside a Git repository")
        return 2

    paths = []
    for given in args.path:
        path = os.path.relpath(os.path.abspath(given), root)
        if path.startswith(".."):
            # Report what was typed: the relpath of an outside path is a stack
            # of `../` that names nothing the reader passed in.
            bad("%s is outside the repository at %s" % (given, shorten(root)))
            return 3
        paths.append(path)

    problems = report_sources(root, paths)

    if not paths:
        return 1 if problems + scan_tracked(root) else 0

    all_rules = []
    for source in active_ignore_files(root, paths):
        base = os.path.relpath(os.path.dirname(source), root)
        if base in (".", ".git/info", os.path.join(".git", "info")):
            base = ""
        for rule in read_rules(source):
            all_rules.append(SourcedRule(rel(root, source), base, rule))

    problems += report_rule_lint(all_rules)

    with_index = check_ignore(paths)
    without_index = check_ignore(paths, no_index=True)
    if with_index is None or without_index is None:
        info("cannot explain these paths without an answer from git")
        return 1
    for path in paths:
        problems += diagnose_path(
            path, with_index.get(path), without_index.get(path), all_rules
        )
    return 1 if problems else 0


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
        description="Explain why a path is ignored, or why it is not."
    )
    parser.add_argument("path", nargs="*",
                        help="path to explain; with none, scan for tracked files "
                             "an ignore rule claims")
    parser.add_argument("--quiet", action="store_true",
                        help="print nothing; communicate the verdict through the exit code")
    args = parser.parse_args(argv)

    if args.quiet:
        with contextlib.redirect_stdout(io.StringIO()):
            return run_report(args)
    return run_report(args)


if __name__ == "__main__":
    sys.exit(main())

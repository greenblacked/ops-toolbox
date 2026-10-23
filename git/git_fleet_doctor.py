#!/usr/bin/env python3
"""Run every git doctor across many repositories and print one verdict table.

The doctors answer one repository at a time. A machine with forty clones -
from clone-repos.sh, a build agent's workspace, a mirror farm - needs the other
question answered: which of them have a tracked secret, a stale lock, a dead
core.hooksPath? This finds the repositories under one or more roots, runs each
git_*_doctor.py beside it in --quiet mode in each of them, and prints a table
of verdicts with one overall exit code. --details re-runs only the failing
cells loudly, so the diagnosis arrives without a second command.

Offline and read-only: every doctor it drives is read-only, it passes them
nothing but --quiet (never --probe, --test-auth, --test-sign or --fsck), and
their stdin is /dev/null. git_ssh_doctor.py is left out unless named with
--only, because its default run attempts authentication against each SSH
remote.

The doctors are found beside this script (and on PATH as a fallback), so a
doctor added later is picked up without an edit here. Copied alone into ~/bin
it has nothing to drive; copy the doctors with it.

    ./git_fleet_doctor.py ~/src                       # every repository under ~/src
    ./git_fleet_doctor.py --only ignore --only secrets ~/src
    ./git_fleet_doctor.py --details --exclude 'archive/*' ~/src /srv/mirrors
"""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import fnmatch
import io
import os
import re
import shutil
import signal
import subprocess
import sys

HOME = os.path.expanduser("~")

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = C_BOLD = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"

# Doctors looked up on PATH when none sit beside this script.
KNOWN_DOCTORS = ("health", "hooks", "ignore", "remote", "secrets", "signing", "ssh",
                 "submodule")
# Doctors left out unless --only names them: their default run is not offline.
NOT_BY_DEFAULT = frozenset(("ssh",))


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


# --------------------------------------------------------------------------
# Pure helpers. Everything below this line takes its input as arguments, so it
# can be unit-tested with a temporary directory tree and no doctor. Running
# the doctors is left untested here; the integration suite does it for real.
# --------------------------------------------------------------------------
_DOCTOR_NAME = re.compile(r"^git_([a-z0-9]+)_doctor\.py$")
# Directories never searched for repositories: a dependency tree can hold
# thousands of vendored clones that are not the user's to diagnose.
SKIP_DIRS = frozenset((".git", "node_modules"))


def doctor_key(filename):
    """'ssh' for git_ssh_doctor.py; None for anything else, this driver included."""
    match = _DOCTOR_NAME.match(filename)
    if not match or match.group(1) == "fleet":
        return None
    return match.group(1)


def verdict(rc, timed_out):
    """The table cell for one doctor's exit code.

    4 is the doctors' "nothing to diagnose here". Every other code than
    0, 1 and 4 is the doctor failing to run - a usage error, a crash - and
    shows as ERR, so a broken invocation is never read as a finding.
    """
    if timed_out:
        return "TIME"
    return {0: "ok", 1: "FAIL", 4: "n/a"}.get(rc, "ERR")


def is_repo(path):
    """True when `path` is a repository root: a `.git` entry, or a bare layout.

    A bare or mirror repository has no `.git`; it is the git directory
    itself, recognised by HEAD, objects/ and refs/ side by side. Only those
    three names are looked at, so its internals are never searched.
    """
    if os.path.lexists(os.path.join(path, ".git")):
        return True
    return (os.path.isfile(os.path.join(path, "HEAD"))
            and os.path.isdir(os.path.join(path, "objects"))
            and os.path.isdir(os.path.join(path, "refs")))


def walk_repos(root, depth, excludes):
    """Sorted repository roots at most `depth` levels below `root`.

    A directory is a repository when it holds a `.git` entry, directory or
    file, so linked worktrees and submodule checkouts count, or when it is
    a bare or mirror repository (HEAD, objects/ and refs/). A repository is
    not searched further: a clone nested inside another is the outer one's
    business. Symlinked directories are not followed, so the walk cannot
    leave the root or loop. `excludes` are globs over the path relative to
    `root`; `root` itself is returned when it is a repository.
    """
    root = os.path.abspath(root)
    if is_repo(root):
        return [root]
    found = []
    pending = [(root, 0)]
    while pending:
        directory, level = pending.pop()
        if level >= depth:
            continue
        try:
            entries = list(os.scandir(directory))
        except OSError:
            continue
        for entry in entries:
            if entry.name in SKIP_DIRS:
                continue
            try:
                if not entry.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            relative = os.path.relpath(entry.path, root)
            if any(fnmatch.fnmatchcase(relative, glob) for glob in excludes):
                continue
            if is_repo(entry.path):
                found.append(entry.path)
            else:
                pending.append((entry.path, level + 1))
    return sorted(found)


def repo_labels(repos):
    """{repo: label}, each repository's path relative to their common parent."""
    if not repos:
        return {}
    if len(repos) == 1:
        return {repos[0]: os.path.basename(repos[0]) or repos[0]}
    common = os.path.commonpath(repos)
    return {repo: os.path.relpath(repo, common) for repo in repos}


def classify_row(cells):
    """'findings', 'errors' or 'clean' for one repository's cells."""
    values = set(cells.values())
    if "FAIL" in values:
        return "findings"
    if values & {"ERR", "TIME"}:
        return "errors"
    return "clean"


def render_table(rows, keys):
    """Fixed-width text for [(label, {key: cell})], doctors in sorted order,
    ending in a one-line summary."""
    keys = sorted(keys)
    label_width = max([len("repo")] + [len(label) for label, _ in rows])
    widths = [max(len(key), 4) for key in keys]
    lines = ["  ".join(["repo".ljust(label_width)]
                       + [key.ljust(w) for key, w in zip(keys, widths)]).rstrip()]
    for label, cells in rows:
        lines.append("  ".join([label.ljust(label_width)]
                               + [cells.get(key, "-").ljust(w)
                                  for key, w in zip(keys, widths)]).rstrip())
    kinds = [classify_row(cells) for _, cells in rows]
    lines.append("%d repo(s): %d clean, %d with findings, %d errors" % (
        len(rows), kinds.count("clean"), kinds.count("findings"), kinds.count("errors")))
    return "\n".join(lines)


def overall_exit(rows):
    """1 on any FAIL, else 2 on any ERR or TIME, else 0; 4 with no rows."""
    if not rows:
        return 4
    kinds = [classify_row(cells) for _, cells in rows]
    if "findings" in kinds:
        return 1
    if "errors" in kinds:
        return 2
    return 0


# --------------------------------------------------------------------------
# The impure edge: finding the doctors and running them.
# --------------------------------------------------------------------------
def discover_doctors():
    """{key: path} for the doctors beside this script, else on PATH."""
    here = os.path.dirname(os.path.realpath(__file__))
    found = {}
    try:
        names = sorted(os.listdir(here))
    except OSError:
        names = []
    for name in names:
        key = doctor_key(name)
        path = os.path.join(here, name)
        if key and os.path.isfile(path):
            found[key] = path
    if found:
        return found
    for key in KNOWN_DOCTORS:
        path = shutil.which("git_%s_doctor.py" % key)
        if path:
            found[key] = path
    return found


def run_doctor(path, repo, timeout, quiet=True):
    """(rc, timed_out, output) for one doctor in one repository.

    The doctor runs in its own session so that on a timeout the whole group
    goes, git children included. output is captured only when not quiet.
    """
    cmd = [sys.executable, path] + (["--quiet"] if quiet else [])
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=repo,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL if quiet else subprocess.PIPE,
            stderr=subprocess.DEVNULL if quiet else subprocess.STDOUT,
            start_new_session=True,
        )
    except OSError as exc:
        return 255, False, str(exc)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        return proc.returncode, True, ""
    return proc.returncode, False, (out or b"").decode("utf-8", "replace")


def check_repo(repo, doctors, timeout):
    """{key: cell} for one repository, its doctors run one after another."""
    cells = {}
    for key, path in sorted(doctors.items()):
        rc, timed_out, _ = run_doctor(path, repo, timeout)
        cells[key] = verdict(rc, timed_out)
    return cells


def run_report(args, doctors):
    repos = []
    for root in args.root:
        repos.extend(walk_repos(root, args.depth, args.exclude))
    repos = sorted(set(repos))
    if not repos:
        head("repositories")
        warn("no Git repository found within %d level(s) of %s"
             % (args.depth, ", ".join(shorten(r) for r in args.root)))
        return 4

    labels = repo_labels(repos)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {repo: pool.submit(check_repo, repo, doctors, args.timeout)
                   for repo in repos}
        results = {repo: future.result() for repo, future in futures.items()}
    rows = [(labels[repo], results[repo]) for repo in repos]

    head("repositories")
    if len(repos) > 1:
        info("under %s" % shorten(os.path.commonpath(repos)))
    print(render_table(rows, list(doctors)))
    info("n/a: nothing for that doctor to check; ERR: the doctor did not run "
         "(exit 2, 3 or a crash); TIME: it ran past --timeout")

    if args.details:
        for repo in repos:
            for key in sorted(doctors):
                if results[repo].get(key) not in ("FAIL", "ERR"):
                    continue
                head("%s / %s" % (labels[repo], key))
                _, _, output = run_doctor(doctors[key], repo, args.timeout, quiet=False)
                for line in output.rstrip("\n").splitlines():
                    print("      %s" % line)

    rc = overall_exit(rows)
    print()
    if rc == 1:
        bad("findings in %d repo(s)" % sum(1 for _, c in rows if "FAIL" in c.values()))
    elif rc == 2:
        bad("a doctor could not run in some repositories")
    else:
        ok("every repository is clean")
    return rc


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


def bounded_int(low, high=None):
    def parse(value):
        try:
            number = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError("%r is not a whole number" % value) from None
        if number < low or (high is not None and number > high):
            raise argparse.ArgumentTypeError(
                "must be %s, not %d" % ("at least %d" % low if high is None
                                        else "between %d and %d" % (low, high), number))
        return number
    return parse


def main(argv=None):
    parser = Usage3Parser(
        description="Run every git_*_doctor.py beside this script in each repository "
                    "under the given roots and print one table of verdicts.",
        epilog="Exit codes: 0 every cell ok or n/a, 1 at least one FAIL, 2 a doctor "
               "could not run or timed out, or no doctor was found, 3 usage, 4 no "
               "repository found.",
    )
    parser.add_argument("root", nargs="+", metavar="ROOT",
                        help="directory to search; a repository itself is accepted too")
    parser.add_argument("--depth", type=bounded_int(0), default=3, metavar="N",
                        help="how many levels below ROOT to look (default: 3)")
    parser.add_argument("--exclude", action="append", default=[], metavar="GLOB",
                        help="skip directories whose path relative to ROOT matches "
                             "(repeatable)")
    parser.add_argument("--only", action="append", default=[], metavar="NAME",
                        help="run only this doctor, e.g. ignore or secrets (repeatable)")
    parser.add_argument("--timeout", type=bounded_int(1), default=60, metavar="SECONDS",
                        help="per doctor per repository (default: 60)")
    parser.add_argument("--jobs", type=bounded_int(1, 16), default=4, metavar="N",
                        help="repositories checked in parallel, 1 to 16 (default: 4)")
    parser.add_argument("--details", action="store_true",
                        help="re-run each failing doctor and print its report")
    parser.add_argument("--quiet", action="store_true",
                        help="print nothing; communicate the verdict through the exit code")
    args = parser.parse_args(argv)

    for root in args.root:
        if not os.path.isdir(root):
            parser.error("%s is not a directory" % root)

    doctors = discover_doctors()
    if not doctors:
        print("no git_*_doctor.py found beside this script or on PATH", file=sys.stderr)
        return 2
    if args.only:
        unknown = sorted(set(args.only) - set(doctors))
        if unknown:
            parser.error("no doctor named %s; available: %s"
                         % (", ".join(unknown), ", ".join(sorted(doctors))))
        doctors = {k: v for k, v in doctors.items() if k in args.only}
    else:
        doctors = {k: v for k, v in doctors.items() if k not in NOT_BY_DEFAULT}

    if args.quiet:
        with contextlib.redirect_stdout(io.StringIO()):
            return run_report(args, doctors)
    return run_report(args, doctors)


if __name__ == "__main__":
    sys.exit(main())

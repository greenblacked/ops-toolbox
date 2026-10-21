#!/usr/bin/env python3
"""Diagnose a repository that is locked, slow, or growing without bound.

The other doctors look at what a repository is connected to: keys, signing,
remotes, ignore rules. This one looks at the repository itself, for the class
of incident that arrives as "git says index.lock exists", "git got slow" or
"the disk keeps filling up", on a laptop clone or on a build agent's cache:

  locks        `rm .git/index.lock` is the runbook answer, and it is the wrong
               one while a git process still holds the lock. A lock is only
               called stale here when it is old AND no git process is running,
               and the rm is printed, never run.
  auto gc      a failed automatic gc leaves gc.log behind, and while it is
               there `git gc --auto` refuses to run again for a day, so loose
               objects pile up with nothing said after the first warning.
  objects      loose objects and packs against the gc.auto and
               gc.autoPackLimit thresholds, and garbage an interrupted gc or
               fetch left in objects/pack.
  maintenance  whether a large repository is registered for background
               maintenance and has a commit-graph.
  clone shape  shallow and partial clones, which change what log and blame
               can see.

Read-only. It stats files, reads at most three lines of gc.log, and runs git
commands that write nothing. `--fsck` adds a connectivity check, opt-in
because it reads every object.

    ./git_health_doctor.py                  # this repository
    ./git_health_doctor.py --lock-age 30    # call a lock stale after 30 minutes
    ./git_health_doctor.py --fsck           # also check object connectivity
    ./git_health_doctor.py --json           # the same verdict as one JSON object
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
import time

HOME = os.path.expanduser("~")

C_RESET = C_RED = C_GREEN = C_YELLOW = C_DIM = C_BOLD = ""
if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
    C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
    C_RED, C_GREEN, C_YELLOW = "\033[31m", "\033[32m", "\033[33m"

# git's own defaults for the two automatic-gc thresholds.
GC_AUTO_DEFAULT = 6700
GC_AUTO_PACK_LIMIT_DEFAULT = 50
# Packed size, in KiB, above which a repository is worth pointing at the size
# report, and above which background maintenance and a commit-graph pay off.
LARGE_PACK_KIB = 500 * 1024
MAINTENANCE_KIB = 100 * 1024
# How many files under refs/ are looked at for stray locks before the scan
# stops. A repository with a million loose refs is a finding of its own.
REFS_SCAN_LIMIT = 5000
# Minutes before a lock counts as stale rather than as a command mid-flight.
DEFAULT_LOCK_AGE = 10

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


def run(cmd, timeout=15):
    """Run a command, returning (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 255, "", str(exc)


# --------------------------------------------------------------------------
# Pure helpers. Everything below this line takes its input as strings, numbers
# and lists, with the clock injected, so it can be unit-tested without a
# repository or a process table. The parts that stat files and shell out are
# left untested, because mocking them would only assert that the mock was
# called.
# --------------------------------------------------------------------------
COUNT_KEYS = ("count", "size", "in-pack", "packs", "size-pack", "prune-packable",
              "garbage", "size-garbage")


def parse_count_objects(text):
    """Parse `git count-objects -v` into {key: int}.

    Sizes are KiB, because -v without -H prints them that way. A key git did
    not print is absent rather than zero, and a line that is not `key: int` is
    skipped: a newer git adding a field must not break an older doctor.
    """
    counts = {}
    for line in (text or "").splitlines():
        key, sep, value = line.partition(":")
        if not sep:
            continue
        key = key.strip()
        if key not in COUNT_KEYS:
            continue
        try:
            counts[key] = int(value.strip())
        except ValueError:
            continue
    return counts


# git_running()'s answer when a git process exists but its repository is unknown.
UNATTRIBUTED = "unattributed"


def classify_locks(locks, now, min_age_minutes, git_running):
    """Judge each (path, mtime) lock file. Returns [(level, message, fix)].

    A lock is only called stale when it is old enough AND no git process is
    running: removing index.lock under a live `git rebase` breaks the very
    operation the user is waiting on. git_running is True, False, or None when
    it could not be told, and None never earns the fail verdict. UNATTRIBUTED
    means a git process exists but could not be tied to this repository, which
    is not enough to call the lock stale either.
    """
    findings = []
    for path, mtime in locks:
        age = int((now - mtime) // 60)
        name = os.path.basename(path)
        if age < min_age_minutes:
            findings.append((
                "info",
                "%s is %d min old: recent, a git command is probably mid-flight"
                % (path, max(age, 0)),
                None,
            ))
        elif git_running is False:
            findings.append((
                "fail",
                "%s is %d min old and no git process is running: every command "
                "that needs it stops with '%s': File exists" % (path, age, name),
                "rm -- %s   # after confirming no git is running" % shlex.quote(path),
            ))
        elif git_running == UNATTRIBUTED:
            findings.append((
                "warn",
                "%s is %d min old, and a git process is running somewhere; "
                "cannot tell whether it owns this lock" % (path, age),
                "rm -- %s   # only after confirming no git is running here"
                % shlex.quote(path),
            ))
        elif git_running:
            findings.append((
                "warn",
                "%s is %d min old, but a git process is running here; wait for it"
                % (path, age),
                "re-run this doctor once that process has exited",
            ))
        else:
            findings.append((
                "warn",
                "%s is %d min old, and whether a git process is running cannot "
                "be told" % (path, age),
                "rm -- %s   # only after confirming no git is running"
                % shlex.quote(path),
            ))
    return findings


def object_findings(counts, gc_auto, gc_auto_pack_limit, gc_disabled):
    """What the object counts say about housekeeping. [(level, message, fix)].

    gc_auto and gc_auto_pack_limit are the effective values, git's defaults
    when unset. With automatic gc disabled the thresholds mean nothing, so the
    loose-object count is context rather than a missed run.
    """
    findings = []
    loose = counts.get("count", 0)
    packs = counts.get("packs", 0)
    garbage = counts.get("garbage", 0)

    if gc_disabled:
        if loose:
            findings.append((
                "info",
                "%d loose object(s); automatic gc is disabled, so they only go "
                "away when something runs git gc" % loose,
                None,
            ))
    elif loose > gc_auto:
        findings.append((
            "warn",
            "%d loose objects, above gc.auto (%d): automatic gc has not run"
            % (loose, gc_auto),
            "git gc",
        ))

    if not gc_disabled and gc_auto_pack_limit > 0 and packs > gc_auto_pack_limit:
        findings.append((
            "warn",
            "%d packs, above gc.autoPackLimit (%d): every object lookup searches "
            "each of them" % (packs, gc_auto_pack_limit),
            "git repack -ad",
        ))

    if garbage > 0:
        findings.append((
            "warn",
            "%d garbage file(s) (%d KiB) in objects/pack, left by an interrupted "
            "gc or fetch" % (garbage, counts.get("size-garbage", 0)),
            "git prune   # when no git process is running; it removes stale "
            "temporary packs",
        ))

    if counts.get("size-pack", 0) > LARGE_PACK_KIB:
        findings.append((
            "info",
            "%.1f MiB packed: git_size_report.sh names the blobs that account "
            "for it" % (counts["size-pack"] / 1024.0),
            None,
        ))
    return findings


GC_LOG_EXPIRY_DEFAULT = "1.day"
_EXPIRY_UNITS = {"second": 1, "minute": 60, "hour": 3600, "day": 86400,
                 "week": 7 * 86400, "month": 31 * 86400, "year": 366 * 86400}
_EXPIRY = re.compile(r"^(\d+)[. ]+(second|minute|hour|day|week|month|year)s?"
                     r"(?:[. ]+ago)?$")


def parse_expiry_seconds(text):
    """Seconds named by a gc.logExpiry value, or None for "never expires".

    Handles N.day(s), N.week(s), N.hour(s) and the other units (with or
    without a trailing ".ago"), and `now`. Months and years are rounded up,
    and anything not understood (`never` included) gives None: the gc.log
    then keeps being reported as blocking, the conservative answer.
    """
    value = (text or "").strip().lower()
    if value == "now":
        return 0
    match = _EXPIRY.match(value)
    if match:
        return int(match.group(1)) * _EXPIRY_UNITS[match.group(2)]
    return None


def gc_log_blocks(age_seconds, expiry_seconds):
    """True while a gc.log of this age still stops automatic gc."""
    return expiry_seconds is None or age_seconds < expiry_seconds


def parse_gc_log(text):
    """The first three non-empty lines of gc.log, stripped."""
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return lines[:3]


def parse_process_names(text):
    """Process names, one per line, reduced to their basename.

    macOS `ps -o comm=` prints a full path, Linux a truncated name and
    /proc/PID/comm a bare one; the basename makes the three comparable.
    """
    return [os.path.basename(line.strip()) for line in (text or "").splitlines()
            if line.strip()]


def git_is_running(names):
    """Whether a process called exactly `git` is in the list.

    Exactly: git-lfs, gitk and a credential daemon do not hold index.lock,
    and counting them would make every lock look busy forever.
    """
    return "git" in names


def _inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def parse_git_args(args):
    """(git_dir, work_tree, chdirs) from the global options of a git command
    line (args without the leading `git`), in both `--opt=X` and `--opt X`
    forms. Parsing stops at the subcommand; a missing value gives None."""
    git_dir = work_tree = None
    chdirs = []
    skip_value = ("-c", "--namespace", "--super-prefix", "--config-env",
                  "--exec-path", "--list-cmds")
    i = 0
    while i < len(args):
        arg = args[i]
        if not arg.startswith("-") or arg == "-":
            break
        value = None
        name = arg
        if arg.startswith("--") and "=" in arg:
            name, value = arg.split("=", 1)
        elif arg.startswith("-C") and len(arg) > 2:
            name, value = "-C", arg[2:]
        elif name in ("-C", "--git-dir", "--work-tree") or name in skip_value:
            if i + 1 < len(args):
                value = args[i + 1]
            i += 1
        i += 1
        if name == "-C" and value is not None:
            chdirs.append(value)
        elif name == "--git-dir" and value is not None:
            git_dir = value
        elif name == "--work-tree" and value is not None:
            work_tree = value
    return git_dir, work_tree, chdirs


def attribute_git_processes(procs, repo_paths):
    """Whether any git process belongs to this repository.

    procs is [(cwd, git_dir, work_tree[, args])] for each process called
    `git`; cwd is None when it could not be read, git_dir and work_tree are
    the GIT_DIR and GIT_WORK_TREE of its environment or None, args its command
    line after `git` (or None). The options of the command line count too:
    `git --git-dir=/repo/.git fetch` run from elsewhere sets GIT_DIR only
    internally, so /proc/PID/environ never shows it, and -C changes the
    directory the others are relative to. repo_paths are the worktree, git
    directory and common directory of this repository (and its linked
    worktrees). A process belongs to it when its working directory, GIT_DIR or
    GIT_WORK_TREE lies inside one of them.

    True: one does. False: none do and every process was placed elsewhere (or
    there are none). UNATTRIBUTED: none do, but one has no repository
    evidence at all (no readable working directory and no absolute path).
    """
    roots = [os.path.realpath(p) for p in repo_paths if p]
    unplaced = False
    for proc in procs:
        cwd, git_dir, work_tree = proc[:3]
        args = proc[3] if len(proc) > 3 else None
        arg_dir, arg_tree, chdirs = parse_git_args(args or [])
        candidates = []
        base = cwd
        for extra in (git_dir, work_tree):
            if extra:
                path = _resolve(base, extra)
                if path:
                    candidates.append(path)
        for chdir in chdirs:
            base = _resolve(base, chdir)
            if base is None:
                break
        if base is not None:
            candidates.append(base)
        for extra in (arg_dir, arg_tree):
            if extra:
                path = _resolve(base, extra)
                if path:
                    candidates.append(path)
        if any(_inside(c, r) for c in candidates for r in roots):
            return True
        if not candidates:
            unplaced = True
    return UNATTRIBUTED if unplaced else False


def _resolve(base, path):
    """path made absolute against base and canonical, or None when it is
    relative and base is unknown."""
    if os.path.isabs(path):
        return os.path.realpath(path)
    if base is None:
        return None
    return os.path.realpath(os.path.join(base, path))


# --------------------------------------------------------------------------
# The impure edge: git, the filesystem and the process table.
# --------------------------------------------------------------------------
def git_path(*args):
    rc, out, _ = run(["git", "rev-parse", *args])
    if rc != 0 or not out.strip():
        return None
    return os.path.abspath(out.strip())


def config_int(key):
    """An integer git config value with git's own suffix handling, or None."""
    rc, out, _ = run(["git", "config", "--int", "--get", key])
    if rc != 0:
        return None
    try:
        return int(out.strip())
    except ValueError:
        return None


def config_value(key, *flags):
    rc, out, _ = run(["git", "config", *flags, "--get", key])
    return out.strip() if rc == 0 else None


def _proc_git_processes():
    """[(cwd, GIT_DIR, GIT_WORK_TREE, args)] per `git` process from /proc, or None
    when /proc cannot place processes (macOS, a restricted container)."""
    try:
        entries = os.listdir("/proc")
        os.readlink("/proc/self/cwd")
    except OSError:
        return None
    procs = []
    seen_any = False
    for entry in entries:
        if not entry.isdigit():
            continue
        base = os.path.join("/proc", entry)
        try:
            with open(os.path.join(base, "comm"), encoding="utf-8",
                      errors="replace") as handle:
                name = handle.read().strip()
        except OSError:
            continue
        seen_any = True
        if name != "git":
            continue
        try:
            cwd = os.readlink(os.path.join(base, "cwd"))
        except OSError:
            cwd = None
        git_dir = work_tree = None
        try:
            with open(os.path.join(base, "environ"), "rb") as handle:
                for item in handle.read().split(b"\0"):
                    if item.startswith(b"GIT_DIR="):
                        git_dir = os.fsdecode(item[8:])
                    elif item.startswith(b"GIT_WORK_TREE="):
                        work_tree = os.fsdecode(item[14:])
        except OSError:
            pass
        args = None
        try:
            with open(os.path.join(base, "cmdline"), "rb") as handle:
                parts = [os.fsdecode(x) for x in handle.read().split(b"\0")]
            args = parts[1:-1] if parts and parts[-1] == "" else parts[1:]
        except OSError:
            pass
        procs.append((cwd, git_dir, work_tree, args))
    return procs if seen_any else None


def git_running(repo_paths=()):
    """True when a git process works on this repository, False when none does,
    UNATTRIBUTED when one runs but cannot be tied to it, None when the process
    table cannot be read.

    /proc first, where the working directory of each git process says which
    repository it is in. Where only ps works (macOS) the names are all there
    is: a git process is then UNATTRIBUTED, never a match, because any
    unrelated git would otherwise hide a stale lock. Neither is a reason to
    guess, so the caller treats None as "cannot tell".
    """
    procs = _proc_git_processes()
    if procs is not None:
        return attribute_git_processes(procs, repo_paths)
    rc, out, _ = run(["ps", "-A", "-o", "comm="])
    if rc == 0 and out.strip():
        return UNATTRIBUTED if git_is_running(parse_process_names(out)) else False
    return None


def worktree_paths():
    """The paths of every worktree of this repository, [] when git cannot say."""
    rc, out, _ = run(["git", "worktree", "list", "--porcelain"])
    if rc != 0:
        return []
    return [line[len("worktree "):] for line in out.splitlines()
            if line.startswith("worktree ")]


def find_locks(directories, refs_dir):
    """[(path, mtime)] for every *.lock directly in `directories` and under
    refs_dir, plus whether the refs scan stopped at REFS_SCAN_LIMIT."""
    locks = []
    seen = set()
    for directory in directories:
        try:
            entries = list(os.scandir(directory))
        except OSError:
            continue
        for entry in entries:
            if not entry.name.endswith(".lock"):
                continue
            try:
                if not entry.is_file(follow_symlinks=False):
                    continue
                real = os.path.realpath(entry.path)
                if real in seen:
                    continue
                seen.add(real)
                locks.append((entry.path, entry.stat(follow_symlinks=False).st_mtime))
            except OSError:
                continue

    truncated = False
    scanned = 0
    for dirpath, _, filenames in os.walk(refs_dir):
        for name in filenames:
            scanned += 1
            if scanned > REFS_SCAN_LIMIT:
                truncated = True
                break
            if name.endswith(".lock"):
                path = os.path.join(dirpath, name)
                try:
                    locks.append((path, os.stat(path).st_mtime))
                except OSError:
                    continue
        if truncated:
            break
    return sorted(locks), truncated


def print_findings(findings):
    """Print (level, message, fix) findings. Returns the fail-level count."""
    problems = 0
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
    return problems


def report_locks(git_dir, common_dir, now, lock_age, toplevel=None):
    head("locks")
    directories = [git_dir] if git_dir == common_dir else [git_dir, common_dir]
    locks, truncated = find_locks(directories, os.path.join(common_dir, "refs"))
    if truncated:
        info("stopped looking for ref locks after %d files under refs/"
             % REFS_SCAN_LIMIT)
    if not locks:
        ok("no lock files")
        return 0

    # Absolute paths, not shorten()ed: the fix line is meant to be pasted,
    # and a quoted ~ is not expanded by the shell.
    old = any((now - mtime) // 60 >= lock_age for _, mtime in locks)
    running = False
    if old:
        running = git_running([toplevel, git_dir, common_dir, *worktree_paths()])
    if old and running is None:
        info("neither ps nor /proc could be read, so whether a git process is "
             "running cannot be told")
    return print_findings(classify_locks(locks, now, lock_age, running))


def report_auto_gc(common_dir, gc_auto, now, log_expiry=None):
    head("auto gc")
    problems = 0
    gc_log = os.path.join(common_dir, "gc.log")
    expiry_text = log_expiry or GC_LOG_EXPIRY_DEFAULT
    blocks = False
    if os.path.isfile(gc_log):
        try:
            age = now - os.stat(gc_log).st_mtime
        except OSError:
            age = 0
        blocks = gc_log_blocks(age, parse_expiry_seconds(expiry_text))
        if not blocks:
            info("gc.log is older than gc.logExpiry (%s), so automatic gc "
                 "runs again and replaces it" % expiry_text)
    if blocks:
        bad("gc.log exists: automatic gc will not run again until it is removed "
            "or gc.logExpiry (%s) passes" % expiry_text)
        try:
            with open(gc_log, encoding="utf-8", errors="replace") as handle:
                lines = parse_gc_log(handle.read(64 * 1024))
        except OSError:
            lines = []
        for line in lines:
            info("    %s" % line)
        info("fix: read %s, fix what it reports, then rm -- %s"
             % (shorten(gc_log), shlex.quote(gc_log)))
        problems += 1

    if gc_auto is not None and gc_auto <= 0:
        warn("automatic gc is disabled (gc.auto=%d); something else must run git gc"
             % gc_auto)
    elif not problems:
        ok("automatic gc is enabled (gc.auto=%d)"
           % (gc_auto if gc_auto is not None else GC_AUTO_DEFAULT))
    return problems


def report_objects(gc_auto, pack_limit, gc_disabled):
    head("objects")
    rc, out, err = run(["git", "count-objects", "-v"], timeout=60)
    if rc != 0:
        bad("git count-objects could not answer (exit %d)" % rc)
        for line in err.strip().splitlines()[:3]:
            info("        %s" % line)
        return 1, {}
    counts = parse_count_objects(out)
    findings = object_findings(counts, gc_auto, pack_limit, gc_disabled)
    summary = "%d loose, %d pack(s), %.1f MiB packed" % (
        counts.get("count", 0), counts.get("packs", 0),
        counts.get("size-pack", 0) / 1024.0)
    if not findings:
        ok(summary)
        return 0, counts
    info(summary)
    problems = print_findings(findings)
    # count-objects names each garbage file on stderr; the first few say
    # which interrupted operation left them.
    for line in [ln for ln in err.splitlines() if "garbage" in ln][:3]:
        info("    %s" % line.strip())
    return problems, counts


def report_maintenance(toplevel, objects_dir, counts):
    head("maintenance")
    if config_value("maintenance.auto", "--bool") == "false":
        warn("maintenance.auto is false: git never tidies up after a command, so "
             "objects and packs only shrink when something runs git maintenance")

    large = counts.get("size-pack", 0) > MAINTENANCE_KIB
    rc, out, _ = run(["git", "config", "--global", "--get-all", "maintenance.repo"])
    registered = {os.path.realpath(os.path.expanduser(line.strip()))
                  for line in out.splitlines() if line.strip()} if rc == 0 else set()
    if os.path.realpath(toplevel) in registered:
        ok("registered for background maintenance (maintenance.repo)")
    elif large:
        info("not registered for background maintenance; at this size it keeps "
             "fetches and gc off the critical path")
        info("fix: git maintenance start")
    else:
        info("not registered for background maintenance; automatic gc is enough "
             "at this size")

    graph = os.path.join(objects_dir, "info", "commit-graph")
    graphs = os.path.join(objects_dir, "info", "commit-graphs")
    if os.path.exists(graph) or os.path.isdir(graphs):
        ok("commit-graph present")
    elif large:
        info("no commit-graph: log --graph, merge-base and blame walk every commit "
             "object")
        info("fix: git commit-graph write --reachable --changed-paths")


def report_clone_shape():
    head("clone shape")
    rc, out, _ = run(["git", "rev-parse", "--is-shallow-repository"])
    shallow = rc == 0 and out.strip() == "true"
    if shallow:
        info("shallow clone: git log and blame stop at the boundary")
        info("fix: git fetch --unshallow")

    rc, out, _ = run(["git", "config", "--get-regexp",
                      r"^remote\..*\.(promisor|partialclonefilter)$"])
    promisors = {}
    for line in out.splitlines() if rc == 0 else []:
        key, _, value = line.partition(" ")
        name, field = key[len("remote."):].rsplit(".", 1)
        promisors.setdefault(name, {})[field.lower()] = value
    partial = sorted(n for n, v in promisors.items()
                     if v.get("promisor", "").lower() == "true")
    for name in partial:
        info("partial clone from %s (filter %s): missing objects are fetched on "
             "demand, so an offline checkout or blame can fail"
             % (name, promisors[name].get("partialclonefilter", "unknown")))
    if not shallow and not partial:
        ok("full clone")


def report_fsck():
    head("fsck")
    rc, out, err = run(["git", "fsck", "--connectivity-only", "--no-dangling",
                        "--no-progress"], timeout=600)
    if rc == 0:
        ok("every reachable object is present")
        return 0
    bad("git fsck --connectivity-only failed (exit %d)" % rc)
    for line in (err + out).strip().splitlines()[:10]:
        info("        %s" % line)
    info("fix: git fetch --all, or re-clone; do not run git gc --prune=now until "
         "this is understood")
    return 1


def run_report(args):
    now = args.now if args.now is not None else int(time.time())

    # --absolute-git-dir rather than --show-toplevel: a bare mirror has no
    # work tree, and it is exactly the long-lived clone this is for.
    git_dir = git_path("--absolute-git-dir")
    if git_dir is None:
        bad("not inside a Git repository")
        return 2
    # Linked worktrees keep index.lock and HEAD.lock in their own git dir and
    # everything else - refs, objects, gc.log - in the common one. Asked of
    # git, because in a worktree or a submodule .git is a file.
    common_dir = git_path("--git-common-dir") or git_dir
    rc, out, _ = run(["git", "rev-parse", "--show-toplevel"])
    toplevel = out.strip() if rc == 0 and out.strip() else git_dir
    objects_dir = git_path("--git-path", "objects") or os.path.join(common_dir, "objects")

    gc_auto = config_int("gc.auto")
    gc_disabled = gc_auto is not None and gc_auto <= 0
    pack_limit = config_int("gc.autoPackLimit")

    problems = report_locks(git_dir, common_dir, now, args.lock_age, toplevel)
    problems += report_auto_gc(common_dir, gc_auto, now,
                               config_value("gc.logExpiry"))
    object_problems, counts = report_objects(
        GC_AUTO_DEFAULT if gc_auto is None else gc_auto,
        GC_AUTO_PACK_LIMIT_DEFAULT if pack_limit is None else pack_limit,
        gc_disabled,
    )
    problems += object_problems
    report_maintenance(toplevel, objects_dir, counts)
    report_clone_shape()
    if args.fsck:
        problems += report_fsck()

    print()
    if problems:
        bad("%d problem(s) found" % problems)
        return 1
    ok("no repository health problems found")
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
        description="Diagnose stale locks, failed automatic gc, object bloat and "
                    "maintenance in this repository.",
        epilog="Exit codes: 0 no fail-level finding, 1 a stale lock, a gc.log, an "
               "fsck failure or a git command that could not answer, 2 not inside "
               "a Git repository, 3 usage.",
    )
    parser.add_argument("--lock-age", type=positive_int, default=DEFAULT_LOCK_AGE,
                        metavar="MINUTES",
                        help="minutes before a lock counts as stale (default: %d)"
                             % DEFAULT_LOCK_AGE)
    parser.add_argument("--fsck", action="store_true",
                        help="also run git fsck --connectivity-only (reads every object)")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--quiet", action="store_true",
                        help="print nothing; communicate the verdict through the exit code")
    output.add_argument("--json", action="store_true",
                        help="print one JSON object (exit code and every finding) "
                             "instead of the report")
    parser.add_argument("--now", type=int, default=None, help=argparse.SUPPRESS)
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

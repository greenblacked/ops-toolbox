#!/usr/bin/env python3
"""Diagnose why a git hook does not run.

Hooks fail silently, which is the whole problem. Five ways it happens, none of
which git reports in a form anyone notices:

  hooksPath       a global core.hooksPath shadows every repository's .git/hooks,
                  and one pointing at a directory that does not exist makes
                  every hook vanish without a word.
  exec bit        a hook without it is skipped (older git prints nothing).
  CRLF shebang    a checkout with CRLF line endings turns `#!/bin/sh` into a
                  request for an interpreter called `sh` plus a carriage
                  return.
  names           `pre-commit.sh` and `precommit` are not hook names.
  frameworks      .pre-commit-config.yaml, .husky/, .githooks/ or lefthook.yml
                  committed but never activated in this clone, which is every
                  fresh clone and every CI runner.

Read-only. It lists the hooks directory, stats each file and reads at most the
first line of each hook (and the start of active ones, to recognise a hook
manager), so a secret inside a hook is never printed. It never chmods, rewrites
line endings, edits core.hooksPath or runs a hook; each repair is printed.

    ./git_hooks_doctor.py            # this repository's hooks
    ./git_hooks_doctor.py --json     # the same verdict as one JSON object
"""

from __future__ import annotations

import argparse
import contextlib
import difflib
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

# Hooks larger than this are not read at all; a hook is a script, and a
# megabyte file in the hooks directory is something else.
READ_LIMIT = 1024 * 1024
# How much of an active hook is read to recognise the manager that wrote it.
TEXT_LIMIT = 64 * 1024

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


def find_program(name, path_env):
    """Resolve a program against an injected PATH string, or None."""
    if not name:
        return None
    if os.path.sep in name:
        return name if os.path.isfile(name) and os.access(name, os.X_OK) else None
    for directory in (path_env or "").split(os.pathsep):
        if not directory:
            continue
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# --------------------------------------------------------------------------
# Pure helpers. Everything below this line takes its input as strings, bytes
# and callables, so it can be unit-tested without a repository or a PATH. The
# parts that list directories and shell out are left untested, because
# mocking them would only assert that the mock was called.
# --------------------------------------------------------------------------
# Every hook name git runs, client and server side (githooks(5)). A file in
# the hooks directory with any other name is never run.
HOOK_NAMES = frozenset((
    "applypatch-msg", "pre-applypatch", "post-applypatch", "pre-commit",
    "pre-merge-commit", "prepare-commit-msg", "commit-msg", "post-commit",
    "pre-rebase", "post-checkout", "post-merge", "pre-push", "pre-receive",
    "update", "proc-receive", "post-receive", "post-update",
    "reference-transaction", "push-to-checkout", "pre-auto-gc", "post-rewrite",
    "sendemail-validate", "fsmonitor-watchman", "p4-changelist",
    "p4-prepare-changelist", "p4-post-changelist", "p4-pre-submit",
    "post-index-change",
))
# Hooks git runs in a push target with $GIT_DIR as the working directory, so
# a relative core.hooksPath is read from there, not from the work tree root
# (githooks(5); reference-transaction also runs there for pushed updates).
RECEIVE_HOOKS = frozenset((
    "pre-receive", "update", "post-receive", "post-update", "push-to-checkout",
    "proc-receive", "reference-transaction",
))
# Suffixes that make a hook file a near miss rather than a hook. The last
# three usually mark a copy someone disabled on purpose.
_HOOK_SUFFIXES = (".sh", ".py", ".js", ".bak", ".disabled", ".orig")
DISABLED_SUFFIXES = (".bak", ".disabled", ".orig")
_SQUASHED = {name.replace("-", ""): name for name in HOOK_NAMES}


def near_miss(filename):
    """The hook name `filename` was probably meant to be, or None.

    An exact hook name is not a near miss. Otherwise the name is lower-cased,
    stripped of one script or backup suffix, and read with `_` or a space as
    `-` and with the hyphens dropped altogether (`precommit`), before a last
    close-spelling comparison.
    """
    if filename in HOOK_NAMES:
        return None
    name = filename.lower()
    for suffix in _HOOK_SUFFIXES:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    name = name.replace("_", "-").replace(" ", "-")
    if name in HOOK_NAMES:
        return name
    if name.replace("-", "") in _SQUASHED:
        return _SQUASHED[name.replace("-", "")]
    close = difflib.get_close_matches(name, sorted(HOOK_NAMES), n=1, cutoff=0.85)
    return close[0] if close else None


def parse_shebang(first_line):
    """(interpreter, args, has_cr) from a hook's first line, as bytes.

    No `#!` gives (None, [], False); a byte-order mark before it counts as no
    shebang, because the kernel does not skip one. has_cr is the CRLF
    checkout: the kernel reads the carriage return as part of the last word.
    """
    if not first_line.startswith(b"#!"):
        return None, [], False
    line = first_line.rstrip(b"\n")
    has_cr = line.endswith(b"\r")
    words = line.rstrip(b"\r")[2:].decode("utf-8", "replace").split()
    if not words:
        return "", [], has_cr
    return words[0], words[1:], has_cr


def env_program(args):
    """(split, names) for the words after env in a shebang: whether -S /
    --split-string is used (also with the program attached, as in -Spython3
    or --split-string=python3 -u) and the words that can name the program."""
    split = False
    names = []
    for i, a in enumerate(args):
        if a.startswith("--split-string"):
            split = True
            rest = a[len("--split-string"):]
            if rest.startswith("="):
                rest = rest[1:]
            if rest:
                names.append(rest.split()[0])
            elif i + 1 < len(args):
                names.append(args[i + 1])
            break
        if a.startswith("-S"):
            split = True
            if a[2:]:
                names.append(a[2:])
            elif i + 1 < len(args):
                names.append(args[i + 1])
            break
        if not a.startswith("-"):
            names.append(a)
    return split, names


def shebang_findings(first_line, find_program, path="<file>"):
    """[(level, message, fix)] for one hook's shebang.

    find_program(name) returns where an interpreter resolves (a bare name on
    PATH, an absolute path as itself) or None; it is passed in so the check
    does not depend on the machine running the tests.
    """
    interpreter, args, has_cr = parse_shebang(first_line)
    if has_cr:
        last = (args[-1] if args else os.path.basename(interpreter or "")) or "sh"
        return [(
            "fail",
            "shebang ends in a carriage return (CRLF checkout): the kernel looks for "
            "an interpreter named %s\\r and the hook fails with No such file" % last,
            "perl -pi.bak -e 's/\\r$//' %s   # keeps a .bak; then pin eol=lf for it in "
            ".gitattributes" % shlex.quote(path),
        )]
    if interpreter is None:
        return [(
            "warn",
            "no shebang line: git falls back to running it with /bin/sh",
            "add #!/bin/sh (or the interpreter it needs) as the first line",
        )]
    if not interpreter:
        return [("fail", "the shebang line names no interpreter", "complete the #! line")]
    if os.path.basename(interpreter) == "env":
        split, names = env_program(args)
        if not names:
            return [("fail", "the shebang runs env with no program to run",
                     "name the interpreter: #!/usr/bin/env bash")]
        if len(args) > 1 and not split:
            return [("fail", "the shebang gives env %d arguments (%s) without -S: Linux "
                             "passes them as ONE word and env cannot find that program"
                     % (len(args), " ".join(args)),
                     "#!%s -S %s" % (interpreter, " ".join(args)))]
        if find_program(names[0]) is None:
            return [("fail", "interpreter %s (through env) is not on PATH" % names[0],
                     "install %s, or change the #! line" % names[0])]
        return []
    if not os.path.isabs(interpreter):
        return [("warn", "interpreter %s is a relative path, resolved against wherever "
                         "git happens to run the hook" % interpreter,
                 "use an absolute path or #!/usr/bin/env %s"
                 % os.path.basename(interpreter))]
    if find_program(interpreter) is None:
        return [("fail", "interpreter %s is not an executable" % interpreter,
                 "install it, or change the #! line")]
    if len(args) > 1:
        return [("warn", "the shebang gives %s %d arguments (%s): Linux passes them as "
                         "ONE word, so the interpreter sees a single option it does not "
                         "know" % (interpreter, len(args), " ".join(args)),
                 "use a single option, or #!/usr/bin/env -S %s %s"
                 % (os.path.basename(interpreter), " ".join(args)))]
    return []


def resolve_hooks_path(value, toplevel):
    """core.hooksPath as an absolute path. A relative one is relative to the
    directory git runs hooks from: the work tree root (the git dir when bare).
    That is the client-hook location; see receive_hooks_dir() for the other."""
    path = os.path.expanduser(value)
    return path if os.path.isabs(path) else os.path.join(toplevel, path)


def receive_hooks_dir(value, toplevel, git_dir):
    """Where the receive-side hooks (RECEIVE_HOOKS) are looked up for this
    core.hooksPath, or None when it is the same place as for client hooks.

    Those hooks run with $GIT_DIR as the working directory, so a relative
    path resolves from there; an absolute path (or a bare repository, where
    both are the git dir) has only one location.
    """
    if not git_dir or os.path.isabs(os.path.expanduser(value)):
        return None
    server = os.path.join(git_dir, os.path.expanduser(value))
    return None if server == resolve_hooks_path(value, toplevel) else server


def hooks_path_findings(value, origin, scope, toplevel, local_hooks_present, exists_fn,
                        git_dir=None):
    """[(level, message, fix)] for core.hooksPath.

    local_hooks_present names the active hooks in the repository's own
    hooks directory, which a global or system hooksPath shadows. With git_dir
    a relative path is also resolved for the receive-side hooks, which run
    from there.
    """
    if not value:
        return []
    resolved = resolve_hooks_path(value, toplevel)
    server = receive_hooks_dir(value, toplevel, git_dir)
    where = origin or "an unnamed source"
    flag = "--%s " % scope if scope in ("global", "system") else ""
    if not exists_fn(resolved):
        which = " for client hooks (read from the work tree root)" if server else ""
        return [(
            "fail",
            "core.hooksPath=%s (set in %s) does not exist%s: git runs NO hooks and "
            "says nothing" % (value, where, which),
            "mkdir -p %s, or git config %s--unset core.hooksPath"
            % (shlex.quote(resolved), flag),
        )]
    if server and not exists_fn(server):
        return [(
            "info",
            "core.hooksPath=%s is relative, so the receive-side hooks (%s) are read "
            "from $GIT_DIR, %s, which does not exist: none of them runs when this "
            "repository is a push target" % (value, ", ".join(sorted(RECEIVE_HOOKS)),
                                             server),
            "mkdir -p %s, if this repository receives pushes" % shlex.quote(server),
        )]
    if scope in ("global", "system") and local_hooks_present:
        return [(
            "warn",
            "core.hooksPath is set %sly (in %s), so %d hook(s) in this repository's "
            ".git/hooks never run: %s" % (scope, where, len(local_hooks_present),
                                           ", ".join(sorted(local_hooks_present))),
            "git config --local core.hooksPath .git/hooks, if this repository's own "
            "hooks should run",
        )]
    return []


PRE_COMMIT_MARKER = "# File generated by pre-commit: https://pre-commit.com"


def _is_pre_commit_hook(text):
    """True for a hook script the pre-commit framework wrote: its marker line
    (compared whole, on stripped lines) or its `-m pre_commit` entry point."""
    for line in text.splitlines():
        line = line.strip()
        if line == PRE_COMMIT_MARKER or "pre_commit" in line:
            return True
    return False


def framework_findings(toplevel_files, hooks_path_value, hook_texts):
    """[(level, message, fix)] for hook managers a repository commits but nobody
    activated. toplevel_files names the entries at the work tree root,
    hook_texts maps each active, executable hook to the start of its text."""
    findings = []
    texts = list(hook_texts.values())
    hooks_path = (hooks_path_value or "").rstrip("/")

    if ".pre-commit-config.yaml" in toplevel_files and not any(
            _is_pre_commit_hook(t) for t in texts):
        findings.append(("warn", ".pre-commit-config.yaml is committed but the "
                                 "pre-commit framework is not installed in this clone",
                         "pre-commit install"))
        if hooks_path:
            findings.append(("info", "pre-commit refuses to install while "
                                     "core.hooksPath is set: git config --unset-all "
                                     "core.hooksPath first", None))
    if ".husky" in toplevel_files and hooks_path not in (".husky", ".husky/_"):
        findings.append(("warn", ".husky/ is committed but core.hooksPath does not "
                                 "point at it, so its hooks never run",
                         "run the project install step (npm install triggers husky), "
                         "or git config core.hooksPath .husky/_"))
    if ".githooks" in toplevel_files and not hooks_path:
        findings.append(("warn", ".githooks/ is committed but core.hooksPath is unset, "
                                 "so tracked hooks are not active",
                         "git config core.hooksPath .githooks"))
    lefthook = {"lefthook.yml", "lefthook.yaml", ".lefthook.yml", ".lefthook.yaml"}
    if lefthook & set(toplevel_files) and not any("lefthook" in t for t in texts):
        findings.append(("warn", "a lefthook config is committed but lefthook is not "
                                 "installed in this clone", "lefthook install"))
    return findings


# --------------------------------------------------------------------------
# The impure edge: git and the hooks directory.
# --------------------------------------------------------------------------
def git_path(*args):
    rc, out, _ = run(["git", "rev-parse", *args])
    if rc != 0 or not out.strip():
        return None
    return os.path.abspath(out.strip())


def hooks_path_config():
    """(value, origin, scope) of the effective core.hooksPath, or empties.

    --show-scope needs git 2.26; an older git answers without it.
    """
    rc, out, _ = run(["git", "config", "--show-origin", "--show-scope", "--get",
                      "core.hooksPath"])
    if rc == 0 and out.strip():
        fields = out.rstrip("\n").split("\t", 2)
        if len(fields) == 3:
            scope, origin, value = fields
            return value, shorten(origin[len("file:"):] if origin.startswith("file:")
                                  else origin), scope
    if rc not in (0, 1):
        rc, out, _ = run(["git", "config", "--show-origin", "--get", "core.hooksPath"])
        if rc == 0 and "\t" in out:
            origin, value = out.rstrip("\n").split("\t", 1)
            return value, shorten(origin[len("file:"):] if origin.startswith("file:")
                                  else origin), ""
    return "", "", ""


def read_start(path, limit):
    try:
        if os.path.getsize(path) > READ_LIMIT:
            return None
        with open(path, "rb") as handle:
            return handle.read(limit)
    except OSError:
        return None


def scan_hooks(directory):
    """(samples, hooks, others) in a hooks directory.

    hooks are (name, path) for files named like a hook, others the rest,
    *.sample files only counted.
    """
    samples = 0
    hooks = []
    others = []
    try:
        entries = sorted(os.scandir(directory), key=lambda e: e.name)
    except OSError:
        return 0, [], []
    for entry in entries:
        try:
            if not entry.is_file():
                continue
        except OSError:
            continue
        if entry.name.endswith(".sample"):
            samples += 1
        elif entry.name in HOOK_NAMES:
            hooks.append((entry.name, entry.path))
        else:
            others.append((entry.name, entry.path))
    return samples, hooks, others


def report_level(level, message, fix):
    if level == "fail":
        bad(message)
    elif level == "warn":
        warn(message)
    else:
        info(message)
    if fix:
        info("fix: %s" % fix)
    return 1 if level == "fail" else 0


def run_report(args):
    git_dir = git_path("--absolute-git-dir")
    if git_dir is None:
        bad("not inside a Git repository")
        return 2
    common_dir = git_path("--git-common-dir") or git_dir
    rc, out, _ = run(["git", "rev-parse", "--show-toplevel"])
    toplevel = out.strip() if rc == 0 and out.strip() else git_dir
    default_dir = os.path.join(common_dir, "hooks")
    value, origin, scope = hooks_path_config()
    active_dir = resolve_hooks_path(value, toplevel) if value else default_dir
    path_env = os.environ.get("PATH", "")

    try:
        toplevel_files = set(os.listdir(toplevel))
    except OSError:
        toplevel_files = set()
    samples, hooks, others = scan_hooks(active_dir)
    frameworks_present = toplevel_files & {
        ".pre-commit-config.yaml", ".husky", ".githooks", "lefthook.yml",
        "lefthook.yaml", ".lefthook.yml", ".lefthook.yaml"}

    if not value and not hooks and not others and not frameworks_present:
        head("hooks")
        info("no active hooks (%d sample hook(s), none active)" % samples)
        return 4

    problems = 0
    head("hooks directory")
    if value:
        info("core.hooksPath=%s (%s%s) -> %s"
             % (value, origin or "an unnamed source", ", " + scope if scope else "",
                shorten(active_dir)))
    else:
        info("core.hooksPath unset; hooks run from %s" % shorten(default_dir))
    local_present = []
    if value and os.path.realpath(active_dir) != os.path.realpath(default_dir):
        _, local_hooks, _ = scan_hooks(default_dir)
        local_present = [n for n, p in local_hooks if os.access(p, os.X_OK)]
    server_dir = receive_hooks_dir(value, toplevel, git_dir) if value else None
    if server_dir:
        info("relative path: client hooks are read from the work tree root, "
             "receive-side hooks (pre-receive, update, ...) from $GIT_DIR -> %s"
             % shorten(server_dir))
    findings = hooks_path_findings(value, origin, scope, toplevel, local_present,
                                   os.path.isdir, git_dir)
    for finding in findings:
        problems += report_level(*finding)
    if not findings and value:
        ok("%s exists" % shorten(active_dir))

    head("hooks")
    hook_texts = {}
    checked = [(name, path, name) for name, path in hooks]
    if server_dir:
        # A receive-side hook next to the client ones is not run from there
        # in a push target; the copy under $GIT_DIR is the one that runs.
        for name, path in hooks:
            if name in RECEIVE_HOOKS:
                info("%s in %s runs for local ref updates only: a push into this "
                     "repository looks in %s" % (name, shorten(active_dir),
                                                 shorten(server_dir)))
        _, server_hooks, _ = scan_hooks(server_dir)
        checked += [(name, path, "%s (receive-side, in %s)" % (name, shorten(server_dir)))
                    for name, path in server_hooks if name in RECEIVE_HOOKS]
    for hook, path, name in checked:
        if not os.access(path, os.X_OK):
            problems += report_level(
                "fail", "%s is not executable: git ignores it" % name,
                "chmod +x %s" % shlex.quote(path))
            continue
        start = read_start(path, TEXT_LIMIT)
        if start is None:
            info("%s is not readable or over 1 MiB; its first line was not checked" % name)
            continue
        first = start.split(b"\n", 1)[0] + (b"\n" if b"\n" in start else b"")
        if b"\0" in first:
            info("%s is a binary; nothing to check in its first line" % name)
            continue
        if name == hook:
            hook_texts[hook] = start.decode("utf-8", "replace")
        shebang = shebang_findings(first, lambda p: find_program(p, path_env), path)
        for finding in shebang:
            problems += report_level(finding[0], "%s: %s" % (name, finding[1]), finding[2])
        if not shebang:
            ok("%s is executable and its interpreter resolves" % name)
    for name, _ in others:
        meant = near_miss(name)
        if meant is None:
            continue
        if name.lower().endswith(DISABLED_SUFFIXES):
            info("%s does not run; it looks like a disabled copy of %s" % (name, meant))
        else:
            report_level("warn", "%s is not a hook name, so git never runs it; did you "
                                 "mean %s" % (name, meant), None)
    if samples:
        info("%d sample hook(s) ignored, as git ignores them" % samples)
    if not hooks:
        info("no file in %s carries a hook name" % shorten(active_dir))

    head("frameworks")
    findings = framework_findings(toplevel_files, value, hook_texts)
    for finding in findings:
        problems += report_level(*finding)
    if not findings:
        if frameworks_present:
            ok("%s active" % ", ".join(sorted(frameworks_present)))
        else:
            info("no hook manager configured in this repository")

    print()
    if problems:
        bad("%d problem(s) found" % problems)
        return 1
    ok("no hook problems found")
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
        description="Diagnose why git hooks do not run: hooksPath, exec bits, CRLF "
                    "shebangs, misnamed hooks and unactivated hook managers.",
        epilog="Exit codes: 0 no fail-level finding, 1 a fail-level finding, 2 not "
               "inside a Git repository, 3 usage, 4 no hooks to diagnose.",
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

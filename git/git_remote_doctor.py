#!/usr/bin/env python3
"""Diagnose why a remote pushes somewhere unexpected, or asks for a password.

git_ssh_doctor.py answers "why is this key refused" and git_signing_doctor.py
answers "why will this not sign". Between them sits the layer neither looks at:
the URL git actually dials, and how it finds a password when that URL is HTTP.
Three things rewrite or resolve that, none of them visible in `git remote -v`:

  the URL itself      a fetch URL over ssh and a push URL over https is why a
                      pull is silent and a push prompts. `git://` cannot carry
                      a push at all, and in scp-like syntax the part after the
                      colon is a path, not a port — `git@host:2222/o/r.git`
                      asks for a repository called `2222/o/r.git`.
  insteadOf           `git remote -v` prints what is in .git/config, not what
                      git dials. A url.<base>.insteadOf rewrite can send every
                      fetch to a mirror, and the only sign of it is that the
                      output of a clone does not match the URL you typed.
  credential helpers  multi-valued and accumulating across scopes, unlike
                      almost every other key — and an empty value resets the
                      list, which is how one line in a repository's config
                      silently disables the keychain helper set globally.

Read-only. It prints commands to run; it never edits config, contacts a remote,
or reads the contents of a credential file.

    ./git_remote_doctor.py                 # diagnose this repository's remotes
    ./git_remote_doctor.py --remote origin
    ./git_remote_doctor.py --url https://github.com/owner/repo.git
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
import re
import stat
import subprocess
import sys

HOME = os.path.expanduser("~")

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
# Pure helpers. Everything below this line takes its input as a string and
# returns data, so it can be unit-tested without a repository, a network or a
# credential store. The parts that shell out are left untested, because mocking
# them would only assert that the mock was called.
# --------------------------------------------------------------------------


def normalise_key(key):
    """Lower-case a config key the way git compares them.

    Section and variable are case-insensitive; the subsection in the middle is
    not. `url.https://Example.COM/.insteadOf` and `remote.Upstream.url` keep
    the case they were written with, because that string is a remote name or a
    URL prefix and lower-casing it would report something that does not exist.
    """
    parts = key.split(".")
    if len(parts) <= 2:
        return key.lower()
    return "%s.%s.%s" % (parts[0].lower(), ".".join(parts[1:-1]), parts[-1].lower())


def parse_git_config(text):
    """Parse `git config --list --show-origin --show-scope -z` output.

    Returns {key: [(value, origin, scope), ...]} in file order. Order matters
    twice over here: for ordinary keys the last entry wins, and for
    credential.helper every entry applies, in sequence.
    """
    entries = {}
    if not text:
        return entries

    tokens = text.split("\0")
    # Records are scope NUL origin NUL "key\nvalue". A trailing empty token is
    # normal because the final record is NUL-terminated too.
    i = 0
    while i + 2 < len(tokens) + 1:
        chunk = tokens[i : i + 3]
        if len(chunk) < 3:
            break
        scope, origin, keyval = chunk
        if not keyval:
            break
        if "\n" in keyval:
            key, value = keyval.split("\n", 1)
        else:
            key, value = keyval, ""
        entries.setdefault(normalise_key(key), []).append((value, origin, scope))
        i += 3
    return entries


def effective(entries, key):
    """The winning (value, origin, scope) for a key, or None."""
    values = entries.get(normalise_key(key))
    return values[-1] if values else None


_SCHEME_KIND = {
    "ssh": "ssh",
    "git+ssh": "ssh",
    "https": "https",
    "http": "http",
    "git": "git",
    "file": "file",
}


def parse_url(url):
    """Split a git remote URL into its parts and say which transport it names.

    kind is one of ssh, scp, https, http, git, file, local or unknown. scp is
    kept distinct from ssh deliberately: the two reach the same daemon but
    disagree about what follows a colon, which is the whole point of the port
    check below.
    """
    raw = (url or "").strip()
    parts = {
        "url": raw,
        "kind": "unknown",
        "scheme": "",
        "user": "",
        "host": "",
        "port": "",
        "path": "",
    }
    if not raw:
        return parts

    if "://" in raw:
        scheme, rest = raw.split("://", 1)
        scheme = scheme.lower()
        parts["scheme"] = scheme
        parts["kind"] = _SCHEME_KIND.get(scheme, "unknown")
        if scheme == "file":
            parts["path"] = rest
            return parts
        authority, _, path = rest.partition("/")
        if "@" in authority:
            parts["user"], _, authority = authority.rpartition("@")
        if authority.startswith("["):
            host, _, tail = authority[1:].partition("]")
            parts["host"] = host
            if tail.startswith(":"):
                parts["port"] = tail[1:]
        elif ":" in authority:
            parts["host"], _, parts["port"] = authority.partition(":")
        else:
            parts["host"] = authority
        parts["path"] = path
        return parts

    # scp-like: [user@]host:path. A leading slash, a dot or no colon at all
    # means a path on this machine.
    if ":" in raw and not raw.startswith(("/", ".", "~")):
        left, _, path = raw.partition(":")
        if "@" in left:
            parts["user"], _, left = left.rpartition("@")
        parts["kind"] = "scp"
        parts["host"] = left
        parts["path"] = path
        return parts

    parts["kind"] = "local"
    parts["path"] = raw
    return parts


def redact_url(url):
    """Blank the password out of a URL before it is printed.

    `https://x-access-token:ghp_…@github.com/` is an ordinary thing to find in
    a rewrite base or a remote URL — CI writes exactly that — and a diagnostic
    whose output people paste into an issue must not be the thing that leaks
    it. The half after the colon always goes. A userinfo with no colon is
    usually a username and is kept, unless it is long enough that it can only
    be a token.
    """
    raw = url or ""
    if "://" not in raw:
        return raw
    scheme, rest = raw.split("://", 1)
    authority, sep, tail = rest.partition("/")
    if "@" not in authority:
        return raw

    userinfo, _, hostport = authority.rpartition("@")
    if ":" in userinfo:
        user, _, _ = userinfo.partition(":")
        userinfo = user + ":***"
    elif len(userinfo) >= 20:
        userinfo = "***"
    return "%s://%s@%s%s%s" % (scheme, userinfo, hostport, sep, tail)


def redact_helper(value):
    """Blank credential-like tokens out of a credential.helper value.

    Shell helpers (`!f() { echo password=…; }; f`) are ordinary in CI and in
    personal configs. Printing the body verbatim is how a "read-only doctor"
    becomes the thing that pastes a secret into an issue.
    """
    raw = value or ""
    if not raw.startswith("!"):
        return raw
    redacted = re.sub(
        r"(?i)\b(password|token|secret|authorization)=(\S+)",
        r"\1=***",
        raw,
    )
    if redacted != raw:
        return redacted
    # No named key matched, but the body may still embed a long token-like
    # string. Collapse long shell helpers to a short marker rather than print
    # the whole command.
    if len(raw) > 48:
        return "!<shell credential helper>"
    return raw


def url_problems(parts):
    """Problems visible in a single URL, as (level, message, fix) tuples."""
    found = []
    kind = parts["kind"]

    if kind == "git":
        found.append((
            "fail",
            "git:// is unauthenticated, unencrypted and read-only",
            "a push over it can never succeed; use https:// or ssh",
        ))
    elif kind == "http":
        found.append((
            "warn",
            "http:// sends any credential over the network in the clear",
            "change the URL to https://",
        ))
    elif kind == "unknown":
        found.append((
            "fail",
            "cannot tell what transport %r names" % redact_url(parts["url"]),
            "expected ssh://, https://, git@host:path or a local path",
        ))

    if kind in ("ssh", "scp", "https", "http", "git") and not parts["host"]:
        found.append(
            ("fail", "no host in %r" % redact_url(parts["url"]), "check the URL")
        )

    # The classic one. In scp-like syntax everything after the colon is the
    # path, so a port written there becomes the first directory of a repository
    # name — and the error says the repository does not exist, which is true.
    if kind == "scp":
        first = parts["path"].split("/", 1)[0]
        if first.isdigit():
            found.append((
                "fail",
                "%r is a path beginning %s, not port %s"
                % (redact_url(parts["url"]), first, first),
                "a port needs the URL form: ssh://%s%s:%s/%s"
                % (
                    parts["user"] + "@" if parts["user"] else "",
                    parts["host"],
                    first,
                    parts["path"].split("/", 1)[1] if "/" in parts["path"] else "",
                ),
            ))

    return found


def collect_remotes(entries):
    """{name: {'fetch': [url...], 'push': [url...]}} from parsed git config.

    A remote with no pushurl pushes to its fetch URL, and that substitution is
    made here so the caller never has to remember it.
    """
    remotes = {}
    for key, values in entries.items():
        if not key.startswith("remote.") or key.count(".") < 2:
            continue
        name = key[len("remote.") : key.rindex(".")]
        field = key[key.rindex(".") + 1 :]
        if field not in ("url", "pushurl"):
            continue
        slot = "fetch" if field == "url" else "push"
        entry = remotes.setdefault(name, {"fetch": [], "push": []})
        for value, _, _ in values:
            entry[slot].append(value)
    for entry in remotes.values():
        if not entry["push"]:
            entry["push"] = list(entry["fetch"])
    return remotes


def collect_rewrites(entries):
    """[(base, pattern, kind)] for every url.<base>.insteadOf / pushInsteadOf."""
    rewrites = []
    for key, values in entries.items():
        if not key.startswith("url.") or key.count(".") < 2:
            continue
        base = key[len("url.") : key.rindex(".")]
        field = key[key.rindex(".") + 1 :]
        if field == "insteadof":
            kind = "insteadOf"
        elif field == "pushinsteadof":
            kind = "pushInsteadOf"
        else:
            continue
        for value, _, _ in values:
            if value:
                rewrites.append((base, value, kind))
    return rewrites


def _longest_match(url, candidates):
    """Apply the longest matching prefix rewrite. Returns (url, pattern, base)."""
    best = None
    for base, pattern, _ in candidates:
        if url.startswith(pattern) and (best is None or len(pattern) > len(best[1])):
            best = (base, pattern)
    if best is None:
        return url, None, None
    base, pattern = best
    return base + url[len(pattern) :], pattern, base


def apply_rewrites(url, rewrites, push=False):
    """The URL git will dial, and the insteadOf pattern that produced it.

    Longest match wins, exactly as git does it. For a push, pushInsteadOf is
    consulted first and insteadOf is the fallback — which means a repository
    can fetch from one host and push to another with no remote.pushurl set
    anywhere, and nothing in `git remote -v` hinting at it.
    """
    if push:
        rewritten, pattern, base = _longest_match(
            url, [r for r in rewrites if r[2] == "pushInsteadOf"]
        )
        if pattern is not None:
            return rewritten, pattern, base
    return _longest_match(url, [r for r in rewrites if r[2] == "insteadOf"])


def credential_helpers(entries, key="credential.helper"):
    """(helpers, resets) for a multi-valued credential.helper.

    Every configured value applies, in the order git read them, which is not
    how any other key in this file behaves. An empty value discards everything
    configured before it — the documented way to ignore a system-wide helper,
    and the undocumented way to lose your keychain by copying a config snippet.
    """
    helpers = []
    resets = []
    for value, origin, scope in entries.get(key.lower(), []):
        if value.strip() == "":
            resets.append((origin, scope, len(helpers)))
            helpers = []
        else:
            helpers.append((value, origin, scope))
    return helpers, resets


def find_program(name, path_env, exec_path=""):
    """Resolve a program against injected PATH and git exec-path strings.

    git's own helpers live in the exec path (/usr/lib/git-core and friends),
    which is not on PATH. Looking only at PATH would report git-credential-store
    as missing on almost every machine, which is exactly the false alarm a
    diagnostic must not produce.
    """
    if not name:
        return None
    if os.path.sep in name:
        return name if os.path.isfile(name) and os.access(name, os.X_OK) else None
    directories = [d for d in (path_env or "").split(os.pathsep) if d]
    if exec_path:
        directories = [exec_path, *directories]
    for directory in directories:
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def classify_helper(value, path_env, exec_path=""):
    """(kind, resolved_path, problem) for one credential.helper value.

    kind is 'shell', 'path' or 'name'. A shell helper is a command git runs
    through /bin/sh; there is nothing to resolve and nothing to check.
    """
    value = (value or "").strip()
    if not value:
        return "empty", None, None
    if value.startswith("!"):
        return "shell", None, None

    # git splits arguments off and runs `git credential-<first token>`.
    first = value.split()[0]

    if os.path.sep in first:
        resolved = find_program(first, path_env, exec_path)
        if resolved is None:
            return "path", None, "%s is not an executable file" % first
        return "path", resolved, None

    program = "git-credential-" + first
    resolved = find_program(program, path_env, exec_path)
    if resolved is None:
        return "name", None, (
            "%s is not on PATH or in git's exec path, so this helper never runs"
            % program
        )
    return "name", resolved, None


def credential_file_problem(path):
    """A world- or group-readable credential store is a finding, not a detail."""
    try:
        mode = os.stat(path).st_mode
    except OSError:
        return None
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        return oct(stat.S_IMODE(mode))
    return None


def needs_credentials(url_kinds):
    """Do any of these URL kinds go through a credential helper?"""
    return any(kind in ("https", "http") for kind in url_kinds)


# --------------------------------------------------------------------------
# Diagnostics
# --------------------------------------------------------------------------


def read_config():
    rc, out, _ = run(["git", "config", "--list", "--show-origin", "--show-scope", "-z"])
    if rc != 0:
        return None
    return parse_git_config(out)


def git_exec_path():
    rc, out, _ = run(["git", "--exec-path"])
    return out.strip() if rc == 0 else ""


def report_url(label, url, rewrites, push):
    """Print one URL, its rewrite and its problems. Returns the problem count."""
    parts = parse_url(url)
    dialled, pattern, base = apply_rewrites(url, rewrites, push=push)
    print("        %-6s %s" % (label, redact_url(url)))

    if pattern is not None:
        kind = "pushInsteadOf" if push and _matched_push(url, rewrites) else "insteadOf"
        print("        %-6s %s  %s(rewritten by url.%s.%s = %s)%s"
              % ("dials", redact_url(dialled), C_DIM, redact_url(base), kind,
                 redact_url(pattern), C_RESET))
        # Everything below judges the URL git will actually dial, not the one
        # in the config file. Judging the latter is how a rewrite hides a
        # problem instead of causing one.
        parts = parse_url(dialled)

    problems = 0
    for level, message, fix in url_problems(parts):
        if level == "fail":
            bad(message)
            problems += 1
        else:
            warn(message)
        info("fix: %s" % fix)
    return problems


def _matched_push(url, rewrites):
    _, pattern, _ = _longest_match(url, [r for r in rewrites if r[2] == "pushInsteadOf"])
    return pattern is not None


def diagnose_remotes(remotes, rewrites, wanted):
    """Report each remote. Returns (problems, dialled URL parts)."""
    head("remotes")
    problems = 0
    dialled_parts = []

    names = sorted(remotes)
    if wanted:
        names = [n for n in names if n in wanted]
        for missing in sorted(set(wanted) - set(remotes)):
            bad("no remote named %s" % missing)
            problems += 1

    for name in names:
        entry = remotes[name]
        print("  %s%s%s" % (C_BOLD, name, C_RESET))
        for url in entry["fetch"]:
            problems += report_url("fetch", url, rewrites, push=False)
            dialled_parts.append(parse_url(apply_rewrites(url, rewrites)[0]))
        for url in entry["push"]:
            problems += report_url("push", url, rewrites, push=True)
            dialled_parts.append(
                parse_url(apply_rewrites(url, rewrites, push=True)[0])
            )

        fetch_kinds = {parse_url(apply_rewrites(u, rewrites)[0])["kind"]
                       for u in entry["fetch"]}
        push_kinds = {parse_url(apply_rewrites(u, rewrites, push=True)[0])["kind"]
                      for u in entry["push"]}
        if fetch_kinds and push_kinds and fetch_kinds != push_kinds:
            warn("%s fetches over %s and pushes over %s"
                 % (name, "/".join(sorted(fetch_kinds)), "/".join(sorted(push_kinds))))
            info("the two use different credentials, which is why only one of "
                 "them prompts")

    return problems, dialled_parts


def diagnose_cross_remote(remotes, rewrites):
    """One host reached two ways is two sets of credentials to keep working."""
    by_host = {}
    for name, entry in remotes.items():
        for url in entry["fetch"] + entry["push"]:
            parts = parse_url(apply_rewrites(url, rewrites)[0])
            if not parts["host"]:
                continue
            kind = "ssh" if parts["kind"] in ("ssh", "scp") else parts["kind"]
            by_host.setdefault(parts["host"], set()).add((kind, name))

    for host in sorted(by_host):
        kinds = {kind for kind, _ in by_host[host]}
        if len(kinds) > 1:
            names = sorted({name for _, name in by_host[host]})
            warn("%s is reached over %s by remote(s) %s"
                 % (host, " and ".join(sorted(kinds)), ", ".join(names)))
            info("each transport authenticates differently, so both have to be "
                 "kept working")


def diagnose_rewrites(rewrites):
    head("url rewrites")
    if not rewrites:
        info("no url.*.insteadOf rewrites configured")
        return 0

    problems = 0
    for base, pattern, kind in sorted(rewrites, key=lambda r: (r[2], r[1])):
        print("        %-13s %s  ->  %s" % (kind, redact_url(pattern), redact_url(base)))

    # git rewrites once. A base that is itself matched by another pattern looks
    # like a chain and behaves like a dead end.
    for base, pattern, kind in rewrites:
        rewritten, second, _ = _longest_match(
            base, [r for r in rewrites if r[2] == kind and r[1] != pattern]
        )
        if second is not None:
            warn("url.%s.%s = %s produces a URL that %s also matches"
                 % (redact_url(base), kind, redact_url(pattern), redact_url(second)))
            info("git applies one rewrite, not a chain: the result stays %s "
                 "rather than becoming %s" % (redact_url(base), redact_url(rewritten)))
            problems += 1

    seen = {}
    for base, pattern, kind in rewrites:
        previous = seen.get((pattern, kind))
        if previous is not None and previous != base:
            bad("%s is claimed by both url.%s and url.%s"
                % (redact_url(pattern), redact_url(previous), redact_url(base)))
            info("only one of them can apply; remove the one you did not mean")
            problems += 1
        seen[(pattern, kind)] = base

    return problems


def diagnose_credentials(entries, dialled_parts, path_env, exec_path):
    head("credential helpers")
    problems = 0

    helpers, resets = credential_helpers(entries)
    http_urls = [p for p in dialled_parts if p["kind"] in ("https", "http")]

    for origin, scope, discarded in resets:
        if discarded:
            warn("an empty credential.helper in %s (%s) discards the %d helper(s) "
                 "configured before it" % (shorten(origin.replace("file:", "")),
                                           scope, discarded))
        else:
            info("an empty credential.helper in %s (%s) resets the list"
                 % (shorten(origin.replace("file:", "")), scope))

    if not helpers:
        if http_urls:
            bad("no credential helper configured, and %d URL(s) here are HTTP"
                % len(http_urls))
            info("every fetch and push will prompt, and fail outright where "
                 "nothing can prompt — a hook, an editor, CI")
            if sys.platform == "darwin":
                info("fix: git config --global credential.helper osxkeychain")
            elif sys.platform.startswith("win"):
                info("fix: git config --global credential.helper manager")
            else:
                info("fix: git config --global credential.helper libsecret")
                info("credential.helper store keeps passwords in a plaintext "
                     "file under ~/.git-credentials — prefer a keyring helper")
            problems += 1
        else:
            info("no credential helper configured; no HTTP remote needs one")
        return problems

    for value, origin, scope in helpers:
        kind, resolved, problem = classify_helper(value, path_env, exec_path)
        origin = shorten(origin.replace("file:", ""))
        shown = redact_helper(value)
        print("        %-24s %s(%s, %s)%s" % (shown, C_DIM, scope, origin, C_RESET))
        if problem:
            bad(problem)
            info("this is what a keychain helper copied between an old machine "
                 "and a new one looks like")
            problems += 1
        elif kind == "shell":
            info("a shell command, run through /bin/sh; nothing here to resolve")
        elif resolved:
            ok("resolves to %s" % shorten(resolved))

        if value.split()[0] == "store":
            for path in (os.path.join(HOME, ".git-credentials"),
                         os.path.join(os.environ.get("XDG_CONFIG_HOME",
                                                     os.path.join(HOME, ".config")),
                                      "git", "credentials")):
                mode = credential_file_problem(path)
                if mode:
                    bad("%s is mode %s — it holds passwords in clear text"
                        % (shorten(path), mode))
                    info("fix: chmod 600 %s" % shorten(path))
                    problems += 1

    if helpers and not http_urls:
        info("no HTTP remote here, so none of these helpers is consulted; ssh "
             "authentication is git_ssh_doctor.py's department")

    scoped = sorted(k for k in entries
                    if k.startswith("credential.") and k.endswith(".helper")
                    and k != "credential.helper")
    for key in scoped:
        # Looked up directly rather than through effective(): the middle of
        # this key is a URL, and a URL is case-sensitive.
        value = entries[key][-1][0]
        url = key[len("credential."):-len(".helper")]
        info("credential.%s.helper = %s applies only to URLs under %s"
             % (redact_url(url), redact_helper(value), redact_url(url)))

    return problems


def run_report(args):
    entries = read_config()
    if entries is None:
        bad("git config failed — is git installed?")
        return 2

    rewrites = collect_rewrites(entries)
    remotes = collect_remotes(entries)

    problems = 0
    dialled_parts = []

    if remotes:
        remote_problems, dialled_parts = diagnose_remotes(remotes, rewrites, args.remote)
        problems += remote_problems
        diagnose_cross_remote(remotes, rewrites)
    elif not args.url:
        head("remotes")
        warn("no remotes configured here and no --url given")
        info("run this inside a repository with a remote, or pass "
             "--url https://host/owner/repo.git")
        diagnose_rewrites(rewrites)
        return 4

    if args.url:
        head("urls")
        for url in args.url:
            print("  %s%s%s" % (C_BOLD, redact_url(url), C_RESET))
            problems += report_url("fetch", url, rewrites, push=False)
            dialled_parts.append(parse_url(apply_rewrites(url, rewrites)[0]))

    problems += diagnose_rewrites(rewrites)
    problems += diagnose_credentials(
        entries, dialled_parts, os.environ.get("PATH", ""), git_exec_path()
    )

    print()
    if problems:
        bad("%d problem(s) found" % problems)
        return 1
    ok("no remote, rewrite or credential problems found")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Diagnose git remote URLs, insteadOf rewrites and credential helpers."
    )
    parser.add_argument("--remote", action="append", default=[],
                        help="remote to check (repeatable); defaults to all of them")
    parser.add_argument("--url", action="append", default=[],
                        help="diagnose an arbitrary URL (repeatable), no repository needed")
    parser.add_argument("--quiet", action="store_true",
                        help="print nothing; communicate the verdict through the exit code")
    args = parser.parse_args(argv)

    if args.quiet:
        with contextlib.redirect_stdout(io.StringIO()):
            return run_report(args)
    return run_report(args)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Diagnose why git-over-SSH authentication fails, and say how to fix it.

`Permission denied (publickey)` tells you nothing about which of the half-dozen
things involved actually went wrong: the key may not exist, may not be offered,
may not be loaded into the agent, may have permissions ssh refuses to use, or
may simply never be reached because the config file declaring it was never read.

Effective configuration comes from `ssh -G`, which is OpenSSH resolving its own
config — reimplementing that parser would only introduce a second opinion. This
script adds what `ssh -G` cannot tell you: *why* a key you believe you
configured is absent from the result, and whether the host key a headless run
will be shown is already trusted. The most common cause, and the one that
prompted this script, is an Include whose glob matches directories. ssh skips
those silently, so a config file one level deeper is never read and no error is
ever printed.

Read-only. It prints commands to run; it never edits config, touches the agent,
or writes a key.

    ./git_ssh_doctor.py                 # diagnose remotes of the current repo
    ./git_ssh_doctor.py --host github.com
    ./git_ssh_doctor.py --test-auth     # also try candidate keys against the host
    ./git_ssh_doctor.py --require-known-host   # CI: an unknown host key fails
    ./git_ssh_doctor.py --json          # the same verdict as one JSON object
"""

from __future__ import annotations

import argparse
import contextlib
import glob
import io
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys

HOME = os.path.expanduser("~")
SSH_DIR = os.path.join(HOME, ".ssh")

# Filenames under ~/.ssh that are never private keys.
_NOT_KEYS = {
    "config",
    "known_hosts",
    "known_hosts.old",
    "known_hosts2",
    "authorized_keys",
    "agent",
    "environment",
    "rc",
}
_KEY_HEADER = re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")

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


def run(cmd, timeout=15):
    """Run a command, returning (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode(
            "utf-8", "replace"
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 255, "", str(exc)


# --------------------------------------------------------------------------
# git remotes
# --------------------------------------------------------------------------
def git_remote_hosts():
    """SSH hosts used by the current repository's remotes, as {host: [urls]}."""
    rc, out, _ = run(["git", "remote", "-v"])
    if rc != 0:
        return {}
    hosts = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        url = parts[1]
        host = ssh_host_of(url)
        if host:
            hosts.setdefault(host, [])
            if url not in hosts[host]:
                hosts[host].append(url)
    return hosts


def ssh_host_of(url):
    """Extract the host from an SSH git URL, or None if it is not SSH."""
    if url.startswith("ssh://"):
        rest = url[len("ssh://") :]
        rest = rest.split("/", 1)[0]
        if "@" in rest:
            rest = rest.split("@", 1)[1]
        return rest.split(":", 1)[0] or None
    # scp-like: [user@]host:path — but not a local path or an https URL.
    if "://" in url:
        return None
    if ":" in url:
        left = url.split(":", 1)[0]
        if "@" in left:
            left = left.split("@", 1)[1]
        if left and not left.startswith("/") and not os.path.exists(url.split(":")[0]):
            return left
    return None


# --------------------------------------------------------------------------
# ssh config: Include analysis
# --------------------------------------------------------------------------
def parse_includes(path, depth=0, seen=None):
    """Return (loaded_files, problems) for an ssh config and everything it includes.

    problems is a list of (pattern, kind, detail) where kind is one of
    'directories', 'no-match'.
    """
    if seen is None:
        seen = set()
    loaded = []
    problems = []
    if depth > 8 or path in seen or not os.path.isfile(path):
        return loaded, problems
    seen.add(path)
    loaded.append(path)

    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return loaded, problems

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not stripped.lower().startswith("include"):
            continue
        parts = stripped.split(None, 1)
        if len(parts) < 2 or parts[0].lower() != "include":
            continue
        for pattern in parts[1].split():
            pattern = pattern.strip('"')
            expanded = os.path.expanduser(pattern)
            if not os.path.isabs(expanded):
                # OpenSSH resolves relative Include paths against ~/.ssh.
                expanded = os.path.join(SSH_DIR, expanded)
            matches = sorted(glob.glob(expanded))
            files = [m for m in matches if os.path.isfile(m)]
            dirs = [m for m in matches if os.path.isdir(m)]
            if not matches:
                problems.append((pattern, "no-match", expanded))
            elif dirs and not files:
                # The failure this script exists for. ssh does not descend into
                # a directory and does not complain about it either.
                problems.append((pattern, "directories", ", ".join(
                    os.path.basename(d) for d in dirs)))
            for f in files:
                sub_loaded, sub_problems = parse_includes(f, depth + 1, seen)
                loaded.extend(sub_loaded)
                problems.extend(sub_problems)
    return loaded, problems


# --------------------------------------------------------------------------
# keys
# --------------------------------------------------------------------------
def looks_like_private_key(path):
    try:
        if os.path.getsize(path) > 64 * 1024:
            return False
        with open(path, "rb") as fh:
            return bool(_KEY_HEADER.search(fh.read(4096)))
    except OSError:
        return False


def discover_keys(root=SSH_DIR):
    """Every private key under ~/.ssh, at any depth."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in sorted(filenames):
            if name.endswith(".pub") or name in _NOT_KEYS:
                continue
            path = os.path.join(dirpath, name)
            if looks_like_private_key(path):
                found.append(path)
    return found


def permissions_problem(path):
    """ssh refuses a private key that is group- or world-readable."""
    try:
        mode = os.stat(path).st_mode
    except OSError:
        return None
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        return oct(stat.S_IMODE(mode))
    return None


def agent_identities():
    rc, out, _ = run(["ssh-add", "-l"])
    if rc != 0:
        return []
    return [ln for ln in out.splitlines() if ln.strip()]


# --------------------------------------------------------------------------
# effective config per host
# --------------------------------------------------------------------------
# `ssh -G` keys whose value is a list. identityfile arrives one line per file;
# the known-hosts keys arrive as one line of space-separated paths.
_PATH_LIST_KEYS = ("userknownhostsfile", "globalknownhostsfile")


def _split_paths(value):
    try:
        return shlex.split(value)
    except ValueError:
        return value.split()


def parse_ssh_g(text):
    """Parse `ssh -G host` output into {key: value}.

    Keys are lower-cased and the first occurrence wins, as ssh's own does.
    identityfile collects every line in order; the known-hosts keys are split
    into their paths, a quoted path with a space staying one entry.
    """
    cfg = {"identityfile": []}
    for line in (text or "").splitlines():
        if " " not in line:
            continue
        key, value = line.split(" ", 1)
        key = key.lower()
        if not key:
            continue
        if key == "identityfile":
            cfg["identityfile"].append(value)
        elif key in _PATH_LIST_KEYS:
            cfg.setdefault(key, _split_paths(value))
        else:
            cfg.setdefault(key, value)
    return cfg


def known_hosts_spec(hostname, port, hostkeyalias=""):
    """The name `ssh-keygen -F` has to be asked for, as ssh writes it.

    A HostKeyAlias replaces the host outright. A non-default port is part of
    the name, `[host]:port`, and forgetting that makes every host on port
    2222 look unknown.
    """
    if hostkeyalias and hostkeyalias.lower() != "none":
        return hostkeyalias
    if str(port) in ("", "22"):
        return hostname
    return "[%s]:%s" % (hostname, port)


def normalise_strict(value):
    """StrictHostKeyChecking as one of yes, no, ask or accept-new.

    `ssh -G` prints true/false for yes/no, and the config also accepts off.
    """
    value = (value or "ask").strip().lower()
    if value in ("true", "yes"):
        return "yes"
    if value in ("false", "no", "off"):
        return "no"
    return value


def host_key_findings(host, port, strict, found_in, files_checked, hashed, require=False,
                      alias=""):
    """[(level, message, fix)] for one host's known_hosts state.

    host is the HostName ssh dials. Without `require` an unknown key is a
    warning, so nobody's exit code changes; with it (a CI preflight) it is a
    failure, under accept-new and StrictHostKeyChecking no as well, since
    those trust whatever key the first connection presents. With a
    HostKeyAlias the fix records the key under the alias, the name ssh looks up.
    """
    strict = normalise_strict(strict)
    port = str(port or "22")
    where = host if port == "22" else "%s port %s" % (host, port)
    findings = []
    if strict == "no":
        findings.append((
            "warn",
            "StrictHostKeyChecking is off for %s: the host key is never verified, so "
            "a man-in-the-middle is not detected" % where,
            "remove StrictHostKeyChecking no from the Host block and pin the key "
            "instead",
        ))
    if found_in:
        findings.append(("info", "host key present in %s" % ", ".join(found_in), None))
        if hashed:
            findings.append(("info", "stored hashed (HashKnownHosts), so the file "
                                     "does not name the host in clear", None))
        return findings
    checked = ", ".join(files_checked) or "any known_hosts file"
    if strict in ("no", "accept-new"):
        if not require:
            if strict == "accept-new":
                findings.append((
                    "info",
                    "host key for %s is not recorded; accept-new will record it on "
                    "first use, which is acceptable for a workstation, pin it for CI"
                    % where,
                    None,
                ))
            return findings
        message = ("host key for %s is not in %s: %s trusts whatever key the first "
                   "connection presents, so it is not pinned"
                   % (where, checked, "accept-new" if strict == "accept-new"
                      else "StrictHostKeyChecking no"))
    else:
        message = ("host key for %s is not in %s: the first connection stops to ask, "
                   "and a non-interactive run (CI, cron, BatchMode) fails with Host key "
                   "verification failed" % (where, checked))
    use_alias = bool(alias) and alias.lower() != "none"
    record = ("awk -v a=%s '{$1=a; print}' /tmp/hostkey" % shlex.quote(alias)
              if use_alias else "cat /tmp/hostkey")
    findings.append((
        "fail" if require else "warn",
        message,
        "ssh-keyscan -t ed25519 -p %s %s > /tmp/hostkey; ssh-keygen -lf /tmp/hostkey"
        "   # compare with the fingerprint the provider publishes, then: "
        "%s >> ~/.ssh/known_hosts" % (port, host, record),
    ))
    return findings


def effective_config(host):
    rc, out, err = run(["ssh", "-G", host])
    if rc != 0:
        return None, err
    return parse_ssh_g(out), ""


_DEFAULT_KNOWN_HOSTS = {
    "userknownhostsfile": ["~/.ssh/known_hosts", "~/.ssh/known_hosts2"],
    "globalknownhostsfile": ["/etc/ssh/ssh_known_hosts", "/etc/ssh/ssh_known_hosts2"],
}


def known_hosts_files(cfg):
    """Every known_hosts file ssh consults for this host, user files first."""
    files = []
    for key in ("userknownhostsfile", "globalknownhostsfile"):
        for path in cfg.get(key) or _DEFAULT_KNOWN_HOSTS[key]:
            if path.lower() != "none":
                files.append(os.path.expanduser(path))
    return files


def check_host_key(host, cfg, require):
    """Report whether this host's key is already trusted.

    Returns (passed, found). Only the file a key was found in is printed:
    `ssh-keygen -F` prints the matching known_hosts line itself, and that
    stays captured so no entry lands in a log.
    """
    hostname = cfg.get("hostname", host)
    port = cfg.get("port", "22")
    spec = known_hosts_spec(hostname, port, cfg.get("hostkeyalias", ""))
    if shutil.which("ssh-keygen") is None:
        info("ssh-keygen is not on PATH, so known_hosts cannot be checked")
        return True, True

    files = known_hosts_files(cfg)
    found_in = []
    hashed = False
    for path in [p for p in files if os.path.isfile(p)]:
        rc, out, _ = run(["ssh-keygen", "-F", spec, "-f", path])
        if rc == 0:
            found_in.append(shorten(path))
            hashed = hashed or any(line.startswith("|1|") for line in out.splitlines())
        elif rc != 1:
            info("ssh-keygen -F could not read %s (exit %d)" % (shorten(path), rc))

    passed = True
    for level, message, fix in host_key_findings(
        hostname, port, cfg.get("stricthostkeychecking", "ask"), found_in,
        [shorten(p) for p in files], hashed, require,
        cfg.get("hostkeyalias", ""),
    ):
        if level == "fail":
            bad(message)
            passed = False
        elif level == "warn":
            warn(message)
        else:
            info(message)
        if fix:
            info("fix: %s" % fix)
    return passed, bool(found_in)


def try_auth(host, user="git", key=None, timeout=20):
    """Attempt a non-interactive auth. Returns (authenticated, detail)."""
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o",
           "StrictHostKeyChecking=accept-new"]
    if key:
        cmd += ["-o", "IdentitiesOnly=yes", "-i", key]
    cmd += ["-T", "%s@%s" % (user, host)]
    rc, out, err = run(cmd, timeout=timeout)
    blob = (out + err).strip()
    if "Permission denied" in blob:
        return False, "permission denied"
    # GitHub and GitLab exit non-zero on a successful auth because they refuse
    # the shell, so the exit code alone cannot be the signal.
    for marker in ("successfully authenticated", "Welcome to GitLab",
                   "does not provide shell access", "logged in as"):
        if marker in blob:
            return True, blob.splitlines()[0][:100]
    if rc == 0:
        return True, blob.splitlines()[0][:100] if blob else "connected"
    return False, (blob.splitlines()[0][:100] if blob else "exit %d" % rc)


# --------------------------------------------------------------------------
def diagnose_host(host, keys, agent, test_auth, require_known_host=False):
    head("host: %s" % host)
    cfg, err = effective_config(host)
    if cfg is None:
        bad("ssh -G %s failed: %s" % (host, err.strip()[:200]))
        return False

    configured = [os.path.expanduser(p) for p in cfg.get("identityfile", [])]
    existing = [p for p in configured if os.path.exists(p)]

    info("resolves to %s@%s:%s" % (cfg.get("user", "?"), cfg.get("hostname", host),
                                   cfg.get("port", "22")))

    if not configured:
        warn("no identity files configured for this host")
    elif existing:
        for p in existing:
            ok("offers existing key: %s" % shorten(p))
    else:
        bad("ssh will offer %d identity file(s), none of which exist:" % len(configured))
        for p in configured:
            raw("        %s" % shorten(p))
        info("these are OpenSSH's built-in defaults — no Host block matched %s" % host)

    if agent:
        ok("ssh-agent holds %d identity(ies)" % len(agent))
    else:
        warn("ssh-agent holds no identities")

    # Before any authentication attempt: try_auth connects with
    # StrictHostKeyChecking=accept-new, which records an unknown key on its
    # first success, so checked afterwards this could never fire twice.
    trusted, found = check_host_key(host, cfg, require_known_host)
    if not trusted:
        info("authentication not attempted: it would record the unknown host key")
        return False

    if existing or agent:
        authed, detail = try_auth(host)
        if not found:
            info("note: --test-auth/auth probing records new host keys (accept-new); "
                 "this check ran first")
        if authed:
            ok("authentication succeeds: %s" % detail)
            return True
        bad("authentication fails: %s" % detail)
    else:
        bad("nothing to authenticate with: no existing configured key, empty agent")

    if not test_auth:
        info("re-run with --test-auth to find which of your %d key(s) this host accepts"
             % len(keys))
        return False

    head("testing %d discovered key(s) against %s" % (len(keys), host))
    winners = []
    for key in keys:
        authed, detail = try_auth(host, key=key)
        if authed:
            ok("%s -> %s" % (shorten(key), detail))
            winners.append(key)
        else:
            info("%s -> %s" % (shorten(key), detail))

    if winners:
        suggest_fix(host, winners[0])
    else:
        bad("none of the discovered keys authenticate to %s" % host)
        info("the key for this host may not be in ~/.ssh, or is not registered with "
             "the remote account")
    return bool(winners)


def suggest_fix(host, key):
    head("fix")
    raw("A key that authenticates exists but ssh never offers it. Either:\n")
    raw("  %s1. Declare it for this host%s" % (C_BOLD, C_RESET))
    raw("     Append to %s:\n" % os.path.join(SSH_DIR, "config"))
    raw("       Host %s" % host)
    raw("         HostName %s" % host)
    raw("         User git")
    raw("         IdentityFile %s" % key)
    raw("         IdentitiesOnly yes\n")
    raw("  %s2. Or load it into the agent%s" % (C_BOLD, C_RESET))
    raw("     ssh-add --apple-use-keychain %s\n" % key)
    raw("  %sVerify with%s  ssh -T git@%s" % (C_DIM, C_RESET, host))


def shorten(path):
    return path.replace(HOME, "~", 1) if path.startswith(HOME) else path


def run_report(args):
    head("ssh config")
    config_path = os.path.join(args.ssh_dir, "config")
    if not os.path.isfile(config_path):
        warn("no %s — only OpenSSH defaults apply" % shorten(config_path))
        loaded, problems = [], []
    else:
        loaded, problems = parse_includes(config_path)
        ok("loaded %d config file(s)" % len(loaded))
        for path in loaded:
            raw("        %s" % shorten(path))

    for pattern, kind, detail in problems:
        if kind == "directories":
            bad("Include %s matches only directories (%s)" % (pattern, detail))
            info("ssh does not descend into a directory and reports no error, so "
                 "every config file inside is silently ignored")
            info("fix: Include %s" % (pattern.rstrip("/") + "/*"))
        else:
            warn("Include %s matches nothing (%s)" % (pattern, shorten(detail)))

    head("keys")
    keys = discover_keys(args.ssh_dir)
    if keys:
        ok("found %d private key(s) under %s" % (len(keys), shorten(args.ssh_dir)))
        for key in keys:
            problem = permissions_problem(key)
            if problem:
                bad("%s has mode %s — ssh will refuse it (chmod 600)" %
                    (shorten(key), problem))
            else:
                raw("        %s" % shorten(key))
    else:
        warn("no private keys found under %s" % shorten(args.ssh_dir))

    agent = agent_identities()

    hosts = list(dict.fromkeys(args.host)) or sorted(git_remote_hosts())
    if not hosts:
        head("hosts")
        warn("no SSH remotes in this repository and no --host given")
        return 1

    results = [diagnose_host(h, keys, agent, args.test_auth, args.require_known_host)
               for h in hosts]
    return 0 if all(results) else 1


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
        description="Diagnose git-over-SSH authentication failures."
    )
    parser.add_argument("--host", action="append", default=[],
                        help="host to check (repeatable); defaults to this repo's remotes")
    parser.add_argument("--test-auth", action="store_true",
                        help="try each discovered key against the host")
    parser.add_argument("--require-known-host", action="store_true",
                        help="fail when the host key is not in known_hosts, even under "
                             "accept-new (CI preflight)")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--quiet", action="store_true",
                        help="print nothing; communicate the verdict through the exit code")
    output.add_argument("--json", action="store_true",
                        help="print one JSON object (exit code and every finding) "
                             "instead of the report")
    parser.add_argument("--ssh-dir", default=SSH_DIR, help=argparse.SUPPRESS)
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

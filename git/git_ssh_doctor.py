#!/usr/bin/env python3
"""Diagnose why git-over-SSH authentication fails, and say how to fix it.

`Permission denied (publickey)` tells you nothing about which of the half-dozen
things involved actually went wrong: the key may not exist, may not be offered,
may not be loaded into the agent, may have permissions ssh refuses to use, or
may simply never be reached because the config file declaring it was never read.

Effective configuration comes from `ssh -G`, which is OpenSSH resolving its own
config — reimplementing that parser would only introduce a second opinion. This
script adds what `ssh -G` cannot tell you: *why* a key you believe you
configured is absent from the result. The most common cause, and the one that
prompted this script, is an Include whose glob matches directories. ssh skips
those silently, so a config file one level deeper is never read and no error is
ever printed.

Read-only. It prints commands to run; it never edits config, touches the agent,
or writes a key.

    ./git_ssh_doctor.py                 # diagnose remotes of the current repo
    ./git_ssh_doctor.py --host github.com
    ./git_ssh_doctor.py --test-auth     # also try candidate keys against the host
"""

from __future__ import annotations

import argparse
import glob
import os
import re
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
def effective_config(host):
    rc, out, err = run(["ssh", "-G", host])
    if rc != 0:
        return None, err
    cfg = {"identityfile": []}
    for line in out.splitlines():
        if " " not in line:
            continue
        key, value = line.split(" ", 1)
        key = key.lower()
        if key == "identityfile":
            cfg["identityfile"].append(value)
        else:
            cfg.setdefault(key, value)
    return cfg, ""


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
def diagnose_host(host, keys, agent, test_auth):
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
            print("        %s" % shorten(p))
        info("these are OpenSSH's built-in defaults — no Host block matched %s" % host)

    if agent:
        ok("ssh-agent holds %d identity(ies)" % len(agent))
    else:
        warn("ssh-agent holds no identities")

    if existing or agent:
        authed, detail = try_auth(host)
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
    print("A key that authenticates exists but ssh never offers it. Either:\n")
    print("  %s1. Declare it for this host%s" % (C_BOLD, C_RESET))
    print("     Append to %s:\n" % os.path.join(SSH_DIR, "config"))
    print("       Host %s" % host)
    print("         HostName %s" % host)
    print("         User git")
    print("         IdentityFile %s" % key)
    print("         IdentitiesOnly yes\n")
    print("  %s2. Or load it into the agent%s" % (C_BOLD, C_RESET))
    print("     ssh-add --apple-use-keychain %s\n" % key)
    print("  %sVerify with%s  ssh -T git@%s" % (C_DIM, C_RESET, host))


def shorten(path):
    return path.replace(HOME, "~", 1) if path.startswith(HOME) else path


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Diagnose git-over-SSH authentication failures."
    )
    parser.add_argument("--host", action="append", default=[],
                        help="host to check (repeatable); defaults to this repo's remotes")
    parser.add_argument("--test-auth", action="store_true",
                        help="try each discovered key against the host")
    parser.add_argument("--ssh-dir", default=SSH_DIR, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    head("ssh config")
    config_path = os.path.join(args.ssh_dir, "config")
    if not os.path.isfile(config_path):
        warn("no %s — only OpenSSH defaults apply" % shorten(config_path))
        loaded, problems = [], []
    else:
        loaded, problems = parse_includes(config_path)
        ok("loaded %d config file(s)" % len(loaded))
        for path in loaded:
            print("        %s" % shorten(path))

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
                print("        %s" % shorten(key))
    else:
        warn("no private keys found under %s" % shorten(args.ssh_dir))

    agent = agent_identities()

    hosts = list(dict.fromkeys(args.host)) or sorted(git_remote_hosts())
    if not hosts:
        head("hosts")
        warn("no SSH remotes in this repository and no --host given")
        return 1

    results = [diagnose_host(h, keys, agent, args.test_auth) for h in hosts]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())

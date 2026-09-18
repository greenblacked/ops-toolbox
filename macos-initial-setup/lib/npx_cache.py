"""Read-only classifier for old, idle entries in the default npx cache.

Invoked by stay_fresh.sh, which owns deletion and size accounting. Only complete
16-hex npm cache entries under ~/.npm/_npx qualify. Configuration overrides,
unknown process state, recent modifications, external links and mount boundaries
preserve data. Output is newline-delimited: HOME control characters are rejected
and entry names are hexadecimal. No package manager is invoked, including in
previews. Exit codes: 0 classified, 1 unsafe/unknown, 4 active Node process.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import time

RETENTION_SECONDS = 7 * 86400


class Unsafe(Exception):
    """Classification cannot safely establish disposable cache entries."""


def processes_idle(text, own_pid):
    """Require a complete numeric process listing containing this helper."""
    seen = set()
    active = False
    for line in text.splitlines():
        match = re.fullmatch(r"\s*([1-9][0-9]*)\s+(\S[^\r\n]*)", line)
        if not match:
            raise Unsafe("malformed process listing")
        pid, command = int(match[1]), match[2].strip()
        if pid in seen:
            raise Unsafe("duplicate process identifier")
        seen.add(pid)
        if re.search(r"(?:^|/)(?:node|nodejs|npm|npx)(?:\s|$)", command):
            active = True
    if own_pid not in seen:
        raise Unsafe("process listing is empty or incomplete")
    return not active


def probe_processes():
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,comm="], capture_output=True, text=True,
            timeout=10, check=False, env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as exc:
        raise Unsafe("process inspection unavailable") from exc
    if result.returncode or result.stderr.strip():
        raise Unsafe("process inspection failed")
    return processes_idle(result.stdout, os.getpid())


def safe_root(home, environ):
    if (not os.path.isabs(home) or home == "/" or os.path.normpath(home) != home
            or any(ord(char) < 32 or ord(char) == 127 for char in home)):
        raise Unsafe("unsafe HOME")
    if any(key.lower() in {"npm_config_cache", "npm_config_userconfig", "npm_config_globalconfig"}
           and value for key, value in environ.items()):
        raise Unsafe("npm configuration override; default cache kept")
    # Config precedence includes local/global npmrc files. We do not execute
    # npm to resolve those: only the conventional default directory is scanned,
    # and a user config of any content makes that default ambiguous.
    if os.path.lexists(os.path.join(home, ".npmrc")):
        raise Unsafe("user npm configuration present; default cache kept")
    root = os.path.join(home, ".npm", "_npx")
    current = "/"
    device = None
    for part in root.split("/")[1:]:
        current = os.path.join(current, part)
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return None
        if not stat.S_ISDIR(metadata.st_mode):
            raise Unsafe("cache ancestry is not a real directory")
        # HOME may live on its own volume; the cache must stay on that volume.
        if current == home:
            device = metadata.st_dev
        if device is not None and metadata.st_dev != device:
            raise Unsafe("cache crosses a mount boundary")
    return root


def old_entry(entry, device, cutoff):
    """Inspect the complete tree without following links or crossing devices."""
    pending = [entry]
    while pending:
        path = pending.pop()
        metadata = os.lstat(path)
        if metadata.st_dev != device or metadata.st_mtime > cutoff:
            return False
        if stat.S_ISLNK(metadata.st_mode):
            target = os.path.realpath(path)
            if os.path.commonpath([entry, target]) != entry:
                return False
        elif stat.S_ISDIR(metadata.st_mode):
            with os.scandir(path) as children:
                pending.extend(child.path for child in children)
        elif not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            return False
    manifest = os.path.join(entry, "package.json")
    modules = os.path.join(entry, "node_modules")
    if not stat.S_ISDIR(os.lstat(modules).st_mode):
        return False
    if not stat.S_ISREG(os.lstat(manifest).st_mode):
        return False
    with open(manifest, encoding="utf-8") as source:
        data = json.load(source)
    deps = data.get("dependencies") if isinstance(data, dict) else None
    return (isinstance(deps, dict) and bool(deps)
            and all(isinstance(k, str) and isinstance(v, str) for k, v in deps.items()))


def classify(home, environ, now):
    root = safe_root(home, environ)
    if root is None:
        return []
    device = os.lstat(root).st_dev
    eligible = []
    with os.scandir(root) as entries:
        for entry in entries:
            if not re.fullmatch(r"[0-9a-f]{16}", entry.name):
                continue
            try:
                if (entry.is_dir(follow_symlinks=False)
                        and old_entry(entry.path, device, now - RETENTION_SECONDS)):
                    eligible.append(entry.path)
            except (OSError, ValueError):
                # An unreadable or changing entry is never an empty entry.
                continue
    return sorted(eligible)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    try:
        home = os.environ.get("HOME", "")
        root = safe_root(home, os.environ)
        if root is None:
            return 0
        if not probe_processes():
            print("npx cache kept: a Node/npm/npx process is running", file=sys.stderr)
            return 4
        eligible = classify(home, os.environ, time.time())
        # Recheck after potentially lengthy traversal before offering deletion.
        if not probe_processes():
            print("npx cache kept: a Node/npm/npx process started", file=sys.stderr)
            return 4
        for entry in eligible:
            print(entry)
        return 0
    except (Unsafe, OSError) as exc:
        print("npx cache kept: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

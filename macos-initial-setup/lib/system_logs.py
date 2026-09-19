"""Preview or prune old rotated compressed system logs through directory fds.

The CLI root is immutable: /private/var/log. Only root-owned, single-link,
regular system.log.N, install.log.N and wifi.log.N files ending in .gz or .bz2
qualify, after 30 days without modification. No recursion. Preview is the default;
--apply requires root and a successful open-file probe. JSON reports actual
unlinks separately from candidates. Exit codes: 0 success, 1 guarded/error,
3 usage. This subprocess helper is not installed as a standalone executable.
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

ROOT = "/private/var/log"
RETENTION_SECONDS = 30 * 86400
LOG_NAME = re.compile(r"(?:system|install|wifi)\.log\.[0-9]+\.(?:gz|bz2)")
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class Unsafe(Exception):
    """Cannot establish that deletion is safe."""


def open_secure_root(root):
    """Walk every component without following links; return an owned fd."""
    if not os.path.isabs(root) or root == "/" or os.path.normpath(root) != root:
        raise Unsafe("unsafe log root")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in [""] + root.split("/")[1:]:
            if component:
                child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            metadata = os.fstat(descriptor)
            if metadata.st_uid != 0 or metadata.st_mode & 0o022:
                raise Unsafe("log ancestry is not root-owned and protected")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def parse_open_files(text, root, own_pid):
    """Require lsof to demonstrate it sees our held directory descriptor."""
    paths = set()
    pid = None
    own_directory = False
    for line in text.splitlines():
        if re.fullmatch(r"p[1-9][0-9]*", line):
            pid = int(line[1:])
        elif line.startswith("n/") and pid is not None:
            path = line[1:]
            paths.add(path)
            if pid == own_pid and path == root:
                own_directory = True
        else:
            raise Unsafe("malformed open-file listing")
    if not own_directory:
        raise Unsafe("open-file listing is empty or incomplete")
    return paths


def open_files(root):
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-F", "pn", "+d", root],
            capture_output=True, text=True, timeout=10, check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as exc:
        raise Unsafe("open-file inspection unavailable") from exc
    if result.returncode or result.stderr.strip():
        raise Unsafe("open-file inspection failed")
    return parse_open_files(result.stdout, root, os.getpid())


def eligible(metadata, device, cutoff):
    return (stat.S_ISREG(metadata.st_mode) and metadata.st_uid == 0
            and metadata.st_nlink == 1 and metadata.st_dev == device
            and not metadata.st_mode & 0o022 and metadata.st_mtime <= cutoff)


def identity(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_uid,
            metadata.st_gid, metadata.st_nlink, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns, metadata.st_blocks)


def clean(root, apply=False, now=None, probe=None):
    """Only tests inject root/time/probe; the CLI exposes none of those knobs."""
    result = {"eligible": 0, "eligible_bytes": 0, "removed": 0,
              "freed_bytes": 0, "kept_open": 0, "errors": []}
    descriptor = None
    try:
        if apply and os.geteuid() != 0:
            raise Unsafe("apply requires root; no logs removed")
        descriptor = open_secure_root(root)
        directory = os.fstat(descriptor)
        cutoff = (time.time() if now is None else now) - RETENTION_SECONDS
        candidates = []
        for name in sorted(os.listdir(descriptor)):
            if not LOG_NAME.fullmatch(name):
                continue
            metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if eligible(metadata, directory.st_dev, cutoff):
                candidates.append((name, metadata))
                result["eligible"] += 1
                result["eligible_bytes"] += metadata.st_blocks * 512
        if not apply or not candidates:
            return result
        opened = (probe or open_files)(root)
        for name, original in candidates:
            if os.path.join(root, name) in opened:
                result["kept_open"] += 1
                continue
            # Keep the fd anchored, and also prove the public root still names
            # that directory. A privileged log rotation may replace a path.
            current_root = open_secure_root(root)
            try:
                current = os.fstat(current_root)
            finally:
                os.close(current_root)
            if (current.st_dev, current.st_ino) != (directory.st_dev, directory.st_ino):
                raise Unsafe("log directory changed during cleanup")
            try:
                current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if identity(current) != identity(original):
                    result["errors"].append("changed log retained: %s" % name)
                    continue
                os.unlink(name, dir_fd=descriptor)
                result["removed"] += 1
                result["freed_bytes"] += original.st_blocks * 512
            except OSError as exc:
                result["errors"].append("could not remove %s: %s" % (name, exc))
    except (OSError, Unsafe) as exc:
        result["errors"].append(str(exc))
    finally:
        if descriptor is not None:
            os.close(descriptor)
    return result


class Usage3Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(3, "%s: error: %s\n" % (self.prog, message))


def main(argv=None):
    parser = Usage3Parser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="remove eligible logs (requires root)")
    args = parser.parse_args(argv)
    result = clean(ROOT, args.apply)
    print(json.dumps(result, sort_keys=True))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())

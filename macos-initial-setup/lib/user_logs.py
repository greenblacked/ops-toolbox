"""Guarded macOS user-log cleanup; preview by default, never uses sudo.

Only regular, owned, single-link files in HOME/Library/Logs qualify after
31 complete days, matching find -mtime +30. DiagnosticReports and stay_fresh
are excluded. Symlinks, mount crossings, open files and changed files stay.
"""

import argparse
import json
import os
import re
import stat
import subprocess
import time

FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class Unsafe(Exception):
    """The target or its activity cannot be checked."""


def secure_dir(home, path):
    if os.path.commonpath((home, path)) != home:
        raise Unsafe("directory outside HOME")
    fd = os.open("/", FLAGS)
    device = None
    current = ""
    try:
        for part in path.split("/")[1:]:
            current += "/" + part
            child = os.open(part, FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            meta = os.fstat(fd)
            if current == home:
                device = meta.st_dev
            if device is not None and (meta.st_dev != device
                    or meta.st_uid != os.geteuid() or meta.st_mode & 0o022):
                raise Unsafe("unsafe ownership, permissions or mount boundary")
        return fd
    except BaseException:
        os.close(fd)
        raise


def identity(meta):
    return (meta.st_dev, meta.st_ino, meta.st_mode, meta.st_uid, meta.st_nlink,
            meta.st_size, meta.st_mtime_ns, meta.st_ctime_ns, meta.st_blocks)


def open_files(path):
    try:
        result = subprocess.run(["lsof", "-nP", "-F", "pfn", "+d", path],
                                capture_output=True, text=True, timeout=10,
                                check=False)
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as exc:
        raise Unsafe("open-file inspection unavailable") from exc
    # +d searches every directory entry. Exit 1 also means some entries
    # were not open, which is expected during cleanup. Accept it only with
    # no diagnostics and the validated own-directory witness below.
    # https://github.com/lsof-org/lsof/blob/master/docs/tutorial.md
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise Unsafe("open-file inspection failed")
    opened, pid, seen_self = set(), None, False
    for line in result.stdout.splitlines():
        if re.fullmatch(r"p[1-9][0-9]*", line):
            pid = int(line[1:])
        elif re.fullmatch(r"f(?:[0-9]+|cwd|rtd|txt|mem|DEL)", line) and pid is not None:
            # Darwin emits file-descriptor fields even when only pn is requested.
            pass
        elif line.startswith("n/") and pid is not None:
            opened.add(line[1:])
            seen_self |= pid == os.getpid() and line[1:] == path
        else:
            raise Unsafe("malformed open-file listing")
    if not seen_self:
        raise Unsafe("incomplete open-file listing")
    return opened


def clean(home, apply=False, now=None, probe=None, verbose=False, keep_days=30, progress=None):
    if type(keep_days) is not int or not 1 <= keep_days <= 36500:
        raise ValueError("keep_days must be an integer from 1 to 36500")
    result = dict(eligible=0, eligible_bytes=0, removed=0, freed_bytes=0,
                  kept_open=0, kept_changed=0, errors=[], paths=[], candidates=[])
    if (not home or not os.path.isabs(home) or home == "/"
            or os.path.normpath(home) != home):
        result["errors"].append("invalid HOME")
        return result
    root = os.path.join(home, "Library", "Logs")
    now = time.time() if now is None else now
    cutoff = now - (keep_days + 1) * 86400
    pending = [root]
    while pending:
        path = pending.pop()
        fd = None
        try:
            fd = secure_dir(home, path)
            directory = os.fstat(fd)
            candidates = []
            for name in sorted(os.listdir(fd)):
                if path == root and name in ("DiagnosticReports", "stay_fresh"):
                    continue
                meta = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if stat.S_ISDIR(meta.st_mode):
                    pending.append(os.path.join(path, name))
                elif (stat.S_ISREG(meta.st_mode) and meta.st_uid == os.geteuid()
                      and meta.st_dev == directory.st_dev and meta.st_nlink == 1
                      and meta.st_mtime <= cutoff):
                    candidates.append((name, meta))
                    result["eligible"] += 1
                    result["eligible_bytes"] += meta.st_blocks * 512
                    if verbose:
                        result["paths"].append(os.path.join(path, name))
                        result["candidates"].append(dict(path=os.path.join(path, name),
                            bytes=meta.st_blocks * 512, age_days=int((now-meta.st_mtime)//86400),
                            reason="old regular user log; historical contents cannot be recreated"))
            if not apply or not candidates:
                continue
            opened = (probe or open_files)(path)
            for name, original in candidates:
                if os.path.join(path, name) in opened:
                    result["kept_open"] += 1
                    continue
                current_fd = secure_dir(home, path)
                try:
                    current_dir = os.fstat(current_fd)
                finally:
                    os.close(current_fd)
                if (current_dir.st_dev, current_dir.st_ino) != (directory.st_dev, directory.st_ino):
                    raise Unsafe("log directory changed")
                try:
                    current = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    if identity(current) != identity(original):
                        result["kept_changed"] += 1
                        continue
                    os.unlink(name, dir_fd=fd)
                    result["removed"] += 1
                    result["freed_bytes"] += original.st_blocks * 512
                    result["last_removed"] = dict(path=os.path.join(path, name),
                                                bytes=original.st_blocks * 512)
                    if progress:
                        progress(result)
                except FileNotFoundError:
                    result["kept_changed"] += 1
                except OSError as exc:
                    result["errors"].append(str(exc))
        except (OSError, Unsafe) as exc:
            result["errors"].append("%s: %s" % (path, exc))
        finally:
            if fd is not None:
                os.close(fd)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--keep-days", type=int, default=30)
    parser.add_argument("--progress", action="store_true",
                        help="emit confirmed removal checkpoints")
    args = parser.parse_args()
    if not 1 <= args.keep_days <= 36500:
        parser.error("--keep-days must be from 1 to 36500")
    result = clean(os.environ.get("HOME", ""), args.apply,
                   verbose=args.verbose, keep_days=args.keep_days,
                   progress=(lambda r: print(
                       json.dumps({**r, "paths": [], "candidates": []}), flush=True))
                   if args.progress else None)
    print(json.dumps(result))
    return int(bool(result["errors"]))


if __name__ == "__main__":
    raise SystemExit(main())

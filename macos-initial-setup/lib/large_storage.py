#!/usr/bin/env python3
"""Classify extra large disposable caches that stay_fresh.sh does not inline.

Invoked by stay_fresh.sh, which owns process checks and deletion. Only named
renderer caches directly within recognized profiles qualify. Virtual machines,
downloaded models, GeForce NOW data and JetBrains recovery history are kept.
Output is four NUL-delimited fields per record. Exit codes: 0 classified,
1 unsafe HOME or scan, 4 nothing to report.
"""

from __future__ import annotations

import argparse
import os
import stat
import sys

DISPOSABLE = "disposable"
KEPT = "kept"

CLAUDE_CACHE_NAMES = frozenset(
    {
        "Cache",
        "Code Cache",
        "GPUCache",
        "DawnCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache",
        "GraphiteDawnCache",
        "ShaderCache",
        "GrShaderCache",
    }
)
CLAUDE_KEEP = (
    ("vm_bundles", "Claude computer-use VM"),
    ("claude-code-vm", "Claude Code VM"),
)


class Unsafe(Exception):
    """Classification cannot safely establish disposable storage."""


def safe_home(home):
    if (
        not os.path.isabs(home)
        or home == "/"
        or os.path.normpath(home) != home
        or any(ord(char) < 32 or ord(char) == 127 for char in home)
    ):
        raise Unsafe("unsafe HOME")
    return home


def real_dir(path, home, device):
    """Return path if it is a real directory on HOME's volume, else None.

    Symlinks, files, and mount crossings are not disposable and are not
    kept-notes either: the caller must not follow them.
    """
    if os.path.commonpath([home, path]) != home:
        raise Unsafe("path escapes HOME")
    current = home
    for component in os.path.relpath(path, home).split(os.sep):
        current = os.path.join(current, component)
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise Unsafe("cannot inspect %s" % current) from exc
        if not stat.S_ISDIR(metadata.st_mode):
            return None
        if metadata.st_dev != device:
            raise Unsafe("path crosses a mount boundary")
    return path


def home_device(home):
    try:
        metadata = os.lstat(home)
    except OSError as exc:
        raise Unsafe("cannot inspect HOME") from exc
    if not stat.S_ISDIR(metadata.st_mode):
        raise Unsafe("HOME is not a real directory")
    return metadata.st_dev


def child_dirs(root, device):
    try:
        with os.scandir(root) as children:
            entries = list(children)
        for entry in entries:
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode) and metadata.st_dev == device:
                yield entry.path
    except OSError as exc:
        raise Unsafe("cannot scan %s" % root) from exc


def named_cache_dirs(root, names, device):
    """Only direct app/profile cache leaves; never walk persistent state."""
    roots = [root]
    roots.extend(
        path for path in child_dirs(root, device)
        if os.path.basename(path) == "Default"
        or os.path.basename(path).startswith("Profile ")
    )
    for profile in roots:
        for path in child_dirs(profile, device):
            if os.path.basename(path) in names:
                yield path


def classify(home, scope, deep_clean):
    home = safe_home(home)
    device = home_device(home)
    records = []

    def add(status, family, path, reason):
        records.append((status, family, path, reason))

    if scope in ("ai", "all"):
        claude = real_dir(
            os.path.join(home, "Library", "Application Support", "Claude"),
            home,
            device,
        )
        if claude is not None:
            for path in named_cache_dirs(
                claude, CLAUDE_CACHE_NAMES, device
            ):
                add(DISPOSABLE, "Claude", path, "Claude renderer cache")
            for name, reason in CLAUDE_KEEP:
                kept = real_dir(os.path.join(claude, name), home, device)
                if kept is not None:
                    add(KEPT, "Claude", kept, reason)

    if scope in ("app", "all"):
        for name in ("GeForceNOW", "GeForce NOW"):
            geforce = real_dir(
                os.path.join(home, "Movies", "NVIDIA", name), home, device,
            )
            if geforce is not None:
                add(
                    KEPT, "GeForceNOW", geforce,
                    "GeForce NOW data kept; may contain personal recordings",
                )

        jetbrains = real_dir(
            os.path.join(home, "Library", "Caches", "JetBrains"),
            home,
            device,
        )
        if jetbrains is not None:
            for path in child_dirs(jetbrains, device):
                add(
                    KEPT, "JetBrains", path,
                    "JetBrains system directory kept; includes Local History",
                )

        optguide = real_dir(
            os.path.join(
                home,
                "Library",
                "Application Support",
                "Google",
                "Chrome",
                "OptGuideOnDeviceModel",
            ),
            home,
            device,
        )
        if optguide is not None:
            add(KEPT, "Chrome", optguide, "Chrome downloaded on-device model kept")

    records.sort(key=lambda item: (item[1], item[2], item[0]))
    return records


def emit(records):
    for status, family, path, reason in records:
        sys.stdout.buffer.write(
            ("%s\0%s\0%s\0%s\0" % (status, family, path, reason)).encode("utf-8")
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scope",
        choices=("ai", "app", "all"),
        default="all",
        help="which families to classify",
    )
    parser.add_argument(
        "--deep-clean",
        action="store_true",
        help="accepted for caller compatibility; downloaded models remain kept",
    )
    args = parser.parse_args(argv)
    try:
        records = classify(os.environ.get("HOME", ""), args.scope, args.deep_clean)
    except (Unsafe, OSError) as exc:
        print("large storage kept: %s" % exc, file=sys.stderr)
        return 1
    if not records:
        return 4
    emit(records)
    return 0


if __name__ == "__main__":
    sys.exit(main())

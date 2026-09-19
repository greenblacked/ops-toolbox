"""Classify explicitly selected older JetBrains version directories; never delete.

Only the three default user roots are supported. The newest observed version of
each product, ambiguous inventories, redirected paths and foreign-owned paths
are preserved. Output is NUL-delimited paths, emitted only after full validation.
Exit codes: 0 classified, 1 unsafe/incomplete inventory, 3 usage.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys

PRODUCTS = (
    "IntelliJIdea", "IdeaIC", "PyCharmCE", "PyCharm", "WebStorm", "PhpStorm",
    "RubyMine", "CLion", "DataGrip", "GoLand", "Rider", "RustRover", "DataSpell",
    "Aqua", "Gateway",
)
VERSION = re.compile(r"(" + "|".join(PRODUCTS) + r")(20[0-9]{2})\.([1-9][0-9]*)(?:\.([0-9]+))?")
ROOTS = ("Application Support", "Caches", "Logs")


class Unsafe(Exception):
    """Cannot establish a complete, safe inventory."""


def version(name):
    match = VERSION.fullmatch(name)
    if not match:
        raise ValueError("expected an exact JetBrains version, for example PyCharm2025.2")
    return match[1], tuple(int(part or 0) for part in match.groups()[1:])


def directory(path, home, device, owner):
    current = home
    for part in os.path.relpath(path, home).split(os.sep):
        current = os.path.join(current, part)
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            return False
        if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != owner
                or metadata.st_dev != device or metadata.st_mode & 0o022):
            raise Unsafe("unsafe directory: %s" % current)
    return True


def classify(home, selections):
    if (not os.path.isabs(home) or home == "/" or os.path.normpath(home) != home
            or any(ord(char) < 32 or ord(char) == 127 for char in home)):
        raise Unsafe("unsafe HOME")
    selected = dict.fromkeys(selections)
    parsed = {name: version(name) for name in selected}
    owner = os.getuid()
    metadata = os.lstat(home)
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != owner
            or metadata.st_mode & 0o022):
        raise Unsafe("HOME is not a protected owned directory")
    device = metadata.st_dev
    inventory = {}
    latest = {}
    families = {product for product, _ in parsed.values()}
    for base in ROOTS:
        root = os.path.join(home, "Library", base, "JetBrains")
        if not directory(root, home, device, owner):
            continue
        for name in os.listdir(root):
            try:
                product, number = version(name)
            except ValueError:
                if name.endswith("-backup") and VERSION.fullmatch(name[:-7]):
                    continue
                if any(re.match(re.escape(product) + r"[0-9]", name) for product in families):
                    raise Unsafe("ambiguous version directory: %s" % name) from None
                continue
            if product not in families:
                continue
            path = os.path.join(root, name)
            if not directory(path, home, device, owner):
                raise Unsafe("version disappeared during inventory")
            inventory.setdefault(name, []).append(path)
            latest[product] = max(latest.get(product, number), number)
    paths = []
    for name, (product, number) in parsed.items():
        if name not in inventory:
            raise Unsafe("selected version not found: %s" % name)
        if number >= latest[product]:
            raise Unsafe("newest or only observed version kept: %s" % name)
        paths.extend(inventory[name])
    return sorted(paths)


class Usage3Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(3, "%s: error: %s\n" % (self.prog, message))


def main(argv=None):
    parser = Usage3Parser(description=__doc__)
    parser.add_argument("--version", action="append", required=True)
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        for name in args.version:
            version(name)
    except ValueError as exc:
        parser.error(str(exc))
    if args.validate_only:
        return 0
    try:
        paths = classify(os.environ.get("HOME", ""), args.version)
    except (OSError, Unsafe) as exc:
        print("JetBrains versions kept: %s" % exc, file=sys.stderr)
        return 1
    for path in paths:
        sys.stdout.buffer.write(os.fsencode(path) + b"\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())

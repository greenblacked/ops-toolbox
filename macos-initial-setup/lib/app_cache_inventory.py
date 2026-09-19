"""Map installed third-party apps to disposable cache directories, read-only.

Only exact bundle-ID caches, sandbox Library/Caches, and named Teams WebView
cache leaves qualify. Apple/JetBrains data, app databases, downloaded models,
recordings and unassociated folders are not targets. Parent owns activity
checks and deletion. Output: app, executable ERE, bundle ERE, path (NUL fields).
Exit codes: 0 complete, 1 unsafe or incomplete inventory.
"""

from __future__ import annotations

import os
import plistlib
import re
import stat
import sys

BUNDLE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+")
CACHE_NAMES = ("Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
               "DawnWebGPUCache", "GraphiteDawnCache", "ShaderCache", "GrShaderCache")
EXCLUDED_NAMES = ("jetbrains", "pycharm", "intellij", "webstorm", "phpstorm", "rubymine",
                  "clion", "datagrip", "goland", "rider", "rustrover", "dataspell", "aqua",
                  "gateway", "ollama", "lm studio", "locally ai")


class Unsafe(Exception):
    """Inventory cannot safely establish a candidate."""


def text_safe(value):
    return isinstance(value, str) and bool(value) and not any(
        ord(char) < 32 or ord(char) == 127 for char in value
    )


def owned_dir(path, home, device):
    if os.path.commonpath((path, home)) != home:
        raise Unsafe("cache escapes HOME")
    current = home
    for part in os.path.relpath(path, home).split(os.sep):
        current = os.path.join(current, part)
        try:
            item = os.lstat(current)
        except FileNotFoundError:
            return False
        if (not stat.S_ISDIR(item.st_mode) or item.st_uid != os.getuid()
                or item.st_dev != device or item.st_mode & 0o022):
            return False
    return True


def installed_apps(roots):
    """Bounded directory scan; no LaunchServices/package tool side effects."""
    pending = [(root, 0) for root in roots]
    apps = {}
    while pending:
        root, depth = pending.pop()
        try:
            metadata = os.lstat(root)
        except FileNotFoundError:
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            continue
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if not text_safe(path) or not stat.S_ISDIR(os.lstat(path).st_mode):
                continue
            if not name.endswith(".app"):
                if depth < 2:
                    pending.append((path, depth + 1))
                continue
            if any(word in name.lower() for word in EXCLUDED_NAMES):
                continue
            info = os.path.join(path, "Contents", "Info.plist")
            try:
                item = os.lstat(info)
                if not stat.S_ISREG(item.st_mode) or item.st_size > 1024 * 1024:
                    continue
                with open(info, "rb") as stream:
                    data = plistlib.load(stream)
            except (FileNotFoundError, plistlib.InvalidFileException, ValueError, TypeError):
                continue
            if not isinstance(data, dict):
                continue
            bundle = data.get("CFBundleIdentifier", "")
            executable = data.get("CFBundleExecutable", "")
            if (not text_safe(bundle) or not BUNDLE_ID.fullmatch(bundle)
                    or bundle.lower().startswith("com.apple.") or "jetbrains" in bundle.lower()
                    or not text_safe(executable) or "/" in executable):
                continue
            apps.setdefault(bundle, []).append((path, executable))
    return apps


def classify(home, roots):
    if (not text_safe(home) or not os.path.isabs(home) or home == "/"
            or os.path.normpath(home) != home):
        raise Unsafe("unsafe HOME")
    metadata = os.lstat(home)
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o022):
        raise Unsafe("unsafe HOME ownership/type")
    device = metadata.st_dev
    records = []
    for bundle, apps in sorted(installed_apps(roots).items()):
        label = os.path.basename(apps[0][0])[:-4]
        executable = "|".join(sorted({re.escape(app[1]) for app in apps}))
        pattern = "|".join(re.escape(app[0]) + "/Contents/" for app in apps)
        candidates = [os.path.join(home, "Library", "Caches", bundle)]
        container = os.path.join(home, "Library", "Containers", bundle, "Data", "Library")
        candidates.append(os.path.join(container, "Caches"))
        if bundle == "com.microsoft.teams2":
            web = os.path.join(
                container, "Application Support", "Microsoft", "MSTeams", "EBWebView"
            )
            if owned_dir(web, home, device):
                profiles = [web]
                for name in os.listdir(web):
                    if name == "Default" or re.fullmatch(r"WV2Profile_[A-Za-z0-9_-]+", name):
                        path = os.path.join(web, name)
                        if owned_dir(path, home, device):
                            profiles.append(path)
                candidates.extend(os.path.join(profile, name)
                                  for profile in profiles for name in CACHE_NAMES)
        for path in sorted(set(candidates)):
            if owned_dir(path, home, device):
                records.append((label, executable, pattern, path))
    return sorted(records)


def main():
    home = os.environ.get("HOME", "")
    try:
        records = classify(home, ("/Applications", os.path.join(home, "Applications")))
    except (OSError, Unsafe) as exc:
        print("installed-app cache inventory kept: %s" % exc, file=sys.stderr)
        return 1
    for record in records:
        sys.stdout.buffer.write(b"\0".join(os.fsencode(field) for field in record) + b"\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Classify VS Code-family workspaceStorage entries as live, stale or unresolved.

VS Code and its forks create ``workspaceStorage/<hash>/`` for every folder ever
opened and never garbage-collect them. This module decides which of those
entries refer to projects that are genuinely gone, so a caller can delete them.

The contract is deliberately lopsided: an entry is reported ``stale`` only when
its recorded path is *provably* gone. Everything else — a remote or virtual
workspace, a missing or unparsable workspace.json, a path whose volume is not
currently mounted — is ``unresolved`` and must be kept. Being wrong in the
``unresolved`` direction wastes disk. Being wrong in the ``stale`` direction
destroys a project's editor state, and for a workspace on an unplugged drive
that is indistinguishable from deleting someone's work.

Invoked by stay_fresh.sh with /usr/bin/python3 — the macOS system interpreter,
which is 3.9 — so this is stdlib-only and free of 3.10+ syntax. It is a plain
module with a main(); nothing here writes to disk or deletes anything.

Output is NUL-delimited records, one per entry::

    <status>\\t<entry_dir>\\t<reason>\\t<project_path>\\0

NUL rather than newline because macOS paths may legally contain newlines.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from urllib.parse import unquote, urlparse

LIVE = "live"
STALE = "stale"
UNRESOLVED = "unresolved"

# Volumes whose absence from /Volumes never means "unmounted disk". The boot
# volume is always mounted, and macOS keeps a firmlink here on APFS.
_ALWAYS_MOUNTED_PREFIXES = ("/System/Volumes/",)


def mounted_volume_names(volumes_dir: str = "/Volumes") -> frozenset:
    """Names currently present under /Volumes.

    Deliberately a readdir and nothing more. Calling stat() on each entry — as
    os.path.ismount does — can block for many seconds on a dead network mount,
    and this runs during routine housekeeping. A cheap name lookup is enough to
    answer the only question that matters: is this volume attached right now.
    """
    try:
        return frozenset(os.listdir(volumes_dir))
    except OSError:
        # No /Volumes at all (Linux CI, a sandbox). Callers fall back to
        # treating every path as being on the root volume.
        return frozenset()


def _volume_of(path: str):
    """Return the /Volumes name a path lives on, or None for the root volume."""
    parts = path.split(os.sep)
    # ['', 'Volumes', '<name>', ...]
    if len(parts) >= 3 and parts[1] == "Volumes" and parts[2]:
        return parts[2]
    return None


def extract_uri(data):
    """Pull the workspace URI out of a parsed workspace.json.

    VS Code writes ``folder`` for a single-folder workspace and ``workspace``
    for a .code-workspace file. Anything else is not something we can reason
    about.
    """
    if not isinstance(data, dict):
        return None
    for key in ("folder", "workspace"):
        value = data.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def decode_file_uri(uri: str):
    """Return (decoded_path, raw_path) for a file:// URI, or None if not local.

    Returns every plausible spelling of the path, most-likely first, or None if
    the URI is not a local file. The caller treats the entry as live if *any*
    candidate exists on disk.

    There are two independent ambiguities, and both are resolved by widening the
    candidate list rather than by picking a winner:

    - Percent-decoding. A path containing a literal '%' decodes into something
      else entirely, so the raw spelling is kept alongside the decoded one.
    - '?' and '#'. In a URI these introduce a query and a fragment, but macOS
      allows both in filenames. Truncating at them turns a live '/x/my#proj'
      into '/x/my', which does not exist, which reads as a deleted project.
      So the untruncated spelling is a candidate too.
    """
    if not uri.startswith("file://"):
        return None
    parsed = urlparse(uri)
    # A non-empty host means a UNC/remote path (file://server/share) — not ours
    # to reason about. 'localhost' is spelled by some tools and means local.
    if parsed.netloc and parsed.netloc != "localhost":
        return None
    raw = uri[len("file://") :]
    if parsed.netloc:
        raw = raw[len(parsed.netloc) :]
    if not raw:
        return None

    trimmed = raw
    for sep in ("?", "#"):
        idx = trimmed.find(sep)
        if idx != -1:
            trimmed = trimmed[:idx]

    candidates = []
    for form in (trimmed, raw):
        if not form:
            continue
        for spelling in (unquote(form, errors="replace"), form):
            if spelling and spelling not in candidates:
                candidates.append(spelling)
    return candidates or None


def classify_entry(entry_dir: str, mounted: frozenset):
    """Classify one workspaceStorage/<hash>/ directory.

    Returns (status, reason, project_path). project_path is '' when no local
    path could be determined.
    """
    manifest = os.path.join(entry_dir, "workspace.json")
    if not os.path.isfile(manifest):
        return UNRESOLVED, "no workspace.json", ""

    try:
        with open(manifest, "r", encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        # Unreadable or malformed. We know nothing, so we keep it.
        return UNRESOLVED, "unparsable workspace.json", ""

    uri = extract_uri(data)
    if uri is None:
        return UNRESOLVED, "no folder/workspace key", ""

    candidates = decode_file_uri(uri)
    if candidates is None:
        # vscode-remote://, vscode-vfs://, ssh://, a UNC host — all real
        # workspaces that simply are not on this filesystem.
        scheme = uri.split(":", 1)[0] or "unknown"
        return UNRESOLVED, "non-local workspace (%s)" % scheme, ""

    # The most likely spelling, used for display and for the volume message.
    path = candidates[0]

    # The volume check has to come before the existence check. A workspace on an
    # unplugged SSD or an unmounted share does not exist right now, and is
    # otherwise indistinguishable from a deleted one. Every candidate spelling
    # is considered; we proceed only if at least one names an attached volume.
    if not path.startswith(_ALWAYS_MOUNTED_PREFIXES):
        volumes = []
        for candidate in candidates:
            volume = _volume_of(candidate)
            if volume is not None and volume not in volumes:
                volumes.append(volume)
        if volumes and not any(v in mounted for v in volumes):
            return UNRESOLVED, "volume not mounted (%s)" % volumes[0], path

    for candidate in candidates:
        if os.path.exists(candidate):
            # Report the spelling that actually matched, not the first guess —
            # this string is what --verbose and --json show.
            return LIVE, "", candidate

    return STALE, "path gone", path


def iter_entries(root: str):
    """Yield workspaceStorage/<hash>/ directories under one storage root."""
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return
    for name in names:
        entry = os.path.join(root, name)
        if os.path.isdir(entry):
            yield entry


def scan(roots, volumes_dir: str = "/Volumes"):
    """Classify every entry under each storage root. Returns a list of dicts."""
    mounted = mounted_volume_names(volumes_dir)
    results = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for entry in iter_entries(root):
            status, reason, path = classify_entry(entry, mounted)
            results.append(
                {"status": status, "dir": entry, "reason": reason, "path": path}
            )
    return results


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Classify VS Code workspaceStorage entries as live/stale/unresolved."
    )
    parser.add_argument("roots", nargs="+", help="workspaceStorage directories to scan")
    parser.add_argument(
        "--volumes-dir",
        default="/Volumes",
        help="where mounted volumes appear (overridable for tests)",
    )
    parser.add_argument(
        "--json", action="store_true", help="emit JSON instead of NUL-delimited records"
    )
    args = parser.parse_args(argv)

    results = scan(args.roots, volumes_dir=args.volumes_dir)

    if args.json:
        json.dump(results, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    out = sys.stdout.buffer
    for item in results:
        record = "%s\t%s\t%s\t%s" % (
            item["status"],
            item["dir"],
            item["reason"],
            item["path"],
        )
        out.write(record.encode("utf-8", "surrogateescape") + b"\0")
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())

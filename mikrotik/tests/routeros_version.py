#!/usr/bin/env python3
"""Find and record the RouterOS version exercised by the CHR test suite."""

from __future__ import annotations

import argparse
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from collections.abc import Iterable, Sequence
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
VERSION_FILE = HERE / "routeros-version.env"
CHANNEL_FEEDS = {
    "stable": "https://download.mikrotik.com/routeros/latest-stable.rss",
    "long-term": "https://download.mikrotik.com/routeros/latest-long-term.rss",
}
PROMOTABLE_CHANNEL = "stable"
DOCUMENTATION_FILES = (
    Path("README.md"),
    Path("mikrotik/README.md"),
    Path("mikrotik/tests/README.md"),
    Path(".github/workflows/chr.yml"),
)
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$")
RSS_TITLE_RE = re.compile(
    r"^RouterOS (?P<version>[0-9]+\.[0-9]+(?:\.[0-9]+)?) "
    r"\[(?P<channel>stable|long-term)\]$"
)


class ReleaseError(RuntimeError):
    """The upstream release data or local version state is invalid."""


def validate_version(value: str) -> str:
    value = value.strip()
    if not VERSION_RE.fullmatch(value):
        raise ReleaseError(f"invalid RouterOS version: {value!r}")
    return value


def version_key(value: str) -> tuple[int, int, int]:
    parts = [int(part) for part in validate_version(value).split(".")]
    parts.extend([0] * (3 - len(parts)))
    return parts[0], parts[1], parts[2]


def require_promotable_channel(channel: str) -> None:
    """Reject channels that must not replace the canonical compatibility pin."""
    if channel != PROMOTABLE_CHANNEL:
        raise ReleaseError(
            f"channel {channel!r} is available only for check-only testing; "
            f"version bumps must use {PROMOTABLE_CHANNEL!r}"
        )


def read_pinned_version(path: Path = VERSION_FILE) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ReleaseError(f"cannot read {path}: {exc}") from exc
    values = [line.split("=", 1)[1] for line in lines if line.startswith("ROUTEROS_VERSION=")]
    if len(values) != 1:
        raise ReleaseError(f"{path} must contain exactly one ROUTEROS_VERSION entry")
    return validate_version(values[0])


def parse_release_feed(payload: bytes, channel: str) -> str:
    try:
        root = ET.fromstring(payload)
    except ET.ParseError as exc:
        raise ReleaseError(f"invalid RouterOS release RSS: {exc}") from exc
    title = root.findtext("./channel/item/title", default="").strip()
    match = RSS_TITLE_RE.fullmatch(title)
    if not match:
        raise ReleaseError(f"unexpected RouterOS release title: {title!r}")
    if match.group("channel") != channel:
        raise ReleaseError(
            f"release feed returned channel {match.group('channel')!r}, expected {channel!r}"
        )
    return validate_version(match.group("version"))


def fetch_latest_version(channel: str, timeout: int = 30) -> str:
    url = CHANNEL_FEEDS[channel]
    request = urllib.request.Request(url, headers={"User-Agent": "ops-toolbox/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read()
    except (OSError, urllib.error.URLError) as exc:
        raise ReleaseError(f"cannot fetch {url}: {exc}") from exc
    return parse_release_feed(payload, channel)


def chr_download_url(version: str) -> str:
    checked = validate_version(version)
    return f"https://download.mikrotik.com/routeros/{checked}/chr-{checked}.vdi.zip"


def verify_chr_download(version: str, timeout: int = 30) -> None:
    url = chr_download_url(version)
    request = urllib.request.Request(
        url,
        method="HEAD",
        headers={"User-Agent": "ops-toolbox/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                raise ReleaseError(f"CHR archive returned HTTP {response.status}: {url}")
    except (OSError, urllib.error.URLError) as exc:
        raise ReleaseError(f"CHR archive is unavailable for {version}: {exc}") from exc


def _replace_documented_version(
    repo_root: Path,
    current: str,
    target: str,
    files: Iterable[Path] = DOCUMENTATION_FILES,
) -> None:
    updates = []
    for relative in files:
        path = repo_root / relative
        text = path.read_text(encoding="utf-8")
        if current not in text:
            raise ReleaseError(f"expected {current!r} in {relative}; refusing partial bump")
        updates.append((path, text.replace(current, target)))
    for path, text in updates:
        path.write_text(text, encoding="utf-8")


def _add_changelog_entry(repo_root: Path, current: str, target: str) -> None:
    path = repo_root / "CHANGELOG.md"
    text = path.read_text(encoding="utf-8")
    marker = "## [Unreleased]\n\n### Changed\n\n"
    if marker not in text:
        raise ReleaseError("CHANGELOG.md has no Unreleased/Changed insertion point")
    entry = (
        f"- RouterOS CHR compatibility was bumped from {current} to {target} after "
        "the full Docker integration suite passed.\n"
    )
    path.write_text(text.replace(marker, marker + entry, 1), encoding="utf-8")


def bump_version(target: str, repo_root: Path = REPO_ROOT) -> None:
    target = validate_version(target)
    version_file = repo_root / VERSION_FILE.relative_to(REPO_ROOT)
    current = read_pinned_version(version_file)
    if version_key(target) <= version_key(current):
        raise ReleaseError(f"target {target} must be newer than the pinned version {current}")
    changelog = repo_root / "CHANGELOG.md"
    changelog_marker = "## [Unreleased]\n\n### Changed\n\n"
    if changelog_marker not in changelog.read_text(encoding="utf-8"):
        raise ReleaseError("CHANGELOG.md has no Unreleased/Changed insertion point")
    _replace_documented_version(repo_root, current, target)
    _add_changelog_entry(repo_root, current, target)
    text = version_file.read_text(encoding="utf-8")
    version_file.write_text(
        text.replace(f"ROUTEROS_VERSION={current}", f"ROUTEROS_VERSION={target}"),
        encoding="utf-8",
    )


def _check(args: argparse.Namespace) -> int:
    if args.for_version_bump:
        require_promotable_channel(args.channel)
    current = read_pinned_version()
    latest = validate_version(args.version) if args.version else fetch_latest_version(args.channel)
    if not args.skip_download_check:
        verify_chr_download(latest)
    update_available = version_key(latest) > version_key(current)
    if args.format == "github":
        print(f"current={current}")
        print(f"latest={latest}")
        print(f"update_available={str(update_available).lower()}")
        print(f"channel={args.channel}")
    else:
        state = "newer release available" if update_available else "no newer release"
        print(f"RouterOS {args.channel}: current={current} latest={latest} ({state})")
        print(f"CHR archive: {chr_download_url(latest)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check", help="resolve the newest RouterOS release")
    check.add_argument("--channel", choices=sorted(CHANNEL_FEEDS), default="stable")
    check.add_argument("--version", help="test an explicit version instead of reading RSS")
    check.add_argument("--skip-download-check", action="store_true")
    check.add_argument("--format", choices=("text", "github"), default="text")
    check.add_argument(
        "--for-version-bump",
        action="store_true",
        help="require a channel allowed to replace the canonical version pin",
    )
    check.set_defaults(func=_check)

    bump = subparsers.add_parser("bump", help="update the pinned and documented version")
    bump.add_argument("version")
    bump.set_defaults(func=lambda args: (bump_version(args.version), 0)[1])
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ReleaseError, OSError) as exc:
        print(f"routeros_version.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Find and record the RouterOS version exercised by the CHR test suite."""

from __future__ import annotations

import argparse
import hashlib
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
# Files the bump rewrites when the pin moves.
#
# Nothing under .github/workflows/ may be listed here. GITHUB_TOKEN is refused
# when it pushes a branch touching a workflow file - "refusing to allow a GitHub
# App to create or update workflow ... without `workflows` permission` - and
# that permission cannot be granted from a workflow's own permissions block. A
# single version number in a chr.yml comment was enough to stop the bump branch
# from being pushed at all. Version references belong in documentation, or in
# routeros-version.env, which is the pin itself.
DOCUMENTATION_FILES = (
    Path("README.md"),
    Path("mikrotik/README.md"),
    Path("mikrotik/tests/README.md"),
)
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
# The bracket holds every channel the release currently sits in, not one. A
# release is promoted through them over time, so 7.24 was published as
# "RouterOS 7.24 [stable, testing, development]" and this pattern — which
# demanded a single token — failed the whole workflow at its first step.
# Capture the list and check membership rather than equality.
RSS_TITLE_RE = re.compile(
    r"^RouterOS (?P<version>[0-9]+\.[0-9]+(?:\.[0-9]+)?) "
    r"\[(?P<channels>[a-z][a-z0-9 ,-]*)\]$"
)


class ReleaseError(RuntimeError):
    """The upstream release data or local version state is invalid."""


def validate_version(value: str) -> str:
    value = value.strip()
    if not VERSION_RE.fullmatch(value):
        raise ReleaseError(f"invalid RouterOS version: {value!r}")
    return value


def validate_sha256(value: str) -> str:
    value = value.strip().lower()
    if not SHA256_RE.fullmatch(value):
        raise ReleaseError(f"invalid SHA-256 digest: {value!r}")
    return value


def read_pinned_sha256(path: Path = VERSION_FILE) -> str:
    """The recorded digest, or '' when none has been recorded yet."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ReleaseError(f"cannot read {path}: {exc}") from exc
    values = [line.split("=", 1)[1] for line in lines if line.startswith("ROUTEROS_SHA256=")]
    if len(values) > 1:
        raise ReleaseError(f"{path} must contain at most one ROUTEROS_SHA256 entry")
    if not values or not values[0].strip():
        return ""
    return validate_sha256(values[0])


def _write_pinned_sha256(digest: str, path: Path = VERSION_FILE) -> None:
    digest = validate_sha256(digest)
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if any(line.startswith("ROUTEROS_SHA256=") for line in lines):
        lines = [
            f"ROUTEROS_SHA256={digest}" if line.startswith("ROUTEROS_SHA256=") else line
            for line in lines
        ]
    else:
        # Appended rather than rejected: a version file predating the checksum
        # pin is still valid input, and refusing it would strand the very bump
        # that introduces the digest.
        lines.append(f"ROUTEROS_SHA256={digest}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def compute_sha256(version: str, timeout: int = 300) -> str:
    """Stream the CHR archive and hash it without holding it in memory.

    Tries the same hosts as the Dockerfile, in the same order, so a digest can
    be recorded for anything the build is capable of downloading.
    """
    errors = []
    for url in chr_download_urls(version):
        request = urllib.request.Request(url, headers={"User-Agent": "ops-toolbox/1"})
        digest = hashlib.sha256()
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    digest.update(chunk)
        except (OSError, urllib.error.URLError) as exc:
            errors.append(f"{url}: {exc}")
            continue
        return digest.hexdigest()
    raise ReleaseError("cannot download the CHR archive: " + "; ".join(errors))


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
    channels = {c.strip() for c in match.group("channels").split(",") if c.strip()}
    if channel not in channels:
        raise ReleaseError(
            f"release feed returned channels {sorted(channels)!r}, expected {channel!r}"
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


def chr_download_urls(version: str) -> list[str]:
    """Both hosts the Dockerfile tries, in the same order.

    The build falls back to the CDN for rc/beta builds, so hashing only the
    primary host would fail to record a digest for an archive the build would
    happily have used.
    """
    checked = validate_version(version)
    return [
        f"https://{host}/routeros/{checked}/chr-{checked}.vdi.zip"
        for host in ("download.mikrotik.com", "cdn.mikrotik.com")
    ]


def chr_download_url(version: str) -> str:
    return chr_download_urls(version)[0]


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
    # Anchored, not a bare str.replace. An unanchored replace of a two-part pin
    # such as "7.23" also rewrites the "7.23.3" occurrences around it, turning
    # them into "7.24.3". The lookahead stops the match at a version boundary
    # while still allowing "7.23." followed by nothing version-like.
    pattern = re.compile(rf"(?<![0-9.]){re.escape(current)}(?![0-9.])")
    updates = []
    for relative in files:
        path = repo_root / relative
        text = path.read_text(encoding="utf-8")
        if not pattern.search(text):
            raise ReleaseError(f"expected {current!r} in {relative}; refusing partial bump")
        updates.append((path, pattern.sub(target, text)))
    for path, text in updates:
        path.write_text(text, encoding="utf-8")


# Keep a Changelog's section order. Used to place a "### Changed" heading among
# whatever the Unreleased section already has, rather than demanding it be first.
CHANGELOG_SECTIONS = (
    "Added",
    "Changed",
    "Deprecated",
    "Removed",
    "Fixed",
    "Security",
)


def _unreleased_span(text: str) -> tuple[int, int]:
    """Character range of the Unreleased section body, heading excluded."""
    # [ \t]* not \s*: the latter is greedy across newlines, so end() lands past
    # the blank lines and the caller reinserts its own, producing two in a row.
    heading = re.search(r"^## \[Unreleased\][ \t]*$", text, re.MULTILINE)
    if not heading:
        raise ReleaseError("CHANGELOG.md has no '## [Unreleased]' heading")
    start = heading.end()
    following = re.search(r"^## ", text[start:], re.MULTILINE)
    return start, start + following.start() if following else len(text)


def _add_changelog_entry(repo_root: Path, current: str, target: str) -> None:
    path = repo_root / "CHANGELOG.md"
    text = path.read_text(encoding="utf-8")
    entry = (
        f"- RouterOS CHR compatibility was bumped from {current} to {target} after "
        "the full Docker integration suite passed.\n"
    )

    # This used to require the literal "## [Unreleased]\n\n### Changed\n\n",
    # which meant Changed had to be the *first* subsection. It never was, so the
    # bump step could not have worked even once the candidate test was fixed -
    # any ordinary "### Added" entry above it was enough to break the release
    # automation. Find the section wherever it sits, and create it in Keep a
    # Changelog order when it is absent.
    start, end = _unreleased_span(text)
    body = text[start:end]

    # [ \t]* rather than \s*, so end() lands at the end of the heading line
    # instead of somewhere inside the blank lines after it. Getting that wrong
    # put a blank line between two list items, which markdownlint fails as
    # MD012 - a bump that turns the repository red is not a working bump.
    existing = re.search(r"^### Changed[ \t]*$", body, re.MULTILINE)
    if existing:
        rest = body[existing.end() :].lstrip("\n")
        # A blank line after the heading, the entry, then whatever was there.
        # A following heading needs its own blank line; a bullet must not have
        # one, or the list splits in two.
        separator = "\n" if rest.startswith("#") or not rest else ""
        new_body = body[: existing.end()] + "\n\n" + entry + separator + rest
    else:
        section = "### Changed\n\n" + entry
        later = None
        for name in CHANGELOG_SECTIONS[CHANGELOG_SECTIONS.index("Changed") + 1 :]:
            later = re.search(rf"^### {name}[ \t]*$", body, re.MULTILINE)
            if later:
                break
        if later:
            new_body = body[: later.start()] + section + "\n" + body[later.start() :]
        else:
            new_body = body.rstrip("\n") + "\n\n" + section
            if end < len(text):
                new_body += "\n"

    path.write_text(text[:start] + new_body + text[end:], encoding="utf-8")


def bump_version(target: str, repo_root: Path = REPO_ROOT, digest: str | None = None) -> None:
    """Bump the pin, the docs and the changelog.

    `digest` exists so this stays unit-testable: passing one skips the download,
    which is the only part of a bump that needs the network.
    """
    target = validate_version(target)
    version_file = repo_root / VERSION_FILE.relative_to(REPO_ROOT)
    current = read_pinned_version(version_file)
    if version_key(target) <= version_key(current):
        raise ReleaseError(f"target {target} must be newer than the pinned version {current}")
    changelog = repo_root / "CHANGELOG.md"
    # Fail before the download rather than after it. Only the heading is
    # required now; the Changed section is created if it is not there.
    _unreleased_span(changelog.read_text(encoding="utf-8"))
    # Hash the new archive before touching anything. A bump that moved the
    # version but left the old digest behind would fail every subsequent CHR
    # build with a checksum mismatch that looks like a supply-chain alarm.
    digest = validate_sha256(digest) if digest else compute_sha256(target)

    _replace_documented_version(repo_root, current, target)
    _add_changelog_entry(repo_root, current, target)
    text = version_file.read_text(encoding="utf-8")
    version_file.write_text(
        text.replace(f"ROUTEROS_VERSION={current}", f"ROUTEROS_VERSION={target}"),
        encoding="utf-8",
    )
    _write_pinned_sha256(digest, version_file)


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


def _record_hash(args: argparse.Namespace) -> int:
    version = validate_version(args.version) if args.version else read_pinned_version()
    digest = compute_sha256(version)
    # --print exists for the candidate test, which needs the digest of a version
    # this repository has never pinned and must not rewrite the pin to get it.
    # Bare digest on stdout so a caller can assign it directly.
    if args.print_only:
        print(digest)
        return 0
    _write_pinned_sha256(digest)
    print(f"recorded SHA-256 for RouterOS {version}: {digest}")
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
    bump.add_argument(
        "--digest",
        help="record this SHA-256 instead of downloading again; pass the digest "
        "the candidate test actually ran against",
    )
    bump.set_defaults(func=lambda args: (bump_version(args.version, digest=args.digest), 0)[1])

    record = subparsers.add_parser(
        "record-hash",
        help="download the pinned CHR archive and record its SHA-256",
    )
    record.add_argument(
        "--version",
        help="hash this version instead of the currently pinned one",
    )
    record.add_argument(
        "--print",
        dest="print_only",
        action="store_true",
        help="print the digest instead of writing it to the version file",
    )
    record.set_defaults(func=_record_hash)
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

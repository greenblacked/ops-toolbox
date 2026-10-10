"""MkDocs hook: pull ROADMAP.md and CHANGELOG.md into their site pages."""

import os
import posixpath
import re

from markdown.extensions.toc import slugify as toc_slugify
from mkdocs.exceptions import PluginError

REPO_URL = "https://github.com/greenblacked/ops-toolbox"
BLOB = REPO_URL + "/blob/master/"
TREE = REPO_URL + "/tree/master/"

# Root files a page may include; anything else is rejected so a marker cannot
# read or publish arbitrary files.
ALLOWED = frozenset({"ROADMAP.md", "CHANGELOG.md"})

MARKER = re.compile(r"^<!-- repo-file: (\S+) -->[ \t]*$", re.MULTILINE)
BREADCRUMB = re.compile(r"^\[Ops Toolbox\]\(README\.md\) / \*\*.*\*\*[ \t]*$")
FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$")
# A code span, or an inline link/image target; only the latter is rewritten.
INLINE = re.compile(r"(`+[^`]*`+)|(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
REFDEF = re.compile(r"^(\s{0,3}\[[^\]]+\]:\s*)(\S+)(.*)$")


def _github_slug(text):
    text = re.sub(r"[*`]", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]", r"\1", text)
    text = re.sub(r"[^a-z0-9 _-]", "", text.lower())
    return text.replace(" ", "-")


def _anchor_map(lines):
    """Map GitHub heading slugs to the slugs the MkDocs toc extension makes."""
    mapping = {}
    seen_gh = {}
    seen_md = {}
    in_fence = False
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        match = None if in_fence else HEADING.match(line)
        if not match:
            continue
        text = match.group(1)
        gh = _github_slug(text)
        plain = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
        plain = re.sub(r"\[([^\]]*)\]", r"\1", plain)
        md = toc_slugify(re.sub(r"[*`]", "", plain), "-")
        n = seen_gh.get(gh, 0)
        seen_gh[gh] = n + 1
        m = seen_md.get(md, 0)
        seen_md[md] = m + 1
        gh_final = gh if n == 0 else "%s-%d" % (gh, n)
        md_final = md if m == 0 else "%s_%d" % (md, m)
        mapping[gh_final] = md_final
    return mapping


def _rewrite_target(root, target, anchors):
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("//"):
        return target
    if target.startswith("#"):
        frag = target[1:]
        return "#" + anchors.get(frag, frag)
    path, _, frag = target.partition("#")
    norm = posixpath.normpath(path)
    is_dir = path.endswith("/") or os.path.isdir(os.path.join(root, norm))
    url = (TREE if is_dir else BLOB) + norm.strip("/") + ("/" if is_dir else "")
    return url + ("#" + frag if frag else "")


def _convert(root, text):
    lines = text.splitlines()
    anchors = _anchor_map(lines)
    out = []
    in_fence = False
    dropped_h1 = False
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue
        if not dropped_h1 and line.startswith("# "):
            dropped_h1 = True
            continue
        if BREADCRUMB.match(line):
            continue

        def inline(m, anchors=anchors):
            if m.group(1):
                return m.group(1)
            return m.group(2) + _rewrite_target(root, m.group(3), anchors) + m.group(4)

        line = INLINE.sub(inline, line)
        ref = REFDEF.match(line)
        if ref:
            line = ref.group(1) + _rewrite_target(root, ref.group(2), anchors) + ref.group(3)
        out.append(line)
    return "\n".join(out).strip("\n") + "\n"


def on_page_markdown(markdown, page, config, files):
    root = os.path.dirname(os.path.abspath(config["config_file_path"]))

    def fill(match):
        name = match.group(1)
        marker = match.group(0).strip()
        if name not in ALLOWED:
            raise PluginError(
                "%s in %s: %r is not an allowed root file (allowed: %s)"
                % (marker, page.file.src_path, name, ", ".join(sorted(ALLOWED)))
            )
        path = os.path.realpath(os.path.join(root, name))
        if os.path.commonpath([os.path.realpath(root), path]) != os.path.realpath(root):
            raise PluginError(
                "%s in %s: %r resolves outside the repository root"
                % (marker, page.file.src_path, name)
            )
        # Edit the source file, not the stub page that holds the marker.
        page.edit_url = REPO_URL + "/edit/master/" + name
        with open(path, encoding="utf-8") as handle:
            return _convert(root, handle.read())

    return MARKER.sub(fill, markdown)

---
name: docs-and-changelog
description: How documentation works here - the two-level README rule (folder README plus the matching root README section), the Keep a Changelog [Unreleased] format and the entry voice that explains the defect rather than naming the file, the markdownlint configuration including MD024 siblings_only which bites changelog edits, and the doc-drift checks that fail a suite. Use this whenever you edit any README, CHANGELOG.md, CONTRIBUTING.md or other Markdown here, or when a change needs documenting.
---

# Documentation in this repository

## The two-level rule

Every script is documented twice, and the pull request checklist asks about
both:

- Its **folder README** (`git/README.md`, `mikrotik/README.md`, ...) - the
  detail: what it does, its flags, its exit codes, how to run it.
- The **root README** section for that package - the one-line "at a glance"
  entry, so someone scanning the repository sees it exists.

The root README's own structure is worth respecting rather than appending to:
a Contents list, a "What's here" folder table, per-package "at a glance"
sections, then Testing and Continuous integration tables. A new package needs a
row in the folder table, a Contents entry, and its own section.

## The changelog

`CHANGELOG.md` follows Keep a Changelog. There is no tag yet, so nothing
carries a release number; dated sections are reconstructed from merge commits
and are history, not releases. New work goes under `## [Unreleased]` in the
matching `### Added` / `### Changed` / `### Fixed` subsection.

Entries here are **prose that explains the defect**, not a line naming the
file. The existing ones read like this:

```text
- `stay_fresh.sh --prune-docker-volumes`. Volume pruning was part of the
  default Docker step; volumes hold data, not cache - a stopped project's
  database volume counts as "unused" the moment its container is removed, and
  the LaunchAgent runs the script with `--yes`, so every scheduled run deleted
  such volumes unattended.
```

That is the voice to match: what changed, what the old behaviour was, and what
went wrong because of it. An entry a reader cannot act on is not worth the
line.

## Markdown linting

`.markdownlint-cli2.yaml` sets `default: true` with `MD013` (line length) and
`MD036` off, and `MD024` set to `siblings_only`.

**`MD024: siblings_only` is the one that bites changelog edits.** Repeated
headings are fine under different parents - every dated section may have its
own `### Fixed` - but two `### Fixed` under the *same* section is a failure.
When adding to `[Unreleased]`, extend the existing subsection rather than
opening a second one with the same name.

The rest of the default rule set still applies and is easy to trip:

- Blank line above and below every heading, list and fenced code block.
- A language on every fenced block (`bash`, `powershell`, `text`, `json`).
- One `#` heading per file, no trailing whitespace, file ends with a newline.

Check before pushing - this runs in the Lint job, which `run-tests.sh` does not
cover:

```bash
npx --yes markdownlint-cli2 "**/*.md"
```

## Docs are tested, in places

`mikrotik/tests/test_lua_conventions.sh` checks that the RouterOS
documentation has not drifted from the script set, and
`windows/tests/contract.ps1` checks that every flag the Windows READMEs
document actually exists. A README claim there is an assertion, so fix the
document and the code together or the suite tells you which one you forgot.

## Voice

The documents here explain **why**, with the file and line that establishes
each rule, and they say plainly when a rule exists because something broke.
`CONTRIBUTING.md` opens by inviting you to delete a rule the scripts do not
actually follow. Keep that tone: concrete, cited, and honest about defects
rather than aspirational.

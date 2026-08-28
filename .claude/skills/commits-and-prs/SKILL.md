---
name: commits-and-prs
description: Git workflow for this repository - the commit authorship and the strict no-tooling-attribution rule (no Co-Authored-By, no session links, no generated-with footers, no vendor or model names anywhere in the tree), the type(scope) commit subject format, the typed branch prefixes CI actually filters on, and what the pull request template expects. Use this before committing, branching, pushing or opening a pull request here, and whenever writing a commit message, PR body or review comment for this repository.
---

# Commits, branches and pull requests

## Authorship and attribution

Commits are authored and committed as the repository owner:

```bash
git config user.name  "Serhii Zolotov"
git config user.email "zolotov.98@gmail.com"
```

**No tooling attribution anywhere in the repository or on GitHub.** No
`Co-Authored-By:` trailer naming an assistant, no session-link trailer, no
"Generated with ..." footer in pull request bodies or comments, and no vendor
or model name in commit messages, code comments, changelog entries or
documentation. This holds even when the surrounding tooling appends such a
footer by default - strip it before the commit or the post goes out.

## Commit subjects

`type(scope): imperative summary`, lowercase, no trailing period. Types in use:
`feat`, `fix`, `chore`, `docs`, `test`, `ci`. The scope is the package -
`macos`, `windows`, `mikrotik`, `shell` - and is omitted for repository-wide
changes.

The summary says what changed *and why it matters*, not just where. From the
history:

```text
fix(macos): lock stay_fresh across contexts, keep docker volumes by default
fix(mikrotik): test the candidate against its own digest, not the pin
test(windows): catch on Linux the two failures that reached master
chore: drop the dead alias mappings from .mailmap
```

Body paragraphs are wrapped prose explaining the reasoning, in the same voice
as `CONTRIBUTING.md`: state the defect, then the fix. If a change exists
because something reached `master`, say so - that sentence is why the next
person keeps the guard.

## Branches

Typed prefixes, and CI's pull-request filter is keyed to them: `feat/`, `fix/`,
`chore/`, `ci/` (`feature/` is kept so the older prefix does not silently lose
coverage). A pull request targeting a branch that matches none of these runs
nothing and merges green, so a new prefix means editing
`.github/workflows/ci.yml` in the same change.

`master` is the default branch. Automation never writes to it directly - the
RouterOS bump workflow opens a `chore/routeros-VERSION` pull request instead.

## Pull requests

`.github/pull_request_template.md` is a form, and its questions are the ones
that catch real defects here. Fill it in honestly:

- **What changed** - one or two sentences, and for which package.
- **Which suites did you run** - delete the ones you did not run. Do not tick a
  suite that skipped itself for a missing `pwsh` or Docker daemon.
- **Dry-run output** - paste it for any new or changed script that touches a
  machine.
- The checklist: `--help` exits 0 before any preflight, an unknown flag exits
  3, running twice is safe, anything destructive is behind an opt-in flag, and
  **both the folder README and the root README were updated**.

Pull requests land as merge commits - `Merge pull request #4 from
greenblacked/feature/stay-fresh` - so every commit on the branch stays in the
history under its own subject. Keep each one coherent on its own rather than
leaving a trail of fixups for a squash that is not coming.

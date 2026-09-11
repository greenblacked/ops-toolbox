# Changelog fragments

[Ops Toolbox](../README.md) / **Changelog fragments**

One file per change, so two pull requests never edit the same line of
`CHANGELOG.md`.

Every entry used to be inserted at the top of `[Unreleased]`. That is one
line in one file, so any two branches open at the same time conflicted the
moment one of them merged, and the resolution was always "keep both". A
fragment is that entry as its own file; the script beside it pastes them
into the section in the order Keep a Changelog uses.

## Writing a fragment

Put it under the directory named for its type:

| Directory | Section |
| --- | --- |
| `added/` | Added |
| `changed/` | Changed |
| `deprecated/` | Deprecated |
| `removed/` | Removed |
| `fixed/` | Fixed |
| `security/` | Security |

Name it after the change, `changelog.d/added/clone-repos.md`, and write it
exactly as it will appear in `CHANGELOG.md`: a list item (a dash, a space,
the text), continuation lines indented two spaces, in the voice the entries there
already use (what changed and why it mattered, not a commit subject). A
fragment can hold more than one item. It has no heading; the directory is
the heading.

```markdown
- `git/clone-repos.sh` clones every repository listed in a text file into
  one parent directory. A checkout that is already there is skipped, an
  occupied path is reported and left alone, and one bad line never stops
  the rest.
```

The entries that were already under `[Unreleased]` before this directory
existed stay in `CHANGELOG.md`; the first release moves them along with the
fragments.

## `changelog.sh`

```bash
changelog.d/changelog.sh preview                       # the section as it will read
changelog.d/changelog.sh check                         # every fragment would paste cleanly
changelog.d/changelog.sh release 1.0.0 --dry-run       # what a release would rewrite
changelog.d/changelog.sh release 1.0.0 --date 2026-10-01
```

| Command | What it does |
| --- | --- |
| `preview` | Prints `[Unreleased]` as it will read: the fragments first, then whatever the section already holds, type by type. Writes nothing. |
| `check` | Validates every fragment (type directory, `.md`, starts with a dash and a space, two-space continuations, no headings, no tabs, no trailing whitespace, final newline). The static suite runs it, so a fragment that would not paste fails the pull request. |
| `release VERSION` | Moves the fragments and the entries still under `[Unreleased]` under `## [VERSION] - DATE`, leaves `[Unreleased]` empty, and deletes the fragment files. Refuses a version already in the file, and refuses to run while `check` fails. |

| Option | Meaning |
| --- | --- |
| `-n`, `--dry-run` | For `release`: print what would be written and removed, in the `git/` dry-run grammar, and write nothing. |
| `--date DATE` | For `release`: the date to stamp, `YYYY-MM-DD`. Default: today, UTC. |
| `-h`, `--help` | Show the help. Works before anything is read. |

`CHANGELOG_ROOT` points the script at another directory holding a
`CHANGELOG.md` and a `changelog.d/`; the test in
`test-env/static/test_changelog.sh` uses it to run against a scratch copy.

Exit codes: `0` done, `1` a fragment would not paste or the release could not
proceed, `3` bad arguments, `4` nothing to release.

## Cutting a release

```bash
changelog.d/changelog.sh release 1.0.0 --dry-run   # read what will move
changelog.d/changelog.sh release 1.0.0
git add CHANGELOG.md changelog.d
git commit -m "chore: release 1.0.0"
git tag -a v1.0.0 -m "1.0.0"
```

The release commit removes the fragment files, so it is the one commit that
touches many of them at once; open it as its own pull request with nothing
else in it.

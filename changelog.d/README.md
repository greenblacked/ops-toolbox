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
existed stayed in `CHANGELOG.md`; the v0.1.0 release moved them along with the
fragments.

## What `check` reads in your backticks

Two pull requests shipped fragments describing work that was never committed —
a `--legacy-run` opt-in on a script that had none, an `install_apps.sh` that
had "grown `--list-casks` and `--list-formulae`" — and both passed, because
both would have pasted perfectly. `check` now resolves the mechanical half of
a fragment against the tree it ships with. Prose it cannot read; these two
forms it can.

| You write | What `check` asks |
| --- | --- |
| `` `install_apps.sh` ``, `` `linux/stay_fresh.sh` `` — the first word of a span, ending in `.sh`, `.zsh`, `.ps1`, `.psm1`, `.psd1`, `.py`, `.lua`, `.awk` or `.md` | that a file with that name is in this tree |
| `` `--list-casks` `` — a long flag alone in its span | that some script accepts it: one of the scripts the same entry names, or any script in the tree if the entry names none |

Nothing else is a claim, and the forms these fragments already use stay
quiet:

- **Another tool's flag goes in the span with its tool.** `` `brew --cache` ``,
  `` `apt-get --yes` ``, `` `find -delete` ``, `` `git add -A` `` — a span with
  a space in it is a command line, and only its first word can name a file.
  A bare `` `--flag` `` is read as a claim about a CLI in this repository.
- **Single-dash flags are never claimed.** That is where the other tools live.
- **An invocation is not a file name.** `` `./x.sh` `` is prose about the form
  of a usage line.
- **Runtime state is not a source file.** `` `last-run.json` ``,
  `` `history.tsv` `` — only source extensions are looked up.
- **Say it when a change removes something.** "removed", "deleted", "no
  longer", "renamed", "formerly", "retired", "replaced by", "gone" exempt the
  *sentence* they sit in, so an entry can name the file it deleted. The
  sentence, not the entry: "`x.sh` no longer does A. `--b` is the new opt-in"
  still checks `--b`.

A fragment that fails this is not a style problem. It says the branch is
missing the change the entry describes — or that the entry describes it by a
name nobody can find.

## `changelog.sh`

```bash
changelog.d/changelog.sh preview                       # the section as it will read
changelog.d/changelog.sh check                         # every fragment would paste cleanly
changelog.d/changelog.sh release 1.0.0 --dry-run       # what a release would rewrite
changelog.d/changelog.sh release 1.0.0 --date 2026-10-01
changelog.d/changelog.sh latest                        # newest released version
changelog.d/changelog.sh notes 1.0.0                   # that version's section, for release notes
```

| Command | What it does |
| --- | --- |
| `preview` | Prints `[Unreleased]` as it will read: the fragments first, then whatever the section already holds, type by type. Writes nothing. |
| `check` | Validates every fragment twice over: the shape that would paste (type directory, `.md`, starts with a dash and a space, two-space continuations, no headings, no tabs, no trailing whitespace, final newline), and the claims it makes about this tree — see [What `check` reads in your backticks](#what-check-reads-in-your-backticks). The static suite runs it, so a fragment that would not paste, or that describes work this branch does not contain, fails the pull request. |
| `release VERSION` | Moves the fragments and the entries still under `[Unreleased]` under `## [VERSION] - DATE`, leaves `[Unreleased]` empty, and deletes the fragment files. Refuses a version already in the file, a version that is not `MAJOR.MINOR.PATCH`, and one that is not newer than the latest release, and refuses to run while `check` fails. |
| `latest` | Prints the newest released version, the first `## [X.Y.Z]` heading, alone on stdout. The dated history sections have no brackets and never match. Exits 4 when nothing has been released. |
| `notes VERSION` | Prints the body of that version's section, its `###` subsections included and its heading left out, up to the next `##` heading. Exits 1 when the file has no such section. |

| Option | Meaning |
| --- | --- |
| `-n`, `--dry-run` | For `release`: print what would be written and removed, in the `git/` dry-run grammar, and write nothing. |
| `--date DATE` | For `release`: the date to stamp, `YYYY-MM-DD`. Default: today, UTC. |
| `-h`, `--help` | Show the help. Works before anything is read. |

`CHANGELOG_ROOT` points the script at another directory holding a
`CHANGELOG.md` and a `changelog.d/`; the test in
`test-env/static/test_changelog.sh` uses it to run against a scratch copy.

Exit codes: `0` done, `1` a fragment would not paste, the release could not
proceed, or `notes` found no section, `3` bad arguments, `4` nothing to
release or nothing released.

## Cutting a release

A release is prepared and cut in three steps, so every release is a reviewed
pull request and a tag only ever lands on a commit that is already on `master`.
Merging to `master` deploys the stage site, and nothing deploys production until
you cut the release.

1. **Prepare.** *Actions → Release prepare → Run workflow*
   ([`release-prepare.yml`](../.github/workflows/release-prepare.yml)), from
   `master`, with the version (`1.0.0`). The workflow refuses a version that is
   not `MAJOR.MINOR.PATCH`, is not newer than the latest release, or already has
   a tag or a `release/<version>` branch. It runs `changelog.sh release` on a
   new `release/<version>` branch and pushes it with one commit,
   `release: <version>`. It does not open a pull request: one opened with the
   workflow's token starts no checks. The run's summary links to the
   compare page; **you open the pull request from the pushed branch**, titled
   `release: <version>`, so it gets its checks like any other. The release
   commit removes every fragment file, so it is the one commit that touches many
   of them at once, and nothing else goes in it.
2. **Merge that pull request**, once its checks are green. `master` gets the
   `## [<version>]` heading and the stage site deploys, as for any change.
   Nothing is tagged and production is untouched.
3. **Cut the release.** When stage looks right, *Actions → Release → Run
   workflow* ([`release.yml`](../.github/workflows/release.yml)), from `master`,
   with the same version. It checks that `master`'s HEAD has the version's
   heading, that it is the newest release, and that CI and Security (and the
   docs site, when it ran) passed on HEAD. It then tags HEAD `v<version>`
   (annotated), creates a GitHub Release whose notes are
   `changelog.sh notes <version>`, and deploys production. Notes too long for a
   release description, which the first release's are, are replaced by a link to
   the section at the tag, and the full notes are attached to the release as a
   file.

Run step 3 from the `master` head that carries the release commit, or a later
one: the tag goes on whatever HEAD is when you run it, and the run refuses if
`master` moves while it is running. If tagging succeeded and publishing the
release or the deploy did not, re-run that same run (or start it again on the
same commit): a tag already on the run's commit is kept, and the rest is
finished, even if `master` has moved on meanwhile. If the tag is on an older
commit than `master`'s HEAD, finish by hand: `gh release create vX.Y.Z
--verify-tag --notes-file <(changelog.d/changelog.sh notes X.Y.Z)`, then
`gh workflow run docs.yml --ref vX.Y.Z`.

By hand, the same thing is:

```bash
changelog.d/changelog.sh release 1.0.0 --dry-run   # read what will move
changelog.d/changelog.sh release 1.0.0
git add CHANGELOG.md changelog.d
git commit -m "release: 1.0.0"
# open it as its own pull request; once merged, on master (what step 3 does):
git tag -a v1.0.0 -m "1.0.0" && git push origin v1.0.0
```

To withdraw a release, delete the GitHub Release and then the tag
(`git push origin :refs/tags/v1.0.0`). The `CHANGELOG.md` section stays; the
next release is cut as a newer version rather than reusing the number.

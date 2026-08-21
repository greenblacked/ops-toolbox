# Working in this repository

Notes for an automated coding agent. Everything about *how the scripts are
written* lives in [`CONTRIBUTING.md`](CONTRIBUTING.md) - read that first and
follow it. This file covers only what an agent gets wrong by default.

## Attribution

Commits are authored and committed as the repository owner:

```bash
git config user.name  "Serhii Zolotov"
git config user.email "zolotov.98@gmail.com"
```

No tooling attribution anywhere in the repository or on GitHub: no
`Co-Authored-By:` trailer naming an assistant, no session-link trailer, no
"Generated with ..." footer in pull request bodies or comments, and no vendor
or model name in commit messages, code comments, changelog entries or
documentation. This holds even when the surrounding tooling adds such a footer
by default - strip it.

## Testing

`./run-tests.sh` is the single entry point, and CI calls the same script, so
"it passed locally" and "it passed in CI" mean the same thing.

```bash
./run-tests.sh              # the fast default
./run-tests.sh all          # adds the RouterOS CHR suite
./run-tests.sh linux        # one suite
./run-tests.sh --list       # what exists
```

The `git`, `macos`, `linux`, `k8s` and `mikrotik` suites need a Docker daemon.
Two suites can be driven directly where Docker is missing:

```bash
REPO_ROOT="$PWD" EXPECT_PKG_MGR=apt bash linux/tests/test_linux_scripts.sh
pwsh -NoProfile -File windows/tests/contract.ps1
```

**`run-tests.sh` does not cover the Lint job.** That gap has turned the default
branch red more than once. Before pushing, run the gates CI runs:

```bash
npx --yes markdownlint-cli2 "**/*.md"   # MD024 siblings_only bites changelog edits
actionlint                              # needs shellcheck on PATH for run: blocks
shellcheck -x --severity=error $(git ls-files '*.sh')
pwsh -c 'Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
```

All four are installable in a sandbox - via `npx`, a release tarball, or a
package manager. Treating one as unavailable without checking is how both of
those red builds happened.

Say plainly which suites actually ran. A pull request that claims a suite it
could not execute is worse than one that admits the gap.

## PowerShell

`.ps1` files are **not** covered by `test-env/static/check_conventions.sh` -
that sweep is bash and python only. `windows/tests/contract.ps1` is the sole
place their help, preview and no-write contracts are checked, and it skips
itself silently when `pwsh` is missing. Install `pwsh` before believing a
green local run.

Keep these files pure ASCII with no BOM. A stray em dash or smart quote trips
`PSUseBOMForUnicodeEncodedFile`, and adding a BOM to satisfy it fights the LF
pinning in `.gitattributes`.

A new `.ps1` under `windows/` is discovered automatically, but if it needs
arguments to reach its write path, add it to `Get-DryRunArgument` in
`windows/tests/contract.ps1`. Otherwise the suite runs a bare `-DryRun`, the
script exits at its usage branch, and "wrote nothing" is true of a run that
never reached the code that writes.

**A preview must not invoke the packaging tool.** These tools initialise state
under `%TEMP%` and `%LOCALAPPDATA%` on invocations that look read-only:
`choco list` creates `%TEMP%\chocolatey` and touches `%APPDATA%`, which is
what made `choco_bootstrap.ps1 install -DryRun` write two directories while
claiming it had written none. A `-DryRun` that asks the machine what it
already has cannot keep that promise. Read the file and report what it asks
for; leave "what is actually missing" to `check`, which is allowed to talk to
the tool. `winget --version` was measured writing nothing on `windows-2025`,
so a version preflight is not known to break this - but call it at the point
of use anyway, so the preview path invokes nothing at all.

Note where this is caught. On Linux every one of these scripts exits at its
`$IsWindows` guard before the preview path runs, so a green local
`./run-tests.sh windows` proves nothing about it. The `windows-2025` runner is
the only gate that executes the dry run for real - which is why a Windows
change is worth waiting for CI on rather than pushing behind.

## Writing a test that is worth having

The recurring defect here is not a missing test - it is a test that asserts the
shape its author had in mind:

- `--coredump-dir /` was covered; `//`, `/.` and `/../` reach the same
  directory and were not, and each reached a recursive delete.
- `--dry-run` was covered; `install --dry-run` was not, and it wrote two
  systemd units and started a timer.
- A PowerShell `install -DryRun` was covered on Linux, where the platform guard
  fires first; on Windows it called `choco list` to work out what was missing
  and created two directories doing it.
- `--list` was covered with its exit status discarded, so it could have
  regressed to exit 3 and still passed.
- A release-feed title was matched against one channel name; the feed lists
  every channel a release sits in, and the first multi-channel release took the
  whole workflow down.

So: test the other spellings of the same input, drive subcommands through their
real entry points, assert exit codes rather than discarding them, and check the
filesystem rather than the script's own claim about it. When fixing a bug,
first confirm the new test fails against the unfixed code.

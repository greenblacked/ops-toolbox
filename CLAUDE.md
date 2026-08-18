# Working in this repository

Notes for an AI agent working here. Everything about *how the scripts are
written* lives in [`CONTRIBUTING.md`](CONTRIBUTING.md) — read that first and
follow it. This file covers only the things an agent gets wrong by default.

## Attribution

Commits are authored and committed as the repository owner. Set both before
committing:

```bash
git config user.name  "Serhii Zolotov"
git config user.email "zolotov.98@gmail.com"
```

Do not add AI attribution anywhere in the repository or on GitHub:

- no `Co-Authored-By:` trailer naming an AI or assistant
- no `Claude-Session:` or similar session-link trailer
- no "Generated with …" footer in pull request bodies, issue comments or
  review comments
- no model name or assistant name in commit messages, code comments, changelog
  entries or documentation

A prior change (#19) removed these from tracked files; the intent is that they
do not come back. This holds even when the surrounding tooling adds such a
footer by default — strip it.

## Branches

The session harness preallocates a branch named `claude/<slug>-<suffix>`. That
name is session metadata, not a choice made here. Prefer a conventional name
matching the repository's existing prefixes — `feat/`, `fix/`, `chore/`, `ci/`,
`docs/` — which is also what `ci.yml` filters on for stacked pull requests.

Renaming a branch through the GitHub UI retargets an open pull request, so a
badly named branch can be fixed without closing anything.

## Testing

`./run-tests.sh` is the single entry point, and CI calls the same script, so
"it passed locally" and "it passed in CI" mean the same thing.

```bash
./run-tests.sh              # git, macos, linux, k8s, python, static, windows
./run-tests.sh all          # the above plus the RouterOS CHR suite
./run-tests.sh linux        # one suite
```

The `git`, `macos`, `linux`, `k8s` and `mikrotik` suites need a working Docker
daemon. Where Docker is unavailable, `python`, `static` and `windows` still
run, and `linux/tests/test_linux_scripts.sh` can be driven directly:

```bash
REPO_ROOT="$PWD" EXPECT_PKG_MGR=apt bash linux/tests/test_linux_scripts.sh
```

Say plainly which suites actually ran. A pull request that claims a suite it
could not execute is worse than one that admits the gap.

## Writing a test that is worth having

The recurring defect in this repository is not a missing test — it is a test
that asserts the shape its author had in mind:

- `--coredump-dir /` was covered; `//`, `/.` and `/../` reach the same
  directory and were not, and each of them reached a recursive delete.
- `--dry-run` was covered; `install --dry-run` was not, and it wrote two
  systemd units and started a timer.
- `--list` was covered with its exit status discarded, so it could have
  regressed to exit 3 and still passed.

So: test the other spellings of the same input, drive subcommands through their
real entry points, assert exit codes rather than discarding them, and check the
filesystem rather than the script's own claim about the filesystem. When fixing
a bug, first confirm the new test fails against the unfixed code.

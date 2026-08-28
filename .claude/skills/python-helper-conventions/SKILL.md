---
name: python-helper-conventions
description: How the Python helpers here are written - standard library only and 3.9-clean because /usr/bin/python3 on macOS is 3.9, read-only diagnostics that print the fixing command instead of applying it, pure logic that takes ambient state as parameters so tests use fixture data, the ruff rule set, and where the unit tests live. Use this whenever you create or edit a .py file in this repository, including the doctors under git/ and mikrotik/ and the library under macos-initial-setup/lib/.
---

# Python helpers in this repository

Start from `templates/new_helper.py`, which is a working no-op that
demonstrates every rule below and is held to the `--help` contract by CI.

## Hard constraints

- **Standard library only. No third-party imports, ever.** These helpers are
  invoked by shell scripts on machines with no virtualenv.
- **3.9-clean.** `/usr/bin/python3` on macOS is 3.9 and that is what CI pins;
  `pyproject.toml` sets `target-version = "py39"` so ruff stops suggesting
  syntax that would break on the machines these run on.
- Shebang is `#!/usr/bin/env python3`, asserted by the static suite. Mode 755
  for a CLI.

## Read-only by design

A diagnostic here **explains and prints the command that fixes the problem**;
it does not edit config, touch an agent, or write a file. `git/git_ssh_doctor.py`
is the reference. This is why the template has no `--dry-run` - there is
nothing to preview.

If you find yourself adding a write path to a doctor, that is a new script, not
a new flag on this one.

## Structure for testability

Keep the interesting logic **pure and taking its input as a string**. Parsers
get unit tests with fixture data; anything that shells out stays untested by
design and lives in a small impure edge - `run()` and `locate()` in the
template.

Inject anything ambient as a parameter: the `PATH` string, a directory, the
current time. A test that reads the host's real `PATH` rots the moment it moves
machines, and one that reads the clock rots with the calendar.

## Exit codes and argparse

`argparse` exits `2` on a usage error, which is its own convention rather than
this repository's `3`. That is accepted, not fought:
`test-env/static/check_conventions.sh` skips `*.py` in its unknown-flag check
and explains why in a comment. `--help` must still exit 0, and that *is*
checked.

Otherwise follow the repository table - `0` success, `4` nothing to report is
the shape the template uses.

## Linting

`pyproject.toml` selects `E,F,I,B,UP,SIM` and ignores `UP031`/`UP032`, so
percent-formatting is deliberate and fine in modules that must stay 3.9-clean
and readable next to the shell scripts calling them.

## Tests

Unit tests live in `test-env/python/tests/` and run under stdlib `unittest`
with no Docker, no venv and no network:

```bash
./run-tests.sh python        # ruff + the tests
./test-env/python/run.sh
```

Those tests insert the lib directory on `sys.path` before importing what they
test, so `E402` is ignored for that directory in `pyproject.toml` - the import
genuinely cannot move to the top of the file.

## The one place shared Python code is allowed

`macos-initial-setup/lib/workspace_scan.py` is a substantial program with its
own tests, invoked as a subprocess by absolute path. That is the only sanctioned
shape for shared code in this repository, and note what it costs the caller:
`macos-initial-setup/stay_fresh.sh:44-50` carries a seven-line
symlink-resolving preamble whose only job is finding it. Worth paying once for
a real program with real tests; never for a small validator, which gets
duplicated instead.

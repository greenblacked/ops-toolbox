---
name: adding-a-script
description: The end-to-end checklist for shipping a brand-new script here - picking the template and package, the file mode and .gitattributes rule, the dry_run_args table entry a subcommand-driven script needs, tests, and the folder README, root README and CHANGELOG entries a change is not finished without. Use this whenever you add a new .sh, .ps1, .py or RouterOS .lua file to this repository, or when asked what a new script needs before it can be merged.
---

# Adding a new script

A new script here is not finished when it runs. It is finished when it is
discovered by the suites, documented in two places, and its dry run has been
proven against the filesystem. Work the list in order.

## 1. Pick the package and the template

```bash
cp templates/new_script.sh git/git_my_new_helper.sh   # bash
cp templates/new_script.ps1 windows/setup/my_thing.ps1
cp templates/new_helper.py git/my_doctor.py
chmod +x path/to/the/new/script
```

The templates are working no-ops, not sketches - run them first
(`--help`, `--dry-run`, `--quiet`) to see the expected output grammar. Then
open the language skill for the body: `bash-script-conventions`,
`powershell-script-conventions`, `python-helper-conventions`, or
`routeros-script-conventions`.

The package decides more than the directory. It fixes the `set` dialect, the
dry-run output grammar, whether the script writes a log file, and whether Bash
3.2 applies. Do not mix grammars across packages; a genuinely new top-level
package picks one in its README and sticks to it.

## 2. Make it discoverable

`test-env/lib/discover_clis.sh` finds a script when it is **tracked, mode
`755`, has a shebang on line 1, and is not under `tests/` or `test-env/`**. All
four legs matter - a script missing one is silently uncovered rather than
loudly failing.

- `git add` it before running the static suite; discovery reads the index.
- Executable means shebang. A sourced file (`*.zsh`, `*.aliases`) has neither
  and is mode `644`.
- If you introduce a **new file extension**, add a rule to `.gitattributes`
  pinning it to LF. The patterns are path-anchored, so a rule naming
  `windows/git-bash/.bashrc` does not match a nested copy - confirm with
  `git check-attr eol -- <path>`.

## 3. Reach the main path in the dry-run check

`test-env/static/check_conventions.sh` runs every `--dry-run`-capable CLI
against a scratch `HOME` and `TMPDIR` and diffs the filesystem. If your script
needs more than a bare `--dry-run` to get past argument parsing - a subcommand,
a required `--file`, a target argument - add an entry to `dry_run_args()`:

```bash
git/git_hooks_install.sh)                printf '%s\n' "install --dry-run" ;;
macos-initial-setup/brewfile.sh)         printf '%s\n' "dump --file @SCRATCH@/Brewfile --dry-run" ;;
```

`@SCRATCH@` expands to the scratch `TMPDIR`, so an output path stays inside the
snapshot instead of escaping it or landing in the working tree. Without an
entry the script exits 3 at its usage branch; the check now treats that as a
gap and fails, because "wrote nothing" was true of a run that never reached the
code that writes.

A new `.ps1` needs the equivalent in `Get-DryRunArgument` in
`windows/tests/contract.ps1`.

## 4. Tests

The static and contract suites cover the shape for free. Behaviour is yours to
add, in the package's own suite, in the hand-rolled style described by the
`running-tests` skill. Do not add a hardcoded script list to a test - the
per-package lists are exactly what rotted before discovery existed.

```bash
./run-tests.sh static
./run-tests.sh <package>
```

## 5. Documentation - both levels

The pull request checklist asks for this explicitly, and a missing entry is the
most common thing left out:

- The **folder README** gets the script in its table or list, with what it does
  and its notable flags.
- The **root README** gets it in the matching "at a glance" section.
- `CHANGELOG.md` gets an entry under `[Unreleased]`. See the
  `docs-and-changelog` skill for the format and the markdownlint rule that
  bites here.

RouterOS scripts have a documentation-drift check in
`mikrotik/tests/test_lua_conventions.sh`, so a missing README row there fails
the suite rather than merely aging badly. A batch of twelve scripts once landed
with no tests and no README entry; that check is the reply.

## 6. Final pass

- `--help` exits 0 before any preflight, on any platform.
- An unknown flag exits 3 with a message on stderr.
- Running it twice is safe and produces the same result.
- Anything destructive is behind an explicit opt-in flag.
- The lint gates in the `pre-push-gates` skill, which `run-tests.sh` does not
  cover.

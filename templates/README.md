# Templates

Starting points for new scripts. Copy one, rename it, delete what you do not
need.

| File | For |
| --- | --- |
| [`new_script.sh`](new_script.sh) | A Bash helper in `git/`, `macos-initial-setup/`, or `linux/` |
| [`new_script.ps1`](new_script.ps1) | A PowerShell script in `windows/` |
| [`new_helper.py`](new_helper.py) | A Python diagnostic, alongside `git_ssh_doctor.py` and `router_doctor.py` |

All three are **working no-ops**, not sketches. They are tracked, so the
repository's own checks run against them: `new_script.sh` and `new_helper.py`
get the same `--help` contract every other script is held to (plus ShellCheck
and Ruff respectively), and `new_script.ps1` is in the PowerShell contract
suite, which checks that it parses, that its comment-based help is complete,
and that its dry run writes nothing. If a convention in
[`CONTRIBUTING.md`](../CONTRIBUTING.md) drifts away from what the templates do,
CI fails here first.

```bash
cp templates/new_script.sh git/git_my_new_helper.sh
chmod +x git/git_my_new_helper.sh
```

Try them before editing — `./templates/new_script.sh --dry-run` shows the
output grammar, `--help` shows the expected help layout, and
`./templates/new_helper.py` prints the report shape a diagnostic is expected to
produce.

## Which one

`new_script.sh` and `new_script.ps1` are for scripts that **change** a machine:
both are built around the `--dry-run` / `-DryRun` preview that this repository
requires of anything that writes.

`new_helper.py` is the opposite shape — a **read-only diagnostic** that
explains a failure and prints the command that fixes it, the way
[`git/git_ssh_doctor.py`](../git/git_ssh_doctor.py) does. It has no dry run
because it has nothing to preview. Its structure is the part worth copying: the
pure functions take the PATH string and the command output as parameters rather
than reading them, so they can be unit-tested with fixture data, and the two
functions that touch the machine are kept together and left untested by design.
Python here means the standard library only, and 3.9-clean, because
`/usr/bin/python3` on macOS is 3.9.

There is no RouterOS template. Those scripts vary too much in shape to have a
useful skeleton; start from the closest existing script in
[`../mikrotik/`](../mikrotik/) instead, and read the RouterOS section of
[`CONTRIBUTING.md`](../CONTRIBUTING.md) for the rules that do apply — secrets in
`:global`, alert on transitions, fail safe when unconfigured.

# Templates

Starting points for new scripts. Copy one, rename it, delete what you do not
need.

| File | For |
| --- | --- |
| [`new_script.sh`](new_script.sh) | A Bash helper in `git/`, `macos-initial-setup/`, or `linux/` |
| [`new_script.ps1`](new_script.ps1) | A PowerShell script in `windows/` |

Both are **working no-ops**, not sketches. They are tracked, so the repository's
own checks run against them: `new_script.sh` gets `bash -n`, ShellCheck, and the
same `--help`/unknown-flag contract every other script is held to. If a
convention in [`CONTRIBUTING.md`](../CONTRIBUTING.md) drifts away from what the
templates do, CI fails here first.

```bash
cp templates/new_script.sh git/git_my_new_helper.sh
chmod +x git/git_my_new_helper.sh
```

Try them before editing — `./templates/new_script.sh --dry-run` shows the output
grammar, and `--help` shows the expected help layout.

There is no RouterOS template. Those scripts vary too much in shape to have a
useful skeleton; start from the closest existing script in
[`../mikrotik/`](../mikrotik/) instead, and read the RouterOS section of
[`CONTRIBUTING.md`](../CONTRIBUTING.md) for the rules that do apply — secrets in
`:global`, alert on transitions, fail safe when unconfigured.

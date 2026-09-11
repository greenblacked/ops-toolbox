# Session startup hook

[Ops Toolbox](../../README.md) / **Session startup hook**

What a hosted coding session needs before the first command, so that the
suites and linters in this repository behave the way they do in CI.

| Script | Purpose |
| --- | --- |
| `session-start.sh` | Runs at session start (registered in `../settings.json`). Reads the tool versions from `.github/workflows/ci.yml`, installs ShellCheck, ruff and markdownlint-cli2 at those versions, adds `zsh`, lays out `/repo`, `/.dockerenv`, `/rootonly` and `/rootlocked` so the macOS steps and unprivileged suites run without a Docker daemon, and reinstalls the attribution guard from the user's skills directory. A no-op outside a remote session; `--force` runs it anyway, `--check` reports and changes nothing. `--force` still refuses to plant `/.dockerenv` on a machine that is not a disposable session, because the macOS steps suite reads that file as permission to clear absolute system paths. |

The full description, options and exit codes are in the header of the script
and in the root README under "Remote coding sessions".

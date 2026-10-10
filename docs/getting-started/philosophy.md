# Philosophy

Ops Toolbox is built around one habit: look first, change second.

## Report, preview, apply

Report
:   Reads state and prints a verdict or findings. It writes nothing. Examples:
    `status.sh`, `workstation_doctor.sh`, `hardening_audit.sh`,
    `git_stale_branches.sh`.

Preview
:   Prints what a command would do without doing it. Bash scripts use
    `--dry-run`, PowerShell scripts use `-DryRun`, and `mikrotik/features/export_config.py`
    uses `--stdout` or `--diff`; the other Python tools are read-only. Many scripts that delete or install also need
    `--yes` (`-Yes` in PowerShell) before a real run.

Apply
:   Changes the machine, repository, router or cluster. It is always a
    separate invocation that you choose to run after reading the first two.

```bash
./linux/status.sh                      # report
./linux/disk_cleanup.sh --dry-run      # preview
./linux/disk_cleanup.sh --yes          # apply
```

## Why it exists

Maintenance scripts tend to run with broad permissions against machines you
care about. A script that explains itself before acting is cheaper to trust
than one you have to read end to end. The report tells you whether anything
needs doing; the preview tells you what the script would do about it.

## Each preview has its own scope

There is no global dry-run. The conventions differ by platform:

| Platform | Preview |
| --- | --- |
| Bash writers | `--dry-run` |
| PowerShell | `-DryRun` |
| `export_config.py` | `--stdout` or `--diff` |
| Other Python tools | Read-only diagnostics, no flag needed |
| RouterOS `.lua` scripts | None. They take no flags; read the source, or run `print_schedulers.sh` on your computer. |
| Read-only reports | No flag needed |

!!! warning "A dry run is not the real run"
    `k8s-toolbox/build.sh --dry-run` prints the buildx command; it does not
    exercise the build. Some scripts have no preview at all, for example
    `git/git_recent_branches.sh --switch`, which checks out a branch. The
    platform pages and `--help` say which.

## Scripts do not enforce policy

These scripts report and automate chores. They do not enforce firewall,
security or compliance policy for you.

!!! danger "Alerts are not enforcement"
    RouterOS `security_check.lua` only reports. Blocking or redirecting
    traffic with scripts such as `mac_allowlist_dhcp.lua`,
    `rogue_dns_check.lua` or `brute_force_block.lua` additionally needs an
    enabled firewall rule. A script that populates an address list protects
    nothing until a rule uses that list.

The same applies to a schedule: a timer runs a script at configured times, it
does not by itself guarantee a policy holds between runs.

## Modularity

A script must still work when copied on its own into `~/bin`. That is why
helper code is copied between scripts rather than shared through a library.
The single exception is a substantial, separately tested program invoked as a
subprocess, such as the helpers under `macos-initial-setup/lib/`.

## Minimal dependencies

Bash scripts target Bash 3.2, the version that ships as `/bin/bash` on macOS.
Python helpers use the standard library only (Python 3.9+). Tools such as
`kubectl`, `gcloud`, `docker` or `winget` are required only by the scripts that
drive them.

## Honest about testing

CI covers a lot, and it does not cover everything. The
[testing page](../contributing/testing.md) lists what is checked in CI and what
you must still verify on the target system.

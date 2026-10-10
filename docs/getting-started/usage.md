# Installation and usage

There is no installer for the whole toolbox. You either work from a clone or
copy the one file you need.

## Work from a clone

```bash
git clone https://github.com/greenblacked/ops-toolbox.git
cd ops-toolbox
./linux/status.sh --help
```

## Copy a single file into ~/bin

Each script is self-contained, so one file is enough.

```bash
mkdir -p ~/bin
cp git/git_whoami.sh ~/bin/
chmod +x ~/bin/git_whoami.sh
```

Make sure `~/bin` is on your `PATH`, then run `git_whoami.sh` from anywhere.

!!! warning "Some scripts need their neighbours"
    macOS `stay_fresh.sh` calls companion Python programs and needs its
    adjacent `lib/` directory when copied. Copy `macos-initial-setup/lib/`
    next to it. The [macOS page](../platforms/macos.md) has details.

RouterOS `.lua` scripts are not copied to `~/bin`. You paste each one into
`/system script` on the router. See the [MikroTik page](../platforms/mikrotik.md).

## Help on every script

Every script prints usage with `--help` (Bash and Python) or comment-based help
(PowerShell: `Get-Help .\windows\setup\status.ps1`). Start there; it is the
authoritative list of flags.

```bash
./macos-initial-setup/stay_fresh.sh --help
```

## Shell versions

The Bash scripts in `git/`, `macos-initial-setup/`, `linux/` and `dotfiles/`
run under Bash 3.2, the version in `/bin/bash` on macOS. No newer Bash is
required there. Git Bash scripts under `windows/git-bash/` target Bash 5.

## PowerShell execution policy

PowerShell may refuse to start a script under the current execution policy.
Check it first:

```powershell
Get-ExecutionPolicy -List
```

Follow your organization's policy. The Windows README gives two options:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or running a single
script with `powershell -ExecutionPolicy Bypass -File <script>`. Changing the
policy is a separate system decision, not something these scripts do.

## Exit codes

Scripts share a convention. A script may implement a subset and documents any
narrowing in its header.

| Code | Meaning |
| --- | --- |
| `0` | Success, including every `--help`. |
| `1` | Generic failure: the work ran and some of it did not succeed. |
| `2` | Wrong environment: not a git repo, not macOS, a required tool is missing. |
| `3` | Invalid usage: unknown flag, missing value, failed validation. |
| `4` | Domain no-op: nothing to commit, no base branch, dirty tree. In the dotfiles installer it means something was left in place. |
| `5` | Reserved to `gacp.sh` (push from detached HEAD). |

## Running from the repository root

The docs show commands from the repository root. Some platform READMEs in the
repository show paths relative to their own folder; the script names are the
same.

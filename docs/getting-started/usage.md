# Installation and usage

There is no installer for the whole toolbox. You either work from a clone or
copy the file you need.

## Work from a clone

```bash
git clone https://github.com/greenblacked/ops-toolbox.git
cd ops-toolbox
./linux/status.sh --help
```

## Copy a script into ~/bin

Most scripts are self-contained and work when copied alone into `~/bin`.

```bash
mkdir -p ~/bin
cp git/git_whoami.sh ~/bin/
chmod +x ~/bin/git_whoami.sh
```

Make sure `~/bin` is on your `PATH`, then run `git_whoami.sh` from anywhere.

<!-- markdownlint-disable MD046 -->
!!! warning "Some scripts need their package folder"
    These read files that sit next to them, so copy them with those files
    (or work from a clone). The package README on GitHub has the details.

    | Script | Needs, next to it |
    | --- | --- |
    | `dotfiles/install_dotfiles.sh` | the `config/` and `home/` directories; it exits with code 2 without them. See the [dotfiles README](https://github.com/greenblacked/ops-toolbox/blob/master/dotfiles/README.md). |
    | `k8s-toolbox/build.sh` | `versions.env` and the `Dockerfile`. See the [k8s-toolbox README](https://github.com/greenblacked/ops-toolbox/blob/master/k8s-toolbox/README.md). |
    | `macos-initial-setup/stay_fresh.sh` | the `lib/` directory of Python helpers. See the [macOS README](https://github.com/greenblacked/ops-toolbox/blob/master/macos-initial-setup/README.md) and the [macOS page](../platforms/macos.md). |
    | `macos-initial-setup/launchd/stay_fresh_agent.sh` | `stay_fresh.sh` one directory up, and so `lib/`. |
    | `linux/systemd/stay_fresh_timer.sh` | `stay_fresh.sh` one directory up. See the [Linux README](https://github.com/greenblacked/ops-toolbox/blob/master/linux/README.md). |
    | `linux/install_aliases.sh` | `bash_aliases.sh`, unless you pass `--source FILE`. |
    | `linux/packages.sh`, `macos-initial-setup/brewfile.sh` | their default list file (`packages.<manager>.txt`, `Brewfile`); pass `--file` to use another. |
    | `git/git_aliases.sh`, `linux/bash_aliases.sh` | the scripts they alias, next to them or on `PATH`; an alias is defined only if its script is found. |

    When unsure, check the script's `--help` or its package README, or run it
    from a clone.
<!-- markdownlint-enable MD046 -->

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

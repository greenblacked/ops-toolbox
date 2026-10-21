# Dotfiles

## What it covers

Tool configuration for the shell, terminal, Git, GitHub, SSH and GnuPG,
Kubernetes, cloud CLIs and security scanners. One Bash installer links or
copies each tracked file into place and reports drift.

## Requirements

- macOS 12+ or Linux, and Bash 3.2+.
- `git` for the folder's test suite.
- The tools themselves are not installed by these files. Configs are inert
  until the tool is installed; `--only UNIT` limits any mode to the tools you
  have.

## Main scripts

| Script | Purpose | Preview |
| --- | --- | --- |
| `install_dotfiles.sh` | Link (or copy) each tracked config into `$HOME` or `$XDG_CONFIG_HOME`. Modes: `--list`, `--status`, `--diff`, `--uninstall`, `--prune`, `--only UNIT`, `--force`. | `--dry-run` (also on `--uninstall` and `--prune`); `--list`, `--status` and `--diff` are read-only |
| `dotfiles_doctor.sh` | Read-only health report for the installed configs: a credential written through a link into the tracked repository (reported by file and line, never by value), credential file modes, the environment exports four configs need, and the ssh and git overlays. | read-only |

The installer works per file and never links whole directories. `--status`
reports each file as `MATCH`, `DRIFT`, `MISSING`, `FOREIGN` or `CONFLICT`,
and each link into the folder that no tracked file installs to as `ORPHAN`;
`--prune` removes those.

## Examples

=== "Report"

    ```bash
    ./dotfiles/install_dotfiles.sh --list
    ./dotfiles/install_dotfiles.sh --status
    ./dotfiles/install_dotfiles.sh --diff --only k9s   # what a DRIFT copy changed, secrets redacted
    ```

=== "Preview"

    ```bash
    ./dotfiles/install_dotfiles.sh --dry-run
    ./dotfiles/install_dotfiles.sh --dry-run --only @server   # a jump host: no GUI, no k9s
    ```

=== "Check"

    ```bash
    ./dotfiles/dotfiles_doctor.sh
    ./dotfiles/dotfiles_doctor.sh --fail-on warn --quiet
    ```

=== "Apply"

    ```bash
    ./dotfiles/install_dotfiles.sh
    ```

## Limitations and caveats

!!! warning "Nothing is overwritten without --force"
    `--force` moves an existing file to `NAME.backup-TIMESTAMP` first, then
    replaces it.

!!! note "Restoring a backup"
    `--backups` lists what `--force` set aside and `--restore` moves the
    newest back (`--stamp` picks another; the oldest is usually the file
    from before the dotfiles). It acts only where the path is empty or holds
    the installer's own link or an identical copy, and leaves a changed file
    in place with exit 4. Preview it with `--dry-run`.

!!! note "Exit code 4 is not a failure"
    The installer exits 4 when something was left in place.

- Four configs are found only when your shell exports a path; the README has
  the environment variable block. The rest use default locations.
  `dotfiles_doctor.sh` reports each export that is missing or leads nowhere,
  for the tools that are on `PATH`, with the line to add.
- Installs into `~/.ssh` and `~/.gnupg` enforce mode 700 on those directories.
- Some tools are deliberately left out (pnpm, Maven, jfrog, argocd, gcloud
  credentials). The README gives the reasons.
- `dotfiles_doctor.sh` checks that the credential files the package never
  tracks (`~/.aws/credentials`, `~/.kube/config`, gh `hosts.yml` and eight
  more) are not readable or writable by group or other. It only stats them
  and prints the `chmod 600` for you to run. `~/.ssh` is left to
  `linux/ssh_client_doctor.sh`.
- `dotfiles_doctor.sh` also checks the untracked overlays: that `ssh -G`
  accepts `~/.ssh/config`, that `known_hosts` holds no plaintext host while
  `HashKnownHosts` is on, that no dead ControlMaster socket is left, that a
  commit identity is set through `config.local`, and that no `~/.gitconfig`
  overrides the tracked git config. Host names and identity values are never
  printed.

## Repository

- [`dotfiles/`](https://github.com/greenblacked/ops-toolbox/tree/master/dotfiles)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/dotfiles/README.md)

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
| `install_dotfiles.sh` | Link (or copy) each tracked config into `$HOME` or `$XDG_CONFIG_HOME`. Modes: `--list`, `--status`, `--uninstall`, `--only UNIT`, `--force`. | `--dry-run` (also on `--uninstall`); `--list` and `--status` are read-only |

The installer works per file and never links whole directories. `--status`
reports each file as `MATCH`, `DRIFT`, `MISSING`, `FOREIGN` or `CONFLICT`.

## Examples

=== "Report"

    ```bash
    ./dotfiles/install_dotfiles.sh --list
    ./dotfiles/install_dotfiles.sh --status
    ```

=== "Preview"

    ```bash
    ./dotfiles/install_dotfiles.sh --dry-run
    ```

=== "Apply"

    ```bash
    ./dotfiles/install_dotfiles.sh
    ```

## Limitations and caveats

!!! warning "Nothing is overwritten without --force"
    `--force` moves an existing file to `NAME.backup-TIMESTAMP` first, then
    replaces it.

!!! note "Exit code 4 is not a failure"
    The installer exits 4 when something was left in place.

- Four configs are found only when your shell exports a path; the README has
  the environment variable block. The rest use default locations.
- Installs into `~/.ssh` and `~/.gnupg` enforce mode 700 on those directories.
- Some tools are deliberately left out (pnpm, Maven, jfrog, argocd, gcloud
  credentials). The README gives the reasons.

## Repository

- [`dotfiles/`](https://github.com/greenblacked/ops-toolbox/tree/master/dotfiles)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/dotfiles/README.md)

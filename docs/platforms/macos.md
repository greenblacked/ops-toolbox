# macOS

## What it covers

macOS 12+ on Apple Silicon and Intel: app and CLI installs through Homebrew,
Python, Terraform, Go and Helm toolchains, recurring cleanup (`stay_fresh.sh`),
Brewfile capture, preference drift, read-only health and security reports, and
a LaunchAgent that schedules the maintenance run.

## Requirements

- macOS 12 or later, Xcode Command Line Tools, at least 5 GB free on `/`.
- Homebrew (`install_apps.sh` installs it).
- Bash 3.2, which is `/bin/bash`.
- One `sudo` prompt for root-owned steps.
- Docker with Compose v2 only for the folder's test suite.

## Main scripts

| Script | Purpose | Preview |
| --- | --- | --- |
| `status.sh` | One-screen verdict: OS, disk, Homebrew, git identity, agent, FileVault, SIP. | read-only |
| `workstation_doctor.sh` | Long read-only health report. | read-only |
| `hardening_audit.sh` | Security audit with the fix for each finding. | read-only |
| `install_apps.sh` | Homebrew casks, CLI formulae and Google Cloud SDK; `--profile core`, `platform` or `full`. | `--dry-run` |
| `install_devtools.sh` | Python (pyenv), Terraform, Go (goenv), Helm; `--setup-shell` wires `~/.zshrc`. | `--dry-run` |
| `stay_fresh.sh` | Recurring housekeeping and upgrades; presets `--quick`, `--reports`, `--full`, `--old-only`. | `--dry-run` |
| `brewfile.sh` | `dump`, `check`, `install`, `diff` and `cleanup` of the Homebrew state. | `--dry-run` on `install`; `cleanup` previews unless `--force` |
| `macos_defaults.sh` | Report `defaults` values against the desired set; `--apply`, `--revert`. | `--dry-run` with `--apply` or `--revert` |
| `launchd/stay_fresh_agent.sh` | `install`, `uninstall`, `status`, `run-now`, `logs` for a scheduled LaunchAgent. | `--dry-run` on `install` and `uninstall` |
| `zsh_aliases.zsh` | Optional zsh aliases, sourced rather than run. | n/a |
| `v1_stay_fresh.sh` | Deprecated; runs only with `--legacy-run`. | none; use `stay_fresh.sh` |

All paths are under `macos-initial-setup/`.

## Examples

=== "Report"

    ```bash
    ./macos-initial-setup/status.sh
    ./macos-initial-setup/workstation_doctor.sh --skip-brew-doctor
    ./macos-initial-setup/macos_defaults.sh
    ```

=== "Preview"

    ```bash
    ./macos-initial-setup/install_apps.sh --dry-run --verbose
    ./macos-initial-setup/install_devtools.sh --dry-run --verbose
    ./macos-initial-setup/stay_fresh.sh --dry-run
    ./macos-initial-setup/macos_defaults.sh --apply --dry-run
    ```

=== "Apply"

    ```bash
    ./macos-initial-setup/install_apps.sh --yes
    ./macos-initial-setup/stay_fresh.sh --yes --verbose
    ```

## Limitations and caveats

!!! warning "Copying stay_fresh.sh"
    `stay_fresh.sh` needs its adjacent `lib/` directory. It calls companion
    Python helpers and some Homebrew steps. Copy `macos-initial-setup/lib/`
    next to it, or run it from a clone. `launchd/stay_fresh_agent.sh` in turn
    expects `stay_fresh.sh` one directory above it.

!!! warning "Scheduled runs skip root steps"
    Cask upgrades (`--brew-casks`) need an interactive terminal and may ask
    for a password. The LaunchAgent always runs with `--no-sudo --yes`, so
    root steps are skipped on schedule.

!!! warning "Defaults can change between releases"
    Some `macos_defaults.sh` keys are undocumented, can change between macOS
    releases, and some are protected by SIP or TCC and silently do nothing.

!!! danger "v1_stay_fresh.sh"
    The legacy script is deprecated and has broad cleanup, including Xcode
    Archives. A bare invocation prints a notice and exits 3.

- `install_apps.sh` and `install_devtools.sh` need `--yes` for a real run with
  no terminal on stdin. `--dry-run` is unaffected.
- The Docker tests cover syntax, ShellCheck, `--help`, exit codes and
  `stay_fresh.sh` behavior with host commands faked. They cannot run Homebrew
  on macOS; only the `macos-15` CI runner and your own machine do that.

## Repository

- [`macos-initial-setup/`](https://github.com/greenblacked/ops-toolbox/tree/master/macos-initial-setup)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/macos-initial-setup/README.md)

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

<!-- markdownlint-disable MD033 -->

| Script | Purpose | Preview |
| --- | --- | --- |
| `status.sh` | One-screen verdict: OS, disk, Homebrew, git identity, agent, FileVault, SIP; `--json` for a parser. | <span class="stage stage-report">read-only</span> |
| `workstation_doctor.sh` | Long read-only health report. | <span class="stage stage-report">read-only</span> |
| `hardening_audit.sh` | Security audit with the fix for each finding, including credential files at rest (`--only secrets`); `--json` for MDM and CI. | <span class="stage stage-report">read-only</span> |
| `ops_context.sh` | Which Kubernetes context, gcloud project, AWS profile, Terraform workspace, Docker daemon and GitHub login this shell is pointed at; `--warn-on prod` exits 1 on a match. | <span class="stage stage-report">read-only</span> |
| `net_doctor.sh` | Interfaces, default route, split DNS, system proxy against the shell, VPN tunnels, `/etc/hosts` overrides, listeners; opt-in `--probe`. | <span class="stage stage-report">read-only</span> |
| `tls_expiry.sh` | Certificate expiry for PEM files, hosts and (`--keychain`) Keychain client certificates; exit 1 inside `--days`. | <span class="stage stage-report">read-only</span> |
| `schedule_report.sh` | launchd agents and daemons with schedules decoded, crontab and `at` jobs; flags missing programs and writable plists. | <span class="stage stage-report">read-only</span> |
| `ssh_client_doctor.sh` | `~/.ssh` modes, weak and unencrypted keys, missing `IdentityFile` paths, risky `Host *` options. | <span class="stage stage-report">read-only</span> |
| `install_apps.sh` | Homebrew casks, CLI formulae and Google Cloud SDK; `--profile core`, `platform` or `full`. | `--dry-run` |
| `install_devtools.sh` | Python (pyenv), Terraform, Go (goenv), Helm; `--setup-shell` wires `~/.zshrc`. | `--dry-run` |
| `toolchain_check.sh` | Are the Python, Terraform, Go and Node versions a checkout pins installed and active? | <span class="stage stage-report">read-only</span> |
| `stay_fresh.sh` | Recurring housekeeping and upgrades; presets `--quick`, `--reports`, `--full`, `--old-only`. | `--dry-run` |
| `brewfile.sh` | `dump`, `check`, `install`, `diff` and `cleanup` of the Homebrew state. | `--dry-run` on `install`; `cleanup` previews unless `--force` |
| `config_backup.sh` | Dated, verified, rotated archive of the non-secret dotfiles and tool config; credential paths refused unless `--include-secrets`. | `--dry-run`; a real run needs `--yes` |
| `macos_defaults.sh` | Report `defaults` values against the desired set; `--apply`, `--revert`. | `--dry-run` with `--apply` or `--revert` |
| `launchd/stay_fresh_agent.sh` | `install`, `uninstall`, `status`, `run-now`, `logs` for a scheduled LaunchAgent. | `--dry-run` on `install` and `uninstall` |
| `zsh_aliases.zsh` | Optional zsh aliases, sourced rather than run. | n/a |
| `v1_stay_fresh.sh` | Deprecated; runs only with `--legacy-run`. | none; use `stay_fresh.sh` |

<!-- markdownlint-enable MD033 -->

All paths are under `macos-initial-setup/`.

## Examples

=== "Report"

    ```bash
    ./macos-initial-setup/status.sh
    ./macos-initial-setup/workstation_doctor.sh --skip-brew-doctor
    ./macos-initial-setup/macos_defaults.sh
    ./macos-initial-setup/ops_context.sh --warn-on prod,live
    ```

=== "Preview"

    ```bash
    ./macos-initial-setup/install_apps.sh --dry-run --verbose
    ./macos-initial-setup/install_devtools.sh --dry-run --verbose
    ./macos-initial-setup/stay_fresh.sh --dry-run
    ./macos-initial-setup/macos_defaults.sh --apply --dry-run
    ./macos-initial-setup/config_backup.sh --dry-run
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

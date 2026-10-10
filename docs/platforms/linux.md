# Linux

## What it covers

Debian/Ubuntu, Fedora/RHEL and Arch: read-only system, network, TLS,
SSH-client, schedule and hardening reports; recurring maintenance and disk
cleanup; developer tool installs; config backups; package-set capture; sysctl
defaults; a systemd user timer; and a Kali cloud-init profile.

## Requirements

- Linux only. Other operating systems exit with code 2.
- One of `apt`, `dnf` or `pacman`, and Bash 3.2+.
- `sudo` or root for root-only steps.
- A systemd user manager for `systemd/stay_fresh_timer.sh`.
- `openssl` for `tls_expiry.sh`; `flock` and a hard-link-capable destination
  for `config_backup.sh`.
- Docker only for the folder's test suite.

## Main scripts

| Script | Purpose | Preview |
| --- | --- | --- |
| `status.sh` | One-screen verdict; `--only` selects sections. | read-only |
| `system_doctor.sh` | Long health report. | read-only |
| `net_doctor.sh` | Interfaces, routes, DNS, listening sockets; `--probe HOST`. | read-only |
| `hardening_audit.sh` | Security audit with the fix for each finding. | read-only |
| `ssh_client_doctor.sh` | `~/.ssh` permissions and `IdentityFile` problems. | read-only |
| `tls_expiry.sh` | Certificate expiry within `--days`. | read-only |
| `schedule_report.sh` | systemd timers, user crontab, `cron.d`. | read-only |
| `sysctl_defaults.sh` | Report sysctl values; `--apply`, `--revert`. | `--dry-run` with `--apply` or `--revert` |
| `stay_fresh.sh` | Package upgrade and autoremove, journal vacuum, caches, containers. | `--dry-run` |
| `install_devtools.sh` | CLIs, Python, Go, Terraform, Helm via mise or the distro. | `--dry-run` |
| `disk_cleanup.sh` | Temp files, thumbnails; opt-in trash, journal, package cache, docker. | `--dry-run` |
| `config_backup.sh` | Dated tar of `--paths` (default `/etc`) with rotation. | `--dry-run` |
| `packages.sh` | `list`, `dump`, `check`, `diff`, `install` of the explicit package set. | `--dry-run` on `install` |
| `install_aliases.sh` | Add a marked block to `~/.bashrc`; `--status`, `--uninstall`. | `--dry-run` |
| `systemd/stay_fresh_timer.sh` | systemd user timer for `stay_fresh.sh`. | `--dry-run` on `install`; `--print-only` |
| `cloud-init/kali-vm-init.yaml` | cloud-init user-data for a Kali VM. Not a script. | validate with `cloud-init schema` |

All paths are under `linux/`.

## Examples

=== "Report"

    ```bash
    ./linux/status.sh
    ./linux/status.sh --only disk,git
    ./linux/system_doctor.sh --quiet
    sudo ./linux/system_doctor.sh
    ```

=== "Preview"

    ```bash
    ./linux/stay_fresh.sh --dry-run --only caches,containers
    ./linux/disk_cleanup.sh --dry-run
    sudo ./linux/sysctl_defaults.sh --apply --dry-run
    ./linux/config_backup.sh --dry-run
    ```

=== "Apply"

    ```bash
    ./linux/stay_fresh.sh --yes
    ./linux/disk_cleanup.sh --yes
    ./linux/config_backup.sh --yes --paths /etc/ssh,/etc/nginx --keep 5
    ```

## Limitations and caveats

!!! warning "Scheduled runs skip root steps"
    The systemd timer runs as your user with `--yes --no-sudo`. Package
    upgrades, autoremove and journal vacuum are skipped on schedule.

!!! warning "Unrecognized distributions"
    `stay_fresh.sh` exits 2 on a distribution it does not recognise.
    `disk_cleanup.sh` warns and skips package-cache steps.

!!! danger "Backups contain secrets"
    `config_backup.sh` copies `/etc` by default, including `shadow`, `sudoers`
    and SSH host keys. Archives are mode 0600. Store them accordingly.

!!! warning "sysctl changes are live"
    `sysctl_defaults.sh --apply` writes `/etc/sysctl.d/99-ops-toolbox.conf` and
    applies the values live. Its backups go to `/tmp`.

- The Bash scripts avoid `set -e` on purpose: a long maintenance run reports
  what it could not do and continues.
- The Kali profile installs more than 1,500 packages on the red/blue profile in the tested snapshot;
  use at least 64 GB of disk. It configures key-only SSH and prepares UFW
  without enabling it.
- On OrbStack, the `kali:current` image did not include cloud-init when
  checked on 2026-08-12, so the documented `orbctl create` command times out.
  Use an image that ships cloud-init.
- Tests run for real in Debian by default; `LINUX_DISTROS=all` adds Fedora and
  Arch. Real hardware kernel and sysctl effects are not covered.

## Repository

- [`linux/`](https://github.com/greenblacked/ops-toolbox/tree/master/linux)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/linux/README.md)
- [`linux/cloud-init/`](https://github.com/greenblacked/ops-toolbox/tree/master/linux/cloud-init)
- [`linux/systemd/`](https://github.com/greenblacked/ops-toolbox/tree/master/linux/systemd)

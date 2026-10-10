# MikroTik

## What it covers

RouterOS 7.x scripts for backups, Wi-Fi PSK rotation, watchdogs, DHCP and
firewall drift, security audit and Telegram alerts, plus host-side Python and
Bash tools for config export, scheduler generation, router audit and backup
pull. The integration suite boots RouterOS CHR 7.24.5.

## Requirements

- RouterOS 7.x. The CHR suite pins 7.24.5. `change_WIFI_pw.lua` needs 7.13+
  only for the WiFiWave2 (`wifi`) path, and `pull_router_backups.sh` needs the RouterOS 7+ SFTP server.
- Script policy `read,write,policy,test,sensitive,ftp`.
- A Telegram bot token and chat id, set as the `TgBotToken` / `TgChatId`
  globals (recommended) or by editing the placeholders in `tg_send.lua`.
- Host side: Bash 3.2+, Python 3.9+ (standard library), OpenSSH `ssh` and `scp`,
  and `git` for `export_config.py --commit`.

## Main scripts

Router scripts are `.lua` files under `mikrotik/core/` and `mikrotik/features/`.
They take no flags. See the [script overview](../scripts/index.md) for the
full table.

| Script | Purpose | Preview |
| --- | --- | --- |
| `core/tg_send.lua` | Telegram text helper used by the alerting scripts. | none (no flags) |
| `core/backup_update_check.lua` | Back up, then notify of a newer RouterOS. | none (no flags) |
| `features/backup.lua` | Dated backup and export. | none (no flags) |
| `features/security_check.lua` | Read-only hardening audit sent to Telegram. | read-only |
| `features/health_check.lua` | CPU, RAM, disk, temperature watchdog. | none (no flags) |
| `features/export_config.py` | Host: export over SSH, diff, optional git commit. | `--stdout` or `--diff` |
| `features/router_doctor.py` | Host: audit installed, scheduled and configured scripts. | read-only |
| `features/print_schedulers.sh` | Host: print scheduler commands. | prints only; contacts no router |
| `features/pull_router_backups.sh` | Host: pull backups over SFTP/SCP. | `--dry-run` |

## Examples

RouterOS scripts have no preview. Read the source before pasting it, and use
the host tools to inspect.

=== "Report"

    ```bash
    ./mikrotik/features/router_doctor.py --host 192.168.88.1
    ./mikrotik/features/export_config.py --host router.lan --diff
    ```

=== "Preview"

    ```bash
    ./mikrotik/features/print_schedulers.sh
    ./mikrotik/features/print_schedulers.sh --include-notify-boot
    ./mikrotik/features/pull_router_backups.sh --dry-run admin@router.lan ~/Archive/mikrotik-backups
    ```

=== "Apply"

    ```bash
    ./mikrotik/features/pull_router_backups.sh admin@router.lan ~/Archive/mikrotik-backups
    ./mikrotik/features/export_config.py --host router.lan --commit
    ```

    Installing a router script means pasting its `.lua` file into
    `/system script` with the policy above. The file name becomes the script
    name.

## Limitations and caveats

!!! danger "Half the scripts do not run on RouterOS 7.24"
    On 7.24, 14 of the 28 `.lua` scripts do not run: their underscored
    `:global` or `:local` names stop the parser, and nothing is logged.
    Check the per-script compatibility table in the
    [MikroTik README](https://github.com/greenblacked/ops-toolbox/blob/master/mikrotik/README.md#scripts-overview)
    before installing anything. The [roadmap](../roadmap.md) tracks the fix.

!!! danger "Alerts are not enforcement"
    `security_check.lua` only reports. Scripts that block or redirect traffic
    (`mac_allowlist_dhcp.lua`, `rogue_dns_check.lua`, `brute_force_block.lua`,
    `dhcp_lease_watch.lua` with `Enforce=true`) need an enabled firewall rule
    to have any effect.

!!! warning "Never commit secrets"
    Do not combine `export_config.py --show-sensitive` with `--commit`.
    Secrets must not enter git history.

- Choose one of `update_check`, `backup_update_check` or `stay_fresh`. They do
  one job three ways and must not run together.
- `pull_router_backups.sh` needs non-interactive SSH keys and exits 2 when
  `ssh` or `scp` is missing.
- The CHR suite does not verify real Telegram delivery, address-list
  enforcement, or compatibility with your firmware.

## Repository

- [`mikrotik/`](https://github.com/greenblacked/ops-toolbox/tree/master/mikrotik)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/mikrotik/README.md)
- [`mikrotik/core/`](https://github.com/greenblacked/ops-toolbox/tree/master/mikrotik/core)
- [`mikrotik/features/`](https://github.com/greenblacked/ops-toolbox/tree/master/mikrotik/features)

# Scripts overview

Every main script in the repository, grouped by platform. Paths are relative to
the repository root. The Preview column gives the exact flag; "read-only" means
the script only inspects state, and "n/a" means no preview applies. Check
`--help` for the flags that actually apply to your version of a script.

!!! note "Some previews have limits"
    A dry run covers only what that script says it covers. See
    [Philosophy](../getting-started/philosophy.md).

| Script | Platform | Purpose | Preview |
| --- | --- | --- | --- |
| `macos-initial-setup/status.sh` | macOS | One-screen verdict: OS, disk, Homebrew, git identity, agent, FileVault, SIP. | read-only |
| `macos-initial-setup/workstation_doctor.sh` | macOS | Long read-only health report. | read-only |
| `macos-initial-setup/hardening_audit.sh` | macOS | Security audit with the fix for each finding. | read-only |
| `macos-initial-setup/install_apps.sh` | macOS | Install Homebrew casks, CLI formulae and the Google Cloud SDK. | `--dry-run` |
| `macos-initial-setup/install_devtools.sh` | macOS | Install Python, Terraform, Go and Helm toolchains. | `--dry-run` |
| `macos-initial-setup/stay_fresh.sh` | macOS | Recurring housekeeping, upgrades and reports. | `--dry-run` |
| `macos-initial-setup/v1_stay_fresh.sh` | macOS | Deprecated legacy maintenance flow (`--legacy-run`). | none; use `stay_fresh.sh` |
| `macos-initial-setup/brewfile.sh` | macOS | Dump, check, install, diff and clean up the Homebrew state. | `--dry-run` (install only); `cleanup` previews unless `--force` |
| `macos-initial-setup/macos_defaults.sh` | macOS | Report `defaults` values; `--apply` writes, `--revert` restores. | `--dry-run` with `--apply` or `--revert` |
| `macos-initial-setup/launchd/stay_fresh_agent.sh` | macOS | Install and manage a LaunchAgent that runs `stay_fresh.sh`. | `--dry-run` (install, uninstall) |
| `macos-initial-setup/zsh_aliases.zsh` | macOS | Optional zsh aliases; sourced. | n/a (sourced) |
| `linux/status.sh` | Linux | One-screen verdict: distro, disk, packages, reboot, timer, git identity. | read-only |
| `linux/system_doctor.sh` | Linux | Long read-only health report. | read-only |
| `linux/net_doctor.sh` | Linux | Interfaces, routes, DNS, sockets; optional `--probe HOST`. | read-only |
| `linux/hardening_audit.sh` | Linux | Security audit with the fix for each finding. | read-only |
| `linux/ssh_client_doctor.sh` | Linux | `~/.ssh` permissions and `IdentityFile` problems. | read-only |
| `linux/tls_expiry.sh` | Linux | Certificate expiry within `--days`. | read-only |
| `linux/schedule_report.sh` | Linux | Inventory of systemd timers, crontab and `cron.d`. | read-only |
| `linux/sysctl_defaults.sh` | Linux | Report sysctl values; `--apply` writes, `--revert` restores. | `--dry-run` with `--apply` or `--revert` |
| `linux/stay_fresh.sh` | Linux | Package upgrade, journal vacuum, caches, containers. | `--dry-run` |
| `linux/install_devtools.sh` | Linux | Install CLIs, Python, Go, Terraform, Helm. | `--dry-run` |
| `linux/disk_cleanup.sh` | Linux | Free disk space: temp files, caches, opt-in extras. | `--dry-run` |
| `linux/config_backup.sh` | Linux | Dated tar of `/etc` or `--paths`, with rotation. | `--dry-run` |
| `linux/packages.sh` | Linux | List, dump, check, diff, install the package set. | `--dry-run` (install) |
| `linux/install_aliases.sh` | Linux | Add a marked alias block to `~/.bashrc`. | `--dry-run` |
| `linux/bash_aliases.sh` | Linux | Bash aliases; sourced. | n/a (sourced) |
| `linux/systemd/stay_fresh_timer.sh` | Linux | Install and manage a systemd user timer. | `--dry-run` (install); `--print-only` |
| `linux/cloud-init/kali-vm-init.yaml` | Linux | cloud-init user-data for a Kali VM (not a script). | n/a; validate with `cloud-init schema` |
| `windows/setup/status.ps1` | Windows | One-screen verdict: OS, disk, winget, WSL, reboot, git identity. | read-only |
| `windows/setup/workstation_doctor.ps1` | Windows | BitLocker, Defender, reboot flags, disk, WSL, execution policy. | read-only |
| `windows/setup/stay_fresh.ps1` | Windows | winget upgrade, `wsl --update`, reboot and disk report. | `-DryRun` |
| `windows/setup/winget_bootstrap.ps1` | Windows | Export, list, check, import, diff the winget package set. | `-DryRun` (import) |
| `windows/setup/choco_bootstrap.ps1` | Windows | Export, list, check, install, diff Chocolatey packages. | `-DryRun` (install) |
| `windows/setup/winget_configure.ps1` | Windows | Validate, show, test, apply `configuration.winget`. | `-DryRun` (apply) |
| `windows/cleanup/clean_disk_c.ps1` | Windows | Free space on `C:`; deletes only with `-Yes`. | `-DryRun` |
| `windows/wsl/wsl_manage.ps1` | Windows | WSL2 list, backup, restore, prune, compact and more. | `-DryRun` (restore, prune-backups, terminate) |
| `windows/git-bash/install_dotfiles.sh` | Windows | Copy Git Bash dotfiles into `$HOME` with backups. | `--dry-run`; `--status` is read-only |
| `git/git_whoami.sh` | Git | Effective Git name and email. | read-only |
| `git/git_status_summary.sh` | Git | Compact branch and dirty-count summary. | read-only |
| `git/git_repo_root.sh` | Git | Print the worktree root or git dir. | read-only |
| `git/git_diff_branch.sh` | Git | Diff from the merge base to `HEAD`. | read-only |
| `git/git_recent_branches.sh` | Git | List recent branches; `--switch N` checks one out. | none; `--switch` writes `HEAD` |
| `git/git_stale_branches.sh` | Git | Report old branches and their state. | read-only |
| `git/git_size_report.sh` | Git | Repository size and largest blobs. | read-only |
| `git/gacp.sh` | Git | Add all, commit and push. | `--dry-run` |
| `git/set_git_profile.sh` | Git | Set or save Git author identity profiles. | `--dry-run` |
| `git/git_sync_default.sh` | Git | Fetch and fast-forward the default branch. | `--dry-run` |
| `git/git_cleanup_merged.sh` | Git | Delete local branches merged into a base. | `--dry-run` |
| `git/git_prune_gone.sh` | Git | Delete local branches whose upstream is gone. | `--dry-run` |
| `git/git_undo_last_commit.sh` | Git | Move `HEAD` back one commit or revert it. | `--dry-run` |
| `git/git_amend_last.sh` | Git | Amend the last commit. | `--dry-run` |
| `git/git_hooks_install.sh` | Git | Install, check, remove pre-commit guards. | `--dry-run` (install, uninstall) |
| `git/clone-repos.sh` | Git | Clone every URL in a list file. | `--dry-run` |
| `git/git_ssh_doctor.py` | Git | Diagnose git-over-SSH auth. | read-only |
| `git/git_signing_doctor.py` | Git | Diagnose commit-signing failures. | read-only |
| `git/git_remote_doctor.py` | Git | Diagnose remote URLs and credential helpers. | read-only |
| `git/git_ignore_doctor.py` | Git | Explain why a path is or is not ignored. | read-only |
| `git/git_aliases.sh` | Git | Bash aliases for the helpers; sourced. | n/a (sourced) |
| `git/git_aliases.zsh` | Git | zsh aliases for the helpers; sourced. | n/a (sourced) |
| `mikrotik/core/tg_send.lua` | MikroTik | Telegram text helper used by alerting scripts. | n/a (RouterOS script, no flags) |
| `mikrotik/core/detect_internet.lua` | MikroTik | Re-run WAN/LAN auto-detection. | n/a (RouterOS script, no flags) |
| `mikrotik/core/backup_update_check.lua` | MikroTik | Back up, then notify of a newer RouterOS. | n/a (RouterOS script, no flags) |
| `mikrotik/features/backup.lua` | MikroTik | Dated, version-stamped backup and export. | n/a (RouterOS script, no flags) |
| `mikrotik/features/backup_file_cleanup.lua` | MikroTik | Prune old backup and export files. | n/a (RouterOS script, no flags) |
| `mikrotik/features/change_WIFI_pw.lua` | MikroTik | Rotate Wi-Fi PSKs and announce via Telegram. | n/a (RouterOS script, no flags) |
| `mikrotik/features/reboot-and-flush.lua` | MikroTik | Flush DNS and connection tracking, then reboot. | n/a (RouterOS script, no flags) |
| `mikrotik/features/stay_fresh.lua` | MikroTik | Back up, update RouterOS and firmware; reboots. | n/a (RouterOS script, no flags) |
| `mikrotik/features/update_check.lua` | MikroTik | Back up, then notify of an update (retired on 7.24). | n/a (RouterOS script, no flags) |
| `mikrotik/features/health_check.lua` | MikroTik | CPU, RAM, disk, temperature watchdog. | n/a (RouterOS script, no flags) |
| `mikrotik/features/security_check.lua` | MikroTik | Hardening audit; reports findings only. | read-only |
| `mikrotik/features/cert_expiry_watch.lua` | MikroTik | Warn before a certificate expires. | n/a (RouterOS script, no flags) |
| `mikrotik/features/netwatch_notify.lua` | MikroTik | Telegram alerts from netwatch events. | n/a (RouterOS script, no flags) |
| `mikrotik/features/wireguard_watch.lua` | MikroTik | Alert when a WireGuard peer stops handshaking. | n/a (RouterOS script, no flags) |
| `mikrotik/features/wan_failover_notify.lua` | MikroTik | Alert on WAN-detect state changes. | n/a (RouterOS script, no flags) |
| `mikrotik/features/wan_link_flap_notify.lua` | MikroTik | Alert when a WAN link flaps. | n/a (RouterOS script, no flags) |
| `mikrotik/features/ddns_update.lua` | MikroTik | Push the WAN address to Cloudflare DNS. | n/a (RouterOS script, no flags) |
| `mikrotik/features/dhcp_lease_watch.lua` | MikroTik | Alert on new MACs and lease churn; `Enforce=true` can quarantine. | n/a (RouterOS script, no flags) |
| `mikrotik/features/mac_allowlist_dhcp.lua` | MikroTik | Flag, optionally block, non-allowlisted MACs. | n/a (RouterOS script, no flags) |
| `mikrotik/features/firewall_drift.lua` | MikroTik | Diff firewall rules against a baseline. | n/a (RouterOS script, no flags) |
| `mikrotik/features/firewall_drift_baseline.lua` | MikroTik | Re-arm the firewall drift baseline. | n/a (RouterOS script, no flags) |
| `mikrotik/features/rogue_dns_check.lua` | MikroTik | Detect DNS hijack and non-approved resolvers. | n/a (RouterOS script, no flags) |
| `mikrotik/features/latency_monitor.lua` | MikroTik | Alert on sustained RTT degradation. | n/a (RouterOS script, no flags) |
| `mikrotik/features/bandwidth_spike.lua` | MikroTik | Alert on interface throughput spikes. | n/a (RouterOS script, no flags) |
| `mikrotik/features/traffic_quota.lua` | MikroTik | Track monthly volume per interface. | n/a (RouterOS script, no flags) |
| `mikrotik/features/brute_force_block.lua` | MikroTik | Add repeated auth-failure sources to a block list. | n/a (RouterOS script, no flags) |
| `mikrotik/features/vpn_health.lua` | MikroTik | Watch IPsec, OVPN and WireGuard sessions. | n/a (RouterOS script, no flags) |
| `mikrotik/features/wireless_client_watch.lua` | MikroTik | Alert on wireless client changes and poor signal. | n/a (RouterOS script, no flags) |
| `mikrotik/features/export_config.py` | MikroTik | Host: export `/export` over SSH, diff, optional git commit. | `--stdout` or `--diff` |
| `mikrotik/features/router_doctor.py` | MikroTik | Host: audit installed, scheduled and configured scripts. | read-only |
| `mikrotik/features/print_schedulers.sh` | MikroTik | Host: print `/system scheduler` commands. | prints only; `--dry-run` accepted |
| `mikrotik/features/pull_router_backups.sh` | MikroTik | Host: pull backups over SFTP/SCP. | `--dry-run` |
| `k8s-toolbox/kubectl_pod_diag.sh` | Kubernetes | Triage unhealthy pods, events and PVCs. | read-only |
| `k8s-toolbox/gke_cluster_doctor.sh` | Kubernetes | GKE cluster health checks. | read-only |
| `k8s-toolbox/build.sh` | Kubernetes | Build the toolbox image with buildx. | `--dry-run` |
| `k8s-toolbox/run.sh` | Kubernetes | Run the image with `~/.kube` mounted read-only. | `--dry-run` |
| `k8s-toolbox/debug_pod.sh` | Kubernetes | Attach an ephemeral debug container to a pod. | `--dry-run` |
| `dotfiles/install_dotfiles.sh` | Dotfiles | Link or copy tracked configs; report drift. | `--dry-run`; `--list`, `--status` are read-only |

Helper programs under `macos-initial-setup/lib/` are used by `stay_fresh.sh`
and are not run directly. `windows/git-bash/default-git-bash/` is superseded and
not an install path. The Kubernetes manifests in `k8s-toolbox/debug/` and
`k8s-toolbox/examples/` are applied by hand with `kubectl apply`.

See the platform pages for examples and caveats.

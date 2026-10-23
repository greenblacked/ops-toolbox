# Windows

## What it covers

Windows 10/11 with PowerShell 5.1 or 7 for the `.ps1` scripts, and Git Bash for
the dotfiles installer: winget and Chocolatey capture and restore, workstation
status and health, network diagnosis, winget upgrades with WSL update, a `C:`
disk usage report and disk cleanup, WSL2 backup, restore and compaction, and a
Git Bash dotfiles installer with a read-only doctor for the environment around
it. The Git Bash aliases include `ctx`, which prints the Kubernetes, AWS,
gcloud, Terraform, Docker and Git targets the next command will hit and marks
anything that looks like production.

## Requirements

- Windows 10 or 11; PowerShell 5.1 or 7.
- winget (WinGet 1.6+ for `winget_configure.ps1` `apply` and `test`).
- Chocolatey is optional and is not installed by these scripts.
- WSL2 for `wsl_manage.ps1`, except `verify-backup`, `backups` and
  `wslconfig`, which only read files.
- Elevation for `compact` and some cleanup targets.
- Git Bash for `install_dotfiles.sh` and `gitbash_doctor.sh`.

## Main scripts

<!-- markdownlint-disable MD033 -->

| Script | Purpose | Preview |
| --- | --- | --- |
| `setup/status.ps1` | One-screen verdict; `-Only` selects sections, `-ListSections` lists them. | <span class="stage stage-report">read-only</span> |
| `setup/workstation_doctor.ps1` | BitLocker, Defender, reboot flags, `C:` disk, WSL, execution policy, disk health, uptime, patch age, memory; `-Only` selects sections. | <span class="stage stage-report">read-only</span> |
| `setup/net_doctor.ps1` | Adapters, default routes, DNS, proxy (WinINET against `HTTP_PROXY`), hosts file, listening ports; opt-in `-Probe HOST`. | <span class="stage stage-report">read-only</span> |
| `setup/tls_expiry.ps1` | Certificate expiry for PEM/CER files, TLS endpoints and the personal stores; exit-coded for a scheduled task. | <span class="stage stage-report">read-only</span> |
| `setup/hardening_audit.ps1` | Security audit with the fix for each finding: firewall, SMBv1, RDP/NLA, UAC, autologon, Secure Boot, TPM, LSA, Defender, logging, patch age. | <span class="stage stage-report">read-only</span> |
| `setup/dev_env_doctor.ps1` | Long paths, git line endings and symlinks, virtualization, clock skew (`-CheckTime`), `HOME` against `USERPROFILE`, docker context. | <span class="stage stage-report">read-only</span> |
| `setup/ssh_client_doctor.ps1` | Private-key access lists, the `ssh-agent` service, Git's bundled ssh against the Windows one, `IdentityFile` paths; prints each fix. | <span class="stage stage-report">read-only</span> |
| `setup/path_doctor.ps1` | PATH report: duplicates, dead and relative entries, `REG_SZ` values that never expand, length limits, shadowed commands; `clean` tidies the user PATH with a backup. | `-DryRun` on `clean`; `-Yes` to write |
| `setup/stay_fresh.ps1` | winget upgrade, `wsl --update`, reboot and disk report. | `-DryRun` |
| `setup/winget_bootstrap.ps1` | `export`, `list`, `check`, `import`, `diff` of the winget package set. | `-DryRun` on `import` |
| `setup/choco_bootstrap.ps1` | `export`, `list`, `check`, `install`, `diff` of Chocolatey packages. | `-DryRun` on `install` |
| `setup/winget_configure.ps1` | `validate`, `show`, `test`, `apply` of `configuration.winget`. | `-DryRun` on `apply` |
| `cleanup/disk_usage.ps1` | What fills `C:` (hibernation and page files, `Windows.old`, `WinSxS`, Docker, WSL disks, dev caches) and the tool that gives each back; `tree` for one folder. | <span class="stage stage-report">read-only</span> |
| `cleanup/clean_disk_c.ps1` | Free space on `C:`; opt-in Recycle Bin, Update cache, dev caches, docker, crash dumps, servicing logs, component store. | `-DryRun`; `-Yes` to delete |
| `wsl/wsl_manage.ps1` | `list`, `df`, `backup`, `verify-backup`, `backups` (inventory, `-Verify`, `-MaxAgeDays`), `restore`, `prune-backups`, `clone`, `compact`, `sparse`, `terminate`, `shutdown`, `doctor` (per-distro health), `wslconfig` (audit `.wslconfig`). | `-DryRun` on `backup` (`-All` for every distro), `restore`, `clone`, `prune-backups`, `compact`, `sparse`, `terminate`, `shutdown`; `backups`, `doctor` and `wslconfig` are read-only |
| `git-bash/install_dotfiles.sh` | Copy `.bashrc`, `.bash_profile`, `.aliases` into `$HOME` with backups; `--restore` and `--prune-backups` roll back and clean up. | `--dry-run` (install, `--restore`, `--prune-backups`); `--status`, `--diff` and `--list-backups` are read-only |
| `git-bash/gitbash_doctor.sh` | Git Bash health: CRLF or broken dotfiles, stale `ssh-agent`, Windows OpenSSH on `PATH`, OneDrive `HOME`, long paths, Git settings, Store `python` stub. | <span class="stage stage-report">read-only</span> |

<!-- markdownlint-enable MD033 -->

All paths are under `windows/`.

## Examples

=== "Report"

    ```powershell
    .\windows\setup\status.ps1
    .\windows\setup\status.ps1 -Only disk,git
    .\windows\setup\workstation_doctor.ps1 -MinFreePercent 20
    .\windows\setup\workstation_doctor.ps1 -Only hardware,uptime
    .\windows\setup\net_doctor.ps1 -Probe github.com
    .\windows\setup\ssh_client_doctor.ps1 -FailOn warn
    .\windows\setup\dev_env_doctor.ps1 -CheckTime
    .\windows\setup\hardening_audit.ps1 -FailOn warn
    .\windows\setup\tls_expiry.ps1 -HostName example.com -Store -Days 14
    .\windows\setup\winget_bootstrap.ps1 diff
    .\windows\cleanup\disk_usage.ps1
    .\windows\cleanup\disk_usage.ps1 tree -Path $env:USERPROFILE -Depth 2
    .\windows\wsl\wsl_manage.ps1 doctor
    .\windows\wsl\wsl_manage.ps1 wslconfig
    .\windows\wsl\wsl_manage.ps1 backups -DestDir D:\Backups -Verify -MaxAgeDays 7
    ```

    ```bash
    ./windows/git-bash/gitbash_doctor.sh
    ```

=== "Preview"

    ```powershell
    .\windows\setup\stay_fresh.ps1 -DryRun
    .\windows\setup\path_doctor.ps1 clean -DryRun
    .\windows\cleanup\clean_disk_c.ps1 -DryRun -Scope User
    .\windows\cleanup\clean_disk_c.ps1 -DryRun -IncludeCrashDumps -IncludeLogs -IncludeComponentStore
    .\windows\setup\winget_configure.ps1 apply -DryRun
    .\windows\wsl\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
    .\windows\wsl\wsl_manage.ps1 backup -All -DestDir D:\Backups -DryRun
    .\windows\wsl\wsl_manage.ps1 compact -Distro Ubuntu -DryRun
    ```

=== "Apply"

    ```powershell
    .\windows\setup\stay_fresh.ps1 -Yes
    .\windows\cleanup\clean_disk_c.ps1 -Yes
    .\windows\setup\path_doctor.ps1 clean -Yes
    ```

    ```bash
    ./windows/git-bash/install_dotfiles.sh
    ```

## Limitations and caveats

!!! warning "Consent gates"
    `clean_disk_c.ps1` deletes only with `-Yes` and refuses to run without
    `-DryRun` or `-Yes` (exit 3). `stay_fresh.ps1` skips winget upgrades
    without `-Yes`. It does not reboot and does not free disk space; that is
    `clean_disk_c.ps1`. `path_doctor.ps1 clean` refuses without `-DryRun` or
    `-Yes` (exit 3), changes only the user PATH, and writes a backup first.

!!! warning "PowerShell 5.1 is not tested in CI"
    CI runs `pwsh` (PowerShell 7) on `windows-2025`. Verify the scripts under
    Windows PowerShell 5.1 yourself if you use it.

!!! note "Execution policy"
    Windows may block `.ps1` files. See
    [Installation and usage](../getting-started/usage.md#powershell-execution-policy).
    Changing the policy is your decision, not the scripts'.

- `wsl_manage.ps1 restore` imports a new distro and never overwrites an
  existing one; `-DefaultUser` sets the user it boots as, which `--import`
  does not carry over. `clone` copies a distro under a new name the same way
  and never touches the source. `compact` needs elevation and shuts WSL down
  first.
- Several probes are best-effort: `Get-BitLockerVolume` is missing on Home
  editions, and `Get-MpComputerStatus` is absent where another antivirus
  product replaced Defender.
- `winget_configure.ps1` exits 2 before calling winget when WinGet is older
  than 1.6.
- `windows/git-bash/default-git-bash/` is an earlier draft superseded by
  `windows/git-bash/`. Do not install it.
- Contract tests run without Windows for some scripts only; real winget,
  Chocolatey, WSL, BitLocker and Defender behavior is not covered by CI.

## Repository

- [`windows/`](https://github.com/greenblacked/ops-toolbox/tree/master/windows)
- [Folder README](https://github.com/greenblacked/ops-toolbox/blob/master/windows/README.md)
- [`windows/setup/`](https://github.com/greenblacked/ops-toolbox/tree/master/windows/setup)
- [`windows/cleanup/`](https://github.com/greenblacked/ops-toolbox/tree/master/windows/cleanup)
- [`windows/wsl/`](https://github.com/greenblacked/ops-toolbox/tree/master/windows/wsl)
- [`windows/git-bash/`](https://github.com/greenblacked/ops-toolbox/tree/master/windows/git-bash)

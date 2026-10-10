# Windows

## What it covers

Windows 10/11 with PowerShell 5.1 or 7 for the `.ps1` scripts, and Git Bash for
the dotfiles installer: winget and Chocolatey capture and restore, workstation
status and health, winget upgrades with WSL update, `C:` disk cleanup, WSL2
backup, restore and compaction, and a Git Bash dotfiles installer.

## Requirements

- Windows 10 or 11; PowerShell 5.1 or 7.
- winget (WinGet 1.6+ for `winget_configure.ps1` `apply` and `test`).
- Chocolatey is optional and is not installed by these scripts.
- WSL2 for `wsl_manage.ps1`.
- Elevation for `compact` and some cleanup targets.
- Git Bash for `install_dotfiles.sh`.

## Main scripts

| Script | Purpose | Preview |
| --- | --- | --- |
| `setup/status.ps1` | One-screen verdict; `-Only` selects sections, `-ListSections` lists them. | read-only |
| `setup/workstation_doctor.ps1` | BitLocker, Defender, reboot flags, `C:` disk, WSL, execution policy. | read-only |
| `setup/stay_fresh.ps1` | winget upgrade, `wsl --update`, reboot and disk report. | `-DryRun` |
| `setup/winget_bootstrap.ps1` | `export`, `list`, `check`, `import`, `diff` of the winget package set. | `-DryRun` on `import` |
| `setup/choco_bootstrap.ps1` | `export`, `list`, `check`, `install`, `diff` of Chocolatey packages. | `-DryRun` on `install` |
| `setup/winget_configure.ps1` | `validate`, `show`, `test`, `apply` of `configuration.winget`. | `-DryRun` on `apply` |
| `cleanup/clean_disk_c.ps1` | Free space on `C:`; opt-in Recycle Bin, Update cache, dev caches, docker. | `-DryRun`; `-Yes` to delete |
| `wsl/wsl_manage.ps1` | `list`, `df`, `backup`, `verify-backup`, `restore`, `prune-backups`, `compact`, `sparse`, `terminate`, `shutdown`. | `-DryRun` on `restore`, `prune-backups`, `terminate` |
| `git-bash/install_dotfiles.sh` | Copy `.bashrc`, `.bash_profile`, `.aliases` into `$HOME` with backups. | `--dry-run`; `--status` is read-only |

All paths are under `windows/`.

## Examples

=== "Report"

    ```powershell
    .\windows\setup\status.ps1
    .\windows\setup\status.ps1 -Only disk,git
    .\windows\setup\workstation_doctor.ps1 -MinFreePercent 20
    .\windows\setup\winget_bootstrap.ps1 diff
    ```

=== "Preview"

    ```powershell
    .\windows\setup\stay_fresh.ps1 -DryRun
    .\windows\cleanup\clean_disk_c.ps1 -DryRun -Scope User
    .\windows\setup\winget_configure.ps1 apply -DryRun
    .\windows\wsl\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
    ```

=== "Apply"

    ```powershell
    .\windows\setup\stay_fresh.ps1 -Yes
    .\windows\cleanup\clean_disk_c.ps1 -Yes
    ```

    ```bash
    ./windows/git-bash/install_dotfiles.sh
    ```

## Limitations and caveats

!!! warning "Consent gates"
    `clean_disk_c.ps1` deletes only with `-Yes` and refuses to run without
    `-DryRun` or `-Yes` (exit 3). `stay_fresh.ps1` skips winget upgrades
    without `-Yes`. It does not reboot and does not free disk space; that is
    `clean_disk_c.ps1`.

!!! warning "PowerShell 5.1 is not tested in CI"
    CI runs `pwsh` (PowerShell 7) on `windows-2025`. Verify the scripts under
    Windows PowerShell 5.1 yourself if you use it.

!!! note "Execution policy"
    Windows may block `.ps1` files. See
    [Installation and usage](../getting-started/usage.md#powershell-execution-policy).
    Changing the policy is your decision, not the scripts'.

- `wsl_manage.ps1 restore` imports a new distro and never overwrites an
  existing one. `compact` needs elevation and shuts WSL down first.
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

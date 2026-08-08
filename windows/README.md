# Windows Scripts

Everything for keeping a Windows dev machine pleasant: Git Bash dotfiles,
WSL maintenance, and disk cleanup. Each subfolder has its own README with
full details.

| Folder | Purpose |
| --- | --- |
| [`git-bash/`](git-bash/) | `.bashrc` / `.bash_profile` / `.aliases` for Git Bash (MSYS2) — persistent shared `ssh-agent`, Git-aware prompt, PATH hygiene, and ~190 aliases (Git, GitLab CLI, Docker, Kubernetes, Terraform, WSL, Windows commands). `install_dotfiles.sh` copies them into `$HOME` with a backup, and refuses anything carrying CRLF line endings. |
| [`wsl/`](wsl/) | `wsl_manage.ps1` — list distros with real disk usage, dated `.tar` backups, shrink ballooned VHDX disks (compact/sparse), shutdown. |
| [`cleanup/`](cleanup/) | `clean_disk_c.ps1` — free space on C: safely (temp files, caches, WER, thumbnails), with opt-in flags for Recycle Bin, Windows Update cache, dev caches, and Docker. `-DryRun` first. |
| [`setup/`](setup/) | `winget_bootstrap.ps1` — capture the installed package list to a versioned JSON file and restore it on another machine (`export` / `check` / `import` / `diff`, mirroring `brewfile.sh`), with `winget-packages.example.json` showing the format. `stay_fresh.ps1` — recurring maintenance: winget upgrades, `wsl --update`, pending-reboot report. `workstation_doctor.ps1` — read-only health report: BitLocker, Defender, pending reboot, disk, WSL, execution policy. |
| [`tests/`](tests/) | Contract checks over every script here: parse, comment-based help, preview-before-changing, and that documented flags exist. |

## Quick start

```powershell
# Is this machine healthy? Read-only, changes nothing:
.\setup\workstation_doctor.ps1

# See what cleanup would delete, without deleting anything:
.\cleanup\clean_disk_c.ps1 -DryRun

# WSL disk usage overview:
.\wsl\wsl_manage.ps1 list

# What has changed in the installed package list since it was captured?
.\setup\winget_bootstrap.ps1 diff

# The recurring maintenance run, previewed then performed:
.\setup\stay_fresh.ps1 -DryRun
.\setup\stay_fresh.ps1
```

```bash
# Git Bash dotfiles (from the repo root, inside Git Bash):
./windows/git-bash/install_dotfiles.sh --dry-run
./windows/git-bash/install_dotfiles.sh
```

PowerShell scripts follow the same rules as the rest of the repo: idempotent,
dry-run (or read-only default action) first, destructive things behind
explicit opt-in flags.

## Execution policy note

If PowerShell refuses to run the scripts (`...cannot be loaded because
running scripts is disabled...`), allow locally-created scripts for your
user once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Or run a single script without changing policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup\clean_disk_c.ps1 -DryRun
```

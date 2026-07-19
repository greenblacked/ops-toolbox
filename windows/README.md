# Windows Scripts

Everything for keeping a Windows dev machine pleasant: Git Bash dotfiles,
WSL maintenance, and disk cleanup. Each subfolder has its own README with
full details.

| Folder | Purpose |
| --- | --- |
| [`git-bash/`](git-bash/) | `.bashrc` / `.bash_profile` / `.aliases` for Git Bash (MSYS2) — persistent shared `ssh-agent`, Git-aware prompt, PATH hygiene, and ~190 aliases (Git, GitLab CLI, Docker, Kubernetes, Terraform, WSL, Windows commands). |
| [`wsl/`](wsl/) | `wsl_manage.ps1` — list distros with real disk usage, dated `.tar` backups, shrink ballooned VHDX disks (compact/sparse), shutdown. |
| [`cleanup/`](cleanup/) | `clean_disk_c.ps1` — free space on C: safely (temp files, caches, WER, thumbnails), with opt-in flags for Recycle Bin, Windows Update cache, dev caches, and Docker. `-DryRun` first. |

## Quick start

```powershell
# See what cleanup would delete, without deleting anything:
.\cleanup\clean_disk_c.ps1 -DryRun

# WSL disk usage overview:
.\wsl\wsl_manage.ps1 list
```

```bash
# Git Bash dotfiles (from the repo root, inside Git Bash):
cp windows/git-bash/.bashrc windows/git-bash/.bash_profile windows/git-bash/.aliases "$HOME/"
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

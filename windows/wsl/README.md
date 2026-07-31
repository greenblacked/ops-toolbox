# WSL Maintenance

`wsl_manage.ps1` covers the WSL2 chores that are annoying to remember:
finding where the virtual disks actually live, backing distros up, and
reclaiming the disk space WSL2 never gives back on its own.

## Why "compact" exists

WSL2 stores each distro in a VHDX virtual disk that **grows automatically
but never shrinks**. Delete 20 GB inside Ubuntu and `C:` stays exactly as
full as before — the space is only reclaimable by compacting the VHDX from
the Windows side. This is the single biggest source of "where did my C:
space go?" on WSL machines (the disks commonly balloon to tens of GB), and
regular disk cleaners can't touch it.

## Usage

```powershell
# State, WSL version, VHDX path and real size per distro:
.\wsl_manage.ps1 list

# Dated .tar export (works while the distro is running):
.\wsl_manage.ps1 backup -Distro Ubuntu -DestDir D:\Backups

# Shrink after deleting files inside the distro (elevated PowerShell):
.\wsl_manage.ps1 compact -Distro Ubuntu

# Never think about it again (recent WSL): auto-return space from now on
.\wsl_manage.ps1 sparse -Distro Ubuntu
.\wsl_manage.ps1 sparse -Distro Ubuntu -Off   # revert

# Stop all distros + the utility VM (frees the RAM WSL is holding):
.\wsl_manage.ps1 shutdown
```

## Actions

| Action | Needs admin | Stops WSL | Notes |
| --- | --- | --- | --- |
| `list` | no | no | Joins `wsl -l -v` state with VHDX paths/sizes from the registry. |
| `backup` | no | no | `wsl --export` to `<DestDir>\<distro>_<date>.tar`; prints the matching `--import` restore command. Default `DestDir`: `%USERPROFILE%\wsl-backups`. |
| `compact` | **yes** | **yes** (all distros) | `wsl --shutdown`, then diskpart `compact vdisk`. Prints before/after/reclaimed. |
| `sparse` | no | no | `wsl --manage <distro> --set-sparse true` — needs a recent WSL (`wsl --update` if it fails). |
| `shutdown` | no | yes | Plain `wsl --shutdown`. |

Take a `backup` before your first `compact` on a distro you care about —
compacting is safe and routine, but it is still a disk-level operation on
the only copy of that filesystem.

## Git Bash shortcuts

[`../git-bash/.aliases`](../git-bash/.aliases) defines (only when `wsl.exe`
exists): `wsls` (list -v), `wslsh` (shutdown), `wslup` (update),
`wslstatus`, and `wslr <cmd>` to run a single command in the default distro.

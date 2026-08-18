# WSL Maintenance

`wsl_manage.ps1` covers the WSL2 chores that are annoying to remember:
finding where the virtual disks actually live, backing distros up and getting
them back, reclaiming the disk space WSL2 never gives back on its own, and
throwing away the giant `.tar` exports once they have aged out.

## Why "compact" exists

WSL2 stores each distro in a VHDX virtual disk that **grows automatically
but never shrinks**. Delete 20 GB inside Ubuntu and `C:` stays exactly as
full as before — the space is only reclaimable by compacting the VHDX from
the Windows side. This is the single biggest source of "where did my C:
space go?" on WSL machines (the disks commonly balloon to tens of GB), and
regular disk cleaners can't touch it.

`.\wsl_manage.ps1 df` puts a number on it: the allocated column is the VHDX
file, the used column is `df` inside the distro, and the difference is what a
compact would give back.

## Usage

```powershell
# State, WSL version, VHDX path and real size per distro:
.\wsl_manage.ps1 list

# Allocated vs actually used, per distro (read-only):
.\wsl_manage.ps1 df
.\wsl_manage.ps1 df -Force          # also start stopped distros to measure them

# Dated .tar export (works while the distro is running):
.\wsl_manage.ps1 backup -Distro Ubuntu -DestDir D:\Backups
.\wsl_manage.ps1 verify-backup -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar

# Bring one back as a new distro (see "Restoring" below - read it first):
.\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar -DryRun
.\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar

# Throw away exports that have aged out (preview, then do it):
.\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
.\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2

# Shrink after deleting files inside the distro (elevated PowerShell):
.\wsl_manage.ps1 compact -Distro Ubuntu

# Never think about it again (recent WSL): auto-return space from now on
.\wsl_manage.ps1 sparse -Distro Ubuntu
.\wsl_manage.ps1 sparse -Distro Ubuntu -Off   # revert

# Stop one distro, leaving the others and the utility VM alone:
.\wsl_manage.ps1 terminate -Distro Ubuntu

# Stop all distros + the utility VM (frees the RAM WSL is holding):
.\wsl_manage.ps1 shutdown
```

## Actions

| Action | Needs admin | Stops WSL | Notes |
| --- | --- | --- | --- |
| `list` | no | no | Joins `wsl -l -v` state with VHDX paths/sizes from the registry. |
| `df` | no | no | Allocated (VHDX file) against used (`df -Pk /` inside the distro), plus the reclaimable difference. Stopped distros show `-` unless `-Force` is passed, because measuring one starts it. |
| `backup` | no | no | `wsl --export` to `<DestDir>\<distro>_<date>.tar`; prints the matching `restore` command. Default `DestDir`: `%USERPROFILE%\wsl-backups`. |
| `verify-backup` | no | no | Recomputes SHA-256 for `-Tar` and compares it with the `.sha256` sidecar written by `backup`. Does not require WSL to be running. |
| `restore` | no | no | `wsl --import` of a `.tar` as a **new** distro. Needs `-Distro` (the new name) and `-Tar` (the file). `-DryRun` prints what it would register. |
| `prune-backups` | no | no | Deletes aged-out `.tar` exports under `-DestDir`. `-DryRun` previews; a real run asks before deleting unless `-Force`. |
| `compact` | **yes** | **yes** (all distros) | `wsl --shutdown`, then diskpart `compact vdisk`. Prints before/after/reclaimed. |
| `sparse` | no | no | `wsl --manage <distro> --set-sparse true` — needs a recent WSL (`wsl --update` if it fails). |
| `terminate` | no | one distro | `wsl --terminate <distro>`. Kills that distro's processes; other distros and the utility VM keep running. |
| `shutdown` | no | yes | Plain `wsl --shutdown`. |

Exit codes: `0` success, `1` the underlying `wsl`/`diskpart` command failed,
`2` WSL is not installed or not operational, `3` bad arguments, `4` needs an
elevated shell (`compact`).

Take a `backup` before your first `compact` on a distro you care about —
compacting is safe and routine, but it is still a disk-level operation on
the only copy of that filesystem.

Every new backup has a neighboring `<name>.tar.sha256` file. `restore` verifies
it automatically when present and refuses a mismatch; older exports without a
sidecar remain restorable with a visible warning. Keep the tar and sidecar
together when copying them. `prune-backups` removes a pruned tar's sidecar too,
so retention does not leave checksum files behind.

## Restoring

`backup` writes a `.sha256` sidecar next to each export, and `restore` verifies
the tar against it before importing anything. A backup made before sidecars
existed — or one whose sidecar has been lost — needs `-AllowUnverified`, which
states plainly that nothing was checked. A missing sidecar used to be treated
as a pass, so an unverified import looked exactly like a verified one.

`wsl --import` creates a **new** registration from a tar. It cannot replace a
distro in place, and there are two surprises worth knowing before you need it
at 2am rather than after:

1. **The name must be free.** `-Distro` is the name the restored copy is
   registered under. If it is already taken the import fails; the script
   checks first and says so. To reuse the original name, remove the existing
   distro with `wsl --unregister <name>` — which deletes that distro's disk,
   so take a `backup` of it first.
2. **It boots as root.** The default user is recorded inside the distro and
   `--import` does not carry it over. After a restore, add

   ```text
   [user]
   default=YOURNAME
   ```

   to `/etc/wsl.conf` (`wsl -d <name> -u root`), then
   `.\wsl_manage.ps1 terminate -Distro <name>` so the file is read at the next
   start.

`-InstallDir` is where the new `ext4.vhdx` is written; it defaults to
`%LOCALAPPDATA%\WSL\<Distro>` and must be empty or absent. The tar is read,
not consumed, so plan for the disk holding both it and the imported disk at
once. Run it with `-DryRun` first: that prints the directory it would create
and the size it would import, and registers nothing.

## Pruning backups

Each export is a full copy of the distro's filesystem, so a monthly backup
habit quietly fills a disk. `prune-backups` applies two retention rules to
`-DestDir` and deletes only what **both** agree can go:

- `-KeepLast` (default `2`) — the newest N exports of each distro always stay.
- `-KeepDays` (default `30`) — anything younger than N days always stays.

Only files named the way `backup` writes them —
`<distro>_<yyyy-MM-dd>_<HHmm>.tar` — are candidates. Anything else in the
folder is somebody else's file and is left alone. Pass `-Distro` to prune one
distro's exports rather than all of them.

A real run prints the `KEEP`/`PRUNE` list and then asks for confirmation;
`-Force` skips the prompt for a scheduled task, and `-DryRun` prints the same
list with `WOULD` and deletes nothing.

## Git Bash shortcuts

[`../git-bash/.aliases`](../git-bash/.aliases) defines (only when `wsl.exe`
exists): `wsls` (list -v), `wslsh` (shutdown), `wslup` (update),
`wslstatus`, and `wslr <cmd>` to run a single command in the default distro.

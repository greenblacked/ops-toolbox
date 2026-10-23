# Disk C: cleanup

[Ops Toolbox](../../README.md) / **Disk C: cleanup**

`clean_disk_c.ps1` frees space on `C:` by deleting data that is genuinely
safe to lose. It never touches documents, downloads, application settings, or
anything under your user profile except designated cache/temp locations.

[`disk_usage.ps1`](disk_usage.ps1) is the step before it: a read-only report
of what is actually filling `C:` - including the things `clean_disk_c.ps1`
deliberately leaves alone - with the tool that gives each one back. See
[disk_usage.ps1](#disk_usageps1) below.

## Requirements

| Requirement | Notes |
| --- | --- |
| **Windows 10 or 11** | The script reads `C:` and the current Windows identity at script scope, so it is a Windows-only file in a way the other scripts here are not. |
| **Windows PowerShell 5.1 or PowerShell 7** | Either edition. See the repository's [execution policy note](../README.md#execution-policy-note) if PowerShell refuses to run it at all. |
| **An elevated shell** | Optional. Without it the machine-wide targets (Windows temp, WER, Delivery Optimization, Windows Update cache, system crash dumps, servicing logs, the component store) are skipped with a warning and the profile-owned ones still run. |
| **Docker** | Optional, and only for the opt-in Docker target. When `docker` is not on `PATH` that target prints a `SKIP` line instead of failing the run. |

## Usage

```powershell
# Always start here - reports sizes per target, deletes nothing:
.\clean_disk_c.ps1 -DryRun

# Only profile-owned default targets (no elevation warnings):
.\clean_disk_c.ps1 -DryRun -Scope User

# Default clean (temp files older than 7 days + system caches):
.\clean_disk_c.ps1 -Yes

# More aggressive:
.\clean_disk_c.ps1 -Yes -Days 3 -IncludeRecycleBin -IncludeWindowsUpdate -IncludeDevCaches

# Crash dumps, old servicing logs and superseded update payloads (elevated):
.\clean_disk_c.ps1 -DryRun -IncludeCrashDumps -IncludeLogs -IncludeComponentStore
.\clean_disk_c.ps1 -Yes -IncludeCrashDumps -IncludeLogs -IncludeComponentStore
```

## Deleting needs -Yes

A run with neither `-DryRun` nor `-Yes` deletes nothing: it prints
`refusing to delete without -Yes; preview with -DryRun` and exits `3`. This
used to be the one thing it did not do — a bare `.\clean_disk_c.ps1` emptied
`%TEMP%`, the WER queue and the thumbnail cache on the spot.

That was a difference from
[`../../linux/disk_cleanup.sh`](../../linux/disk_cleanup.sh), which has refused
without `--yes` since it was written, and the two are presented as
counterparts throughout this repository. Anyone carrying the habit across
("just run it, it will tell me what it wants") got a deletion where they
expected to be told what was missing. `-Yes` is that gate, spelled the way the
Bash sibling spells it, and it is checked first — before elevation is probed
and before any target is read.

Exit codes: `0` success, `1` `-IncludeComponentStore` ran and `Dism.exe`
exited non-zero, `3` refused because neither `-DryRun` nor `-Yes` was given.

Run from an **elevated** PowerShell to also clean the system-wide targets
(Windows temp, WER reports, Delivery Optimization, Windows Update cache);
without elevation those are skipped with a warning and the user-level targets
still run.

## What it cleans

**Always (no flags needed, no data loss):**

| Target | Notes |
| --- | --- |
| `%TEMP%` | Only files older than `-Days` (default 7) — recent temp files may belong to running apps. |
| `C:\Windows\Temp` | Same age filter. Admin only. |
| Windows Error Reporting queue | Crash dumps pending upload. Admin only. |
| Delivery Optimization cache | Peer-to-peer Windows Update cache. Admin only. |
| Explorer thumbnail cache | Regenerates automatically as folders are viewed. |

`-Scope User` limits the default targets to user temp and thumbnails;
`-Scope System` limits them to Windows temp, WER, and Delivery Optimization.
`All` remains the default. Explicit `-Include*` flags are independent of this
scope: an opt-in target still runs because it was named explicitly.

**Opt-in flags (safe, but with side effects you should choose knowingly):**

| Flag | Effect | Side effect |
| --- | --- | --- |
| `-IncludeRecycleBin` | Empties Recycle Bin on C: | Deleted files become unrecoverable. |
| `-IncludeWindowsUpdate` | Clears `SoftwareDistribution\Download` (stops/starts the update service around it) | Pending updates re-download. |
| `-IncludeDevCaches` | pip, NuGet, npm caches | Next builds re-download packages. |
| `-IncludeDocker` | `docker system prune -f` | Removes dangling images, stopped containers, unused networks. **Volumes are never touched.** |
| `-IncludeCrashDumps` | `C:\Windows\MEMORY.DMP`, `C:\Windows\Minidump`, `C:\Windows\LiveKernelReports`, the WER report archive (admin), and `%LOCALAPPDATA%\CrashDumps` | **You lose the ability to analyse past crashes.** There is no age filter - copy a dump away first if a crash still needs looking at. Windows recreates the `LiveKernelReports` subfolders when it needs them. |
| `-IncludeLogs` | CBS, DISM and setup (`Panther`) logs under `C:\Windows` older than `-Days` (admin) | Old servicing history is gone; recent logs stay. The event logs are never touched. |
| `-IncludeComponentStore` | `Dism.exe /Online /Cleanup-Image /StartComponentCleanup`, Windows' own supported cleanup (admin) | Superseded update payloads are removed; installed updates can still be uninstalled. It can take a while. `-DryRun` prints the command and does not run DISM at all, not even its analysis, which writes logs of its own. |

## What it deliberately does not touch

- Browser caches/profiles — too easy to nuke sessions and offline data.
- `C:\Windows\Installer` — breaks uninstall/repair of installed software.
- Hibernation file / pagefile — system-managed; disable via `powercfg` if
  you know you want that.
- WSL virtual disks — those shrink via
  [`../wsl/wsl_manage.ps1`](../wsl/wsl_manage.ps1) `compact` instead.
- `Windows.old` and `$WINDOWS.~BT` — Windows' own Storage settings are the
  supported way to remove them.
- `/ResetBase` — `-IncludeComponentStore` never passes it. It makes every
  installed update permanent, so none can be uninstalled afterwards; that is
  a decision to make by hand, not a side effect of freeing space.
- Event logs and `Package Cache` — the first is not a file to delete, the
  second is needed to repair and uninstall software.

The large ones are not invisible, though: [`disk_usage.ps1`](#disk_usageps1)
measures them and names the tool that does give the space back.

## Notes

- Locked/in-use files are skipped silently — normal for temp folders.
- The dry-run total is a lower bound: Recycle Bin, Delivery Optimization,
  npm, Docker and component store sizes are not included in the estimate
  (their tooling doesn't expose sizes cheaply); the real clean prints
  before/after free space, which captures everything. The component store
  runs last for that reason.
- A `FAIL` line for the component store - `Dism.exe` exiting non-zero - is
  reported and the run carries on, then the script exits `1` after the
  summary. Without `-IncludeComponentStore` the exit code stays `0` or `3`
  as documented above.

## disk_usage.ps1

A read-only report of what is filling `C:`, and the report step that comes
before the cleanup step. It deletes nothing - the file contains no deleting
command at all, and the contract tests check that - never follows a junction
or symbolic link, never reads a file's contents and never contacts the
network.

```powershell
.\disk_usage.ps1
.\disk_usage.ps1 hotspots -MinSizeMB 500 -IncludeDocker
.\disk_usage.ps1 tree
.\disk_usage.ps1 tree -Path $env:USERPROFILE -Depth 2 -Top 10
```

| Action | What it shows |
| --- | --- |
| `hotspots` | The default. A fixed list of known space users, each measured and printed as a `FOUND` row with a pointer to what gives it back, largest first; a `SKIP` row for each one that is not there. |
| `tree` | The largest children of a folder (the system drive by default), to a chosen depth, two spaces of indent per level. |

The hot spots, and where each one points:

| Location | Pointer |
| --- | --- |
| `hiberfil.sys`, `pagefile.sys`, `swapfile.sys` | System managed: `powercfg /h /type reduced` or `/h off` for the first, the Virtual memory dialog for the second. |
| `Windows.old`, `$WINDOWS.~BT`, `$WinREAgent` | Settings > System > Storage > Temporary files. Not something this folder deletes. |
| `$Recycle.Bin`, Windows Update downloads, Windows and user temp | This folder's cleanup script, with the flag that reaches each one. |
| `MEMORY.DMP`, minidumps, live kernel reports, user crash dumps; CBS and DISM logs | The cleanup script's crash-dump and log flags. |
| `Windows\Installer`, `Package Cache` | Never delete: uninstall and repair need them. |
| `WinSxS` | `Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore` first; the cleanup itself is the cleanup script's component-store flag. The folder size over-counts, because most of it is hard links, so it is left out of the reachable total. |
| Docker data | `docker system prune` (the cleanup script's Docker flag), or Docker Desktop's Troubleshoot > Clean / Purge data. |
| NuGet, pip and npm caches | The cleanup script's dev-caches flag. |
| Gradle, Maven, Cargo, rustup, Go modules, minikube, kubectl cache, Vagrant, conda, Android SDK and emulators, VirtualBox VMs, Downloads | The owning tool's own clean command, or by hand. |
| Each WSL distro's `ext4.vhdx` | [`../wsl/wsl_manage.ps1`](../wsl/wsl_manage.ps1) `df`, then `compact`. |

The WSL disks are found from the registry (`HKCU\...\Lxss`), not from
`wsl --list`, so a distro imported to another folder is found too and WSL is
not started to answer.

| Option | Meaning |
| --- | --- |
| `-Path DIR` | The folder `tree` measures. Default: the system drive. Must be a folder, or the script exits `3`. |
| `-Depth N` | Levels `tree` shows, `1`-`4`. Default `1`. |
| `-Top N` | Rows per list, `1`-`100`. Default `15`. |
| `-MinSizeMB N` | Hide rows smaller than this. Default `100`; `0` shows everything. |
| `-IncludeDocker` | Also print `docker system df` from the local daemon. A `SKIP` line when `docker` is not on `PATH`. |
| `-Quiet` | Leave out the `SKIP` rows and the `[info]` lines. |

Exit codes: `0` the report ran, `2` not Windows, `3` bad arguments (a `-Path`
that is not a folder, or a number out of range).

From report to cleanup, in the order this repository always uses:

```powershell
# 1. What is filling the disk, and what gives each item back?
.\disk_usage.ps1

# 2. The report ends with the cleanup command for the rows it can reach.
#    Preview it - nothing is deleted:
.\clean_disk_c.ps1 -DryRun -IncludeRecycleBin -IncludeDevCaches

# 3. Then run it:
.\clean_disk_c.ps1 -Yes -IncludeRecycleBin -IncludeDevCaches

# A WSL disk is a different tool:
..\wsl\wsl_manage.ps1 df
..\wsl\wsl_manage.ps1 compact
```

Read the numbers as lower bounds when the shell is not elevated: folders under
`Windows` and other users' profiles are partly unreadable, and a row that hit
one says so. Measuring a large profile or `WinSxS` takes a while; the report
says how many locations it is about to measure before it starts.

Sizes are apparent: a file with several NTFS hard links, which is most of
`WinSxS`, counts once per link, so a total can exceed the space really used.
Telling links apart needs a handle on every file, which a walk of a whole
profile cannot afford, so the report says "apparent" rather than guessing.

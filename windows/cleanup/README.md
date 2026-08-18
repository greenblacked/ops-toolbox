# Disk C: Cleanup

`clean_disk_c.ps1` frees space on `C:` by deleting data that is genuinely
safe to lose. It never touches documents, downloads, application settings, or
anything under your user profile except designated cache/temp locations.

## Usage

```powershell
# Always start here - reports sizes per target, deletes nothing:
.\clean_disk_c.ps1 -DryRun

# Only profile-owned default targets (no elevation warnings):
.\clean_disk_c.ps1 -DryRun -Scope User

# Default clean (temp files older than 7 days + system caches):
.\clean_disk_c.ps1

# More aggressive:
.\clean_disk_c.ps1 -Days 3 -IncludeRecycleBin -IncludeWindowsUpdate -IncludeDevCaches
```

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

## What it deliberately does not touch

- Browser caches/profiles — too easy to nuke sessions and offline data.
- `C:\Windows\Installer` — breaks uninstall/repair of installed software.
- Hibernation file / pagefile — system-managed; disable via `powercfg` if
  you know you want that.
- WSL virtual disks — those shrink via
  [`../wsl/wsl_manage.ps1`](../wsl/wsl_manage.ps1) `compact` instead.

## Notes

- Locked/in-use files are skipped silently — normal for temp folders.
- The dry-run total is a lower bound: Recycle Bin, Delivery Optimization,
  npm, and Docker sizes are not included in the estimate (their tooling
  doesn't expose sizes cheaply); the real clean prints before/after free
  space, which captures everything.

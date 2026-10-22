# A WSL2 distro's virtual disk keeps growing

<!-- markdownlint-disable MD033 MD046 -->

**When to use:** a WSL2 distro's virtual disk has grown large on C:, and
deleting files inside the distro did not give the space back to Windows.

## Symptoms

- C: is nearly full although your Windows files are small.
- `wsl_manage.ps1 list` shows an `ext4.vhdx` of tens or hundreds of GB.
- You deleted files inside the distro (images, build output, caches) and
  C: did not recover. WSL2 virtual disks grow on their own but never shrink
  on their own.

## Before you start

- WSL installed and working. Every action except `verify-backup` first runs
  `wsl --status`, and exits `2` if WSL is missing or not operational.
- An **elevated** PowerShell (Run as Administrator), for `compact` only. It
  exits `4` without one. Every other action runs in a normal shell.
- Room for a backup. An export holds everything inside the distro, so the
  target drive needs that much free space. The default `-DestDir` is `%USERPROFILE%\wsl-backups`, which is on
  C:, so on a full C: pass `-DestDir` on another drive.
- The script. Work from a clone of the repository, or copy
  `windows\wsl\wsl_manage.ps1` onto the machine; it works on its own. See
  [Installation and usage](../getting-started/usage.md).
- More on the Windows scripts and their caveats is on the
  [Windows page](../platforms/windows.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    `list` and `df` only read. `df` does not start a stopped distro unless
    you pass `-Force`.

List the distros, then measure how much a shrink would give back:

```{ .powershell .rpt-report title="Report" }
.\windows\wsl\wsl_manage.ps1 list
.\windows\wsl\wsl_manage.ps1 df
.\windows\wsl\wsl_manage.ps1 df -Distro Ubuntu
```

`list` shows each distro's name, state, the size of its VHDX on disk and the
VHDX path. `df` puts two numbers side by side: **Allocated**, the VHDX file
on the Windows side, and **Used**, what `df` reports inside the distro.
**Reclaimable** is allocated minus used, which is what a compact (or sparse
mode) can give back. `-Distro NAME` narrows it to one distro.

**Allocated** is the file's logical length, not the space it takes on the
disk. If the VHDX is sparse, NTFS can free ranges inside it without the
length changing, so Reclaimable then overstates what a compact recovers.
For a sparse VHDX, check the size on disk before you decide to shrink:
Explorer's "Size on disk" in the file's properties, or one of these
(`fsutil` needs an elevated PowerShell):

```{ .powershell .rpt-report title="Size on disk of a sparse VHDX" }
fsutil sparse queryrange C:\path\to\ext4.vhdx
compact /q C:\path\to\ext4.vhdx
```

Measuring runs a command inside the distro, and running a command in a
stopped distro starts it. So `df` measures only running distros; a stopped
one shows `-` and a note that `-Force` measures it anyway, at the cost of
starting it.

Decide from the numbers. If Reclaimable is small, compacting will not help:
the space is really in use inside the distro. Delete data there first (for a
Linux distro, the [Linux low-disk runbook](linux-low-disk.md) applies inside
it), then run `df` again.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "compact and sparse have no -DryRun"
    The script's `-DryRun` covers `restore`, `prune-backups` and
    `terminate` only. For `compact` and `sparse`, the `df` report above is
    the preview: it says how much the VHDX should shrink.

If you keep dated backups, preview what the retention rule would delete
before you add a new one:

```{ .powershell .rpt-preview title="Preview backup retention" }
.\windows\wsl\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
```

It lists every backup as `KEEP` or `WOULD`, and ends with
`Dry run complete; N file(s) totalling X would be deleted.` A file is kept
when it is one of the newest `-KeepLast` for its distro **or** younger than
`-KeepDays`. Only `.tar` files named the way `backup` names them are ever
candidates. A real run (without `-DryRun`) asks before deleting, unless you
pass `-Force`, and removes each `.sha256` sidecar with its `.tar`.

## Apply

<span class="stage stage-apply">changes things</span>

Work in this order: back up, check the backup, then shrink.

**1. Back up.** Safe while the distro is running.

```{ .powershell .rpt-apply title="Back up" }
.\windows\wsl\wsl_manage.ps1 backup -Distro Ubuntu -DestDir D:\Backups
```

It runs `wsl --export` to `NAME_yyyy-MM-dd_HHmm.tar` in `-DestDir`, creating
the folder if needed, and writes a `.sha256` sidecar beside it. The run ends
with the `restore` command for that file.

**2. Check the backup.**

```{ .powershell .rpt-apply title="Verify the backup" }
.\windows\wsl\wsl_manage.ps1 verify-backup -Tar D:\Backups\Ubuntu_2026-10-21_0930.tar
```

`SHA-256 verified` means the tar matches its sidecar. A missing sidecar or a
mismatch exits `1`; do not go on until this passes.

**3. Shrink, one of two ways.**

!!! apply "compact stops all of WSL"
    `compact` runs `wsl --shutdown` first. **Every** distro and the WSL
    utility VM stop, not only the one you name, and unsaved work inside any
    of them is lost. Save and close everything in WSL first.

    `compact` starts `diskpart` right after `wsl.exe --shutdown` without
    checking that the shutdown worked, so a check after `compact` comes
    too late. Run `.\windows\wsl\wsl_manage.ps1 shutdown` first, confirm
    with `wsl -l -v` that every distro shows `Stopped`, and only then run
    `compact`.

```{ .powershell .rpt-apply title="Compact (elevated)" }
.\windows\wsl\wsl_manage.ps1 compact -Distro Ubuntu
```

After the shutdown it runs `diskpart` to attach the VHDX read-only,
`compact vdisk`, and detach it, then prints
`VHDX: <before> -> <after> (reclaimed <size>)`. The script does not check
`diskpart`'s exit code, so read its output: a reclaimed size of `0 KB` means
nothing was compacted.

Or switch the distro to sparse mode once, so that from then on WSL returns
freed space to Windows by itself:

```{ .powershell .rpt-apply title="Sparse" }
.\windows\wsl\wsl_manage.ps1 sparse -Distro Ubuntu
```

It runs `wsl --manage NAME --set-sparse true`. That needs a recent WSL; if
it fails, the script exits `1` and suggests `wsl --update`.

To stop things yourself first, `shutdown` stops all distros and the utility
VM, and `terminate -Distro NAME` stops one distro and leaves the others
running (`terminate` takes `-DryRun`).

| Exit | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | The underlying `wsl` command failed, or a backup did not verify. Exception: `compact` and `shutdown` do not check `wsl.exe --shutdown`, so a failed shutdown can still exit `0`. |
| `2` | WSL is not installed or not operational. |
| `3` | Bad arguments: no `-Distro`, no such distro, a missing or unusable `-Tar`, a `restore` name that is already registered, or a non-empty install directory. |
| `4` | `compact` without an elevated shell. |

## Verify

<span class="stage stage-report">read-only</span>

```{ .powershell .rpt-report title="Verify" }
.\windows\wsl\wsl_manage.ps1 df -Distro Ubuntu -Force
.\windows\wsl\wsl_manage.ps1 list
```

After `compact`, Allocated should now be close to Used. After `sparse`, the
script promises only that space is returned automatically from then on, so
the number may not drop at once. `compact` stopped the distro, so
`df` needs `-Force` to measure it, which starts it again and proves it
boots. `list` shows its state and the new VHDX size. Check C: itself with
`.\windows\setup\status.ps1 -Only disk`.

## Roll back

- **Sparse:** turn it off with
  `.\windows\wsl\wsl_manage.ps1 sparse -Distro Ubuntu -Off`.
- **Compact:** not reversible, and nothing to reverse: it only gives unused
  blocks back to Windows. It removes no data inside the distro.
- **Full recovery from the backup:**

```{ .powershell .rpt-apply title="Restore as a new distro" }
.\windows\wsl\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-10-21_0930.tar -DryRun
.\windows\wsl\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-10-21_0930.tar
```

What the script header says about `restore`:

- It imports the tar as a **new** distro and never overwrites an existing
  registration. A name that is already registered is refused. To take over
  an existing name you would remove it first with `wsl --unregister NAME`,
  which deletes that distro and its disk, so only do that once the restored
  copy works.
- `-InstallDir` is where the new `ext4.vhdx` goes. It defaults to
  `%LOCALAPPDATA%\WSL\NAME` and must be empty or absent. The tar is read,
  not moved, so you need room for a second copy.
- It checks the tar against its `.sha256` sidecar first. A tar with no
  sidecar is refused unless you pass `-AllowUnverified`.
- The restored distro boots as **root**: `wsl --import` does not carry the
  default user over. Add a `[user]` section with `default=YOURNAME` to
  `/etc/wsl.conf` inside it and terminate the distro once; a successful
  restore prints those steps.

## Related

- [A Windows PC is low on C: drive space](windows-low-disk.md): the rest of
  C:, with `clean_disk_c.ps1`.
- [Windows platform page](../platforms/windows.md)
- [`windows/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/windows/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 MD046 -->

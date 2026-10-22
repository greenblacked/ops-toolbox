# A Windows PC is low on C: drive space

<!-- markdownlint-disable MD033 -->

**When to use:** the C: drive of a Windows workstation or build agent is
nearly full and you need space back now, without uninstalling anything.

## Symptoms

- `status.ps1` warns that C: has under 20 GB free, or
  `workstation_doctor.ps1` warns that free space on C: is below its
  threshold.
- Windows updates fail for lack of space.
- Builds, installs or downloads fail with a "disk full" or "not enough
  space" error.

## Before you start

- Windows PowerShell 5.1 or PowerShell 7.
- An **elevated** shell (Run as Administrator) is optional. Without it,
  every system-wide target prints a `SKIP` line saying it needs elevation,
  and only the targets in your own profile are cleaned. The run says
  `Not elevated: selected system-wide targets will be skipped.` at the top.
- The scripts. Work from a clone of the repository, or copy
  `windows\setup\status.ps1`, `windows\setup\workstation_doctor.ps1` and
  `windows\cleanup\clean_disk_c.ps1` onto the machine; each works on its
  own. If the execution policy refuses to run them, see the execution
  policy note in the
  [`windows/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/windows/README.md).
- More on the Windows scripts and their caveats is on the
  [Windows page](../platforms/windows.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    Both scripts only read state. Run them first and note the numbers.

Get the one-line disk verdict, then the long report:

```{ .powershell .rpt-report title="Report" }
.\windows\setup\status.ps1 -Only disk
.\windows\setup\workstation_doctor.ps1
```

`status.ps1 -Only disk` prints the free space on C: and warns under 20 GB,
exiting `1` when it warns. `-ListSections` lists the other section ids; an unknown id exits `3` and an
empty selection exits `4`. `workstation_doctor.ps1` prints C: free space as
a size and a percentage and warns below 10 percent; `-MinFreePercent N`
changes that threshold. It exits `0` whenever the report ran, warnings or
not.

Find out where the weight is before you clean. If it is your own documents,
downloads, installed programs or virtual machines, this runbook will not
help: `clean_disk_c.ps1` removes temp files, caches and other data that is
regenerable, never documents. WSL distros keep their virtual disks on C:,
and those disks only grow; `.\windows\wsl\wsl_manage.ps1 df` shows how much
of each one is reclaimable, and the
[WSL disk runbook](wsl-disk-growing.md) shrinks them.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "Nothing is deleted"
    `-DryRun` measures each target and reports what it would delete. It
    stops no service and deletes nothing.

Start with the defaults:

```{ .powershell .rpt-preview title="Preview" }
.\windows\cleanup\clean_disk_c.ps1 -DryRun
```

Each target prints one line:

- `WOULD <target> <size> (<n> files)`: what a real run would delete.
  The count covers files only, and the preview names no files or
  directories. A real run also removes every empty directory under each
  selected target, including directories that were already empty,
  whatever their age or `-Days`. The preview does not count or list them.
- `SKIP <target> (needs elevation - run as Administrator)` or
  `SKIP <target> (not found)`: the target is left out.

The run ends with `Would free at least: <size>` and a note that the Recycle
Bin, Delivery Optimization, npm and Docker sizes are not in that estimate.

The defaults, and what decides each one:

| Target | What is removed | Needs elevation |
| --- | --- | --- |
| User temp | Files in `%TEMP%` older than `-Days` | No |
| Explorer thumbnail cache | Files in `%LOCALAPPDATA%\Microsoft\Windows\Explorer` older than one day, whatever `-Days` says | No |
| Windows temp | Files in `C:\Windows\Temp` older than `-Days` | Yes |
| Windows Error Reporting | Every queued report in the WER `ReportQueue` | Yes |
| Delivery Optimization cache | The whole cache, through Windows' own cmdlet | Yes |

`-Scope User` runs only the first two, `-Scope System` only the last three,
and `-Scope All` (the default) all five. `-Days N` takes `0` to `3650`,
default `7`. `-Days 0` drops the age filter: a real run then deletes every
temp file in both temp folders, including files that running programs are
using right now unless they are locked. Locked or in-use files are always
skipped, silently.

If that is not enough, add the opt-ins one at a time and preview again:

```{ .powershell .rpt-preview title="Preview more" }
.\windows\cleanup\clean_disk_c.ps1 -DryRun -IncludeRecycleBin -IncludeDevCaches
.\windows\cleanup\clean_disk_c.ps1 -DryRun -IncludeWindowsUpdate -IncludeDocker
```

| Switch | Effect |
| --- | --- |
| `-IncludeRecycleBin` | Empties the Recycle Bin on C:. Those files become unrecoverable. The dry run shows no size. |
| `-IncludeWindowsUpdate` | Needs elevation. Stops the `wuauserv` and `bits` services, clears `C:\Windows\SoftwareDistribution\Download`, then starts them again. Updates that were downloaded and are still pending download again. |
| `-IncludeDevCaches` | Clears the pip cache and the NuGet global packages folder, and runs `npm cache clean --force` when `npm` is installed. The next builds download again. |
| `-IncludeDocker` | Runs `docker system prune -f`: stopped containers, unused networks and dangling images go, volumes are **not** touched. The dry run runs `docker system df` to show current usage instead of a size. Skipped when `docker` is not installed. |

The opt-ins do not depend on `-Scope`.

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "Deletions are permanent"
    A real run requires `-Yes` and deletes files. Apply exactly the switches
    you previewed.

```{ .powershell .rpt-apply title="Apply" }
.\windows\cleanup\clean_disk_c.ps1 -Yes
```

Or, with the opt-ins you chose in the preview:

```{ .powershell .rpt-apply title="Apply with opt-ins" }
.\windows\cleanup\clean_disk_c.ps1 -Yes -IncludeRecycleBin -IncludeDevCaches
```

Without `-DryRun` or `-Yes` the script refuses before it inspects anything:
`refusing to delete without -Yes; preview with -DryRun`, exit `3`. There is
no `-WhatIf` or `-Confirm`; `-DryRun` and `-Yes` are the whole gate.

The script documents two exit codes: `0` success and `3` refused. No other
code reports a target that failed: a skipped target is a `SKIP` line, a file
that could not be removed is skipped silently, and the Recycle Bin, npm and
Docker steps print `CLEAN` without checking that their command succeeded.
Read every `CLEAN` and `SKIP` line in the output, not just the exit code.

## Verify

<span class="stage stage-report">read-only</span>

A real run ends with two lines:

- `Freed (measured per target): <size>`, the sum of what each target
  measured before deleting. Files that were locked are in that sum but were
  not removed, so it can be higher than what you got back.
- `Free space on C: now: <size> (was <size>)`, read from the drive itself.
  Trust this one.

Confirm with the report you started with:

```{ .powershell .rpt-report title="Verify" }
.\windows\setup\status.ps1 -Only disk
```

`[ ok ]` and exit `0` mean C: is above 20 GB free. If it is still low, go
back to the Report step: the space is held by something this script does not
remove.

## Roll back

Deleting is not reversible. `clean_disk_c.ps1` has no backup and no revert.
What it removes is meant to be regenerable:

- Temp files are disposable. Any that a program still needed are lost.
- The thumbnail cache, the pip, NuGet and npm caches and the Windows Update
  download cache are rebuilt or downloaded again when they are needed.
- Recycle Bin contents, error reports and stopped Docker containers (with
  anything written inside them) are gone for good. `-IncludeDocker` does not
  remove volumes.

The only safeguard is the preview. If a deletion looks wrong there, do not
apply it.

## Related

- [Windows platform page](../platforms/windows.md)
- [A Linux host is low on disk space](linux-low-disk.md): the same incident
  on Linux, with `disk_cleanup.sh`.
- [A WSL2 distro's virtual disk keeps growing](wsl-disk-growing.md): when
  the space is inside a WSL virtual disk.
- [Philosophy](../getting-started/philosophy.md): why every change starts
  with a report and a preview
- [`windows/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/windows/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 -->

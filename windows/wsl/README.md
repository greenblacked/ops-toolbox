# WSL maintenance

[Ops Toolbox](../../README.md) / **WSL maintenance**

`wsl_manage.ps1` covers the WSL2 chores that are annoying to remember:
finding where the virtual disks actually live, backing distros up and getting
them back, reclaiming the disk space WSL2 never gives back on its own, and
throwing away the giant `.tar` exports once they have aged out.

## Contents

- [Requirements](#requirements)
- [Why "compact" exists](#why-compact-exists)
- [Usage](#usage)
- [Actions](#actions)
- [Backing up everything](#backing-up-everything)
- [Restoring](#restoring)
- [Cloning a distro](#cloning-a-distro)
- [Pruning backups](#pruning-backups)
- [Auditing backups](#auditing-backups)
- [Distro doctor](#distro-doctor)
- [.wslconfig audit](#wslconfig-audit)
- [Git Bash shortcuts](#git-bash-shortcuts)

## Requirements

| Requirement | Notes |
| --- | --- |
| **Windows with WSL2** | Every action except `verify-backup`, `backups` and `wslconfig` probes for `wsl.exe` and then runs `wsl --status`, exiting `2` if either says WSL is absent or not operational. `wsl.exe` exists as a stub on machines that never installed WSL, which is why the second probe is there. |
| **Windows PowerShell 5.1 or PowerShell 7** | Run from the folder, or from anywhere by path. |
| **An elevated shell** | Only for `compact`, which drives `diskpart`. Unelevated it exits `4` and does nothing else. |
| **A recent WSL build** | Only for `sparse`, which needs `wsl --manage --set-sparse`. An older build fails the call and the script says to run `wsl --update`. |
| **Enough free disk for both copies** | For `restore`. `wsl --import` reads the `.tar` rather than consuming it, so the tar and the imported `ext4.vhdx` exist at the same time. |

`verify-backup` is the exception to all of it: it recomputes SHA-256 for a
`.tar` and compares it with the sidecar, so it needs no WSL and no elevation
and runs on a machine that only holds the backups. `backups` is the same: it
lists and hashes files. `wslconfig` is the other one: it reads
`%USERPROFILE%\.wslconfig` and nothing else.

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
.\wsl_manage.ps1 backup -All -DestDir D:\Backups -DryRun   # every distro, previewed
.\wsl_manage.ps1 backup -All -DestDir D:\Backups
.\wsl_manage.ps1 verify-backup -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar

# What is in the backup folder, is all of it intact, and is it recent enough?
.\wsl_manage.ps1 backups -DestDir D:\Backups
.\wsl_manage.ps1 backups -DestDir D:\Backups -Verify -MaxAgeDays 7

# Bring one back as a new distro (see "Restoring" below - read it first):
.\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar -DefaultUser me -DryRun
.\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar -DefaultUser me

# A throwaway copy to try something risky in (see "Cloning a distro"):
.\wsl_manage.ps1 clone -Distro Ubuntu -NewName Ubuntu-test -DryRun
.\wsl_manage.ps1 clone -Distro Ubuntu -NewName Ubuntu-test

# Throw away exports that have aged out (preview, then do it):
.\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2 -DryRun
.\wsl_manage.ps1 prune-backups -DestDir D:\Backups -KeepDays 30 -KeepLast 2

# Shrink after deleting files inside the distro (elevated PowerShell):
.\wsl_manage.ps1 compact -Distro Ubuntu -DryRun   # works unelevated
.\wsl_manage.ps1 compact -Distro Ubuntu

# Never think about it again (recent WSL): auto-return space from now on
.\wsl_manage.ps1 sparse -Distro Ubuntu
.\wsl_manage.ps1 sparse -Distro Ubuntu -Off   # revert

# Stop one distro, leaving the others and the utility VM alone:
.\wsl_manage.ps1 terminate -Distro Ubuntu

# Stop all distros + the utility VM (frees the RAM WSL is holding):
.\wsl_manage.ps1 shutdown

# Health of each running distro: WSL1, root default user, disk, clock, DNS:
.\wsl_manage.ps1 doctor
.\wsl_manage.ps1 doctor -Distro Ubuntu -ProbeHost registry.example.com

# Audit .wslconfig (read-only, needs no WSL), or print a starter file:
.\wsl_manage.ps1 wslconfig
.\wsl_manage.ps1 wslconfig -ConfigFile D:\profiles\.wslconfig -Strict
.\wsl_manage.ps1 wslconfig -Template > $env:USERPROFILE\.wslconfig.new
```

## Actions

| Action | Needs admin | Stops WSL | Notes |
| --- | --- | --- | --- |
| `list` | no | no | Joins `wsl -l -v` state with VHDX paths/sizes from the registry. |
| `df` | no | no | Allocated (VHDX file) against used (`df -Pk /` inside the distro), plus the reclaimable difference. Stopped distros show `-` unless `-Force` is passed, because measuring one starts it. |
| `backup` | no | no | `wsl --export` to `<DestDir>\<distro>_<date>.tar`; prints the matching `restore` command. Default `DestDir`: `%USERPROFILE%\wsl-backups`. `-All` exports every distro (see [Backing up everything](#backing-up-everything)); `-DryRun` prints the plan and writes nothing. |
| `verify-backup` | no | no | Recomputes SHA-256 for `-Tar` and compares it with the `.sha256` sidecar written by `backup`. Does not require WSL to be running. |
| `backups` | no | no | Inventory of the dated exports under `-DestDir`; `-Verify` hashes each against its sidecar, `-MaxAgeDays` flags a distro with no recent backup. Read-only; needs no WSL. See [Auditing backups](#auditing-backups). |
| `restore` | no | no | `wsl --import` of a `.tar` as a **new** distro. Needs `-Distro` (the new name) and `-Tar` (the file). `-DefaultUser` sets the user it boots as. `-DryRun` prints what it would register. |
| `clone` | no | no | Copy `-Distro` as `-NewName` through a staging export that is deleted afterwards (`-KeepTar` keeps it as a verified backup). Sets the copy's default user. `-DryRun` prints every step. See [Cloning a distro](#cloning-a-distro). |
| `prune-backups` | no | no | Deletes aged-out `.tar` exports under `-DestDir`. `-DryRun` previews; a real run asks before deleting unless `-Force`. |
| `compact` | **yes** (not for `-DryRun`) | **yes** (all distros) | `wsl --shutdown`, then diskpart `compact vdisk`. Prints before/after/reclaimed. `-DryRun` names the running distros the shutdown would stop and the disk it would compact, and says when the shell is not elevated. |
| `sparse` | no | no | `wsl --manage <distro> --set-sparse true` — needs a recent WSL (`wsl --update` if it fails). `-DryRun` prints the setting it would make. |
| `terminate` | no | one distro | `wsl --terminate <distro>`. Kills that distro's processes; other distros and the utility VM keep running. |
| `shutdown` | no | yes | Plain `wsl --shutdown`. `-DryRun` names the distros it would stop. |
| `doctor` | no | no | Per-distro health report, read-only. Running distros only unless `-Force`. See [Distro doctor](#distro-doctor). |
| `wslconfig` | no | no | Audits `%USERPROFILE%\.wslconfig` (or `-ConfigFile`): no memory cap, keys WSL ignores, values that do not parse. Read-only; needs no WSL. `-Template` prints a starter file. See [.wslconfig audit](#wslconfig-audit). |

`-DryRun` previews every action that changes something: `backup`, `restore`,
`prune-backups`, `clone`, `compact`, `sparse`, `terminate` and `shutdown`. None of the
previews calls `wsl --export`, `--import`, `--shutdown`, `--terminate`,
`--manage` or diskpart.

Exit codes: `0` success, `1` the underlying `wsl`/`diskpart` command failed
(for `backup -All`: one or more exports failed, the rest still ran; for
`backups`: a `BAD` or `MISS` tar under `-Verify`, or a `STALE` distro; for
`doctor`: at least one `FAIL`; for `wslconfig -Strict`: at least one `WARN`), `2` WSL is not installed or not
operational, `3` bad arguments (including a `-ConfigFile` that does not exist),
`4` needs an elevated shell (`compact`).

Take a `backup` before your first `compact` on a distro you care about —
compacting is safe and routine, but it is still a disk-level operation on
the only copy of that filesystem.

Every new backup has a neighboring `<name>.tar.sha256` file. `restore` verifies
it automatically and refuses both a mismatch and a missing sidecar, exiting `1`
either way; an older export without one needs `-AllowUnverified`. Keep the tar
and sidecar together when copying them. `prune-backups` removes a pruned tar's sidecar too,
so retention does not leave checksum files behind.

## Backing up everything

Before a Windows reinstall, a WSL upgrade or a distro upgrade, the step is
"export everything", and that used to be a loop written by hand.
`backup -All` exports every registered distro into `-DestDir` under one
timestamp, so the set is obvious from the names, and writes the same `.sha256`
sidecar for each as a single `backup` does, so `verify-backup` and
`restore -Tar` work on the results unchanged.

```powershell
.\wsl_manage.ps1 backup -All -DestDir D:\Backups -DryRun
```

```text
WOULD Ubuntu -> D:\Backups\Ubuntu_2026-10-21_1830.tar    4.20 GB
WOULD Debian -> D:\Backups\Debian_2026-10-21_1830.tar    1.10 GB
SKIP  docker-desktop                               managed by Docker Desktop
SKIP  docker-desktop-data                          managed by Docker Desktop
Dry run complete; 2 distro(s) would be exported, nothing was written.
```

- **Docker Desktop's distros are skipped.** `docker-desktop` and
  `docker-desktop-data` belong to Docker Desktop, which recreates them;
  exporting the data one is a multi-gigabyte copy of your image cache.
- **Space is checked before anything is written.** A running distro is measured
  with `df` inside it, and one whose use is more than the free space on the
  `-DestDir` drive is refused (`FAIL`) up front instead of failing half way.
  The exports share that drive, so each measured export let through takes its
  size off what the next distro is checked against, and a set that cannot fit
  together is refused for the distros that do not fit. A
  stopped distro is never started to measure it, the rule `df` follows too, so
  only its VHDX size is known; that is an upper bound, so a VHDX larger than
  the free space is a `WARN` and the export still runs. A `-DestDir` on a UNC
  share is not checked.
- **One failed export does not stop the rest.** The others carry on, and the
  run ends with `Exported N, skipped N, failed N` and exit `1` if anything
  failed.
- **A failed export never costs you a backup.** Each export is written to a
  temporary `.partial` file and moved onto its final name only once it has
  succeeded, so a failure removes just its own partial file. Running
  `backup` again in the same minute, where the name repeats, cannot delete
  the valid tar and sidecar the earlier run left.
- **The preview writes nothing**, not even `-DestDir`. `-All` and `-Distro`
  together are a usage error (exit `3`); `backup -Distro X -DryRun` previews
  one distro the same way.

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
   `--import` does not carry it over. Pass `-DefaultUser NAME` and restore
   sets it for you once the import has succeeded:

   ```powershell
   .\wsl_manage.ps1 restore -Distro Ubuntu-restored -Tar D:\Backups\Ubuntu_2026-08-08_0930.tar -DefaultUser me
   ```

   It reads `/etc/wsl.conf` inside the new distro and, when there is no
   `[user]` section, appends

   ```text
   [user]
   default=NAME
   ```

   then terminates the distro so the file is read at the next start, and
   confirms with `id -un` that it now starts as `NAME` (exit `1` if not, which
   usually means the user does not exist inside that tar). A `[user]` section
   that already sets `default=` is left alone; one without it is not edited,
   and the line to add is printed instead. `NAME` is checked before anything
   is read or imported (lowercase letters, digits, `_` and `-`, at most 32
   characters; anything else exits `3`), so a typo does not cost a long import.
   Without `-DefaultUser`, a successful restore prints the same steps to do by
   hand: add the section above with `wsl -d <name> -u root`, then
   `.\wsl_manage.ps1 terminate -Distro <name>`.

`-InstallDir` is where the new `ext4.vhdx` is written; it defaults to
`%LOCALAPPDATA%\WSL\<Distro>` and must be empty or absent. The tar is read,
not consumed, so plan for the disk holding both it and the imported disk at
once. Run it with `-DryRun` first: that prints the directory it would create,
the size it would import and the default user it would set, and registers
nothing.

## Cloning a distro

A throwaway copy of a working distro is the safest place to try a distro
upgrade, a new toolchain or a script you do not trust yet. By hand it is a
backup, a restore, an edit of `/etc/wsl.conf`, a terminate, and remembering to
delete the tar. `clone` is all of that in one step:

```powershell
.\wsl_manage.ps1 clone -Distro Ubuntu -NewName Ubuntu-test -DryRun
.\wsl_manage.ps1 clone -Distro Ubuntu -NewName Ubuntu-test
.\wsl_manage.ps1 clone -Distro Ubuntu -NewName Ubuntu-test -InstallDir D:\WSL\Ubuntu-test -DestDir D:\Backups -DefaultUser me -KeepTar
```

1. Exports `-Distro` to a staging tar in `-DestDir`, named
   `.clone-<NewName>-<pid>.tar`: a leading dot and no date, so neither
   `prune-backups` nor `backups` can ever take it for a backup. Exporting is
   safe while the source runs, and the source is never changed.
2. Imports it as `-NewName` into `-InstallDir` (default
   `%LOCALAPPDATA%\WSL\<NewName>`, which must be empty or absent).
3. Sets the copy's default user: `-DefaultUser` when given, otherwise the
   source's own default user, looked up by its uid inside the copy. A source
   that boots as root gives a copy that boots as root.
4. Terminates the copy so `/etc/wsl.conf` is read at its next start.
5. Deletes the staging tar, in a `finally` block, so a failure or Ctrl+C does
   not leave a full copy of the distro behind. `-KeepTar` instead renames it
   to `<Distro>_<date>.tar` with a `.sha256` sidecar, a normal backup that
   `verify-backup`, `backups` and `restore` work with.

Everything that can refuse is checked before the export: the source must be
registered, `-NewName` must be given, free and different from the source,
`-DefaultUser` must be a valid name, and the install directory must be empty
(all exit `3`). A running source is measured with `df`, and when its use is
more than the free space on the `-DestDir` drive, clone refuses (exit `1`)
rather than fail half way; a stopped source is not started to measure it, so
its VHDX size is printed as an upper bound. A failed export or import exits
`1` and removes the staging tar and any install directory clone created
itself. Nothing is unregistered, ever. Remove the copy when you are done with
`wsl --unregister <NewName>`.

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

## Auditing backups

`verify-backup` checks one tar. The question a runbook or a scheduled task
asks before a risky change is wider: what backups are there, are they all
intact, and is the newest one recent enough? `backups` answers it for the
dated exports under `-DestDir` (only files named the way `backup` writes them;
anything else in the folder is ignored, as with `prune-backups`).

```powershell
.\wsl_manage.ps1 backups -DestDir D:\Backups
.\wsl_manage.ps1 backups -DestDir D:\Backups -Verify -MaxAgeDays 7
.\wsl_manage.ps1 backups -DestDir D:\Backups -Distro Ubuntu -Verify
```

Without `-Verify` nothing is hashed: one line per tar, newest first within
each distro, with its size, its age and whether its sidecar is there.

```text
OK    Ubuntu_2026-10-20_0900.tar                      4.20 GB    1d   sha256:present
OK    Ubuntu_2026-10-13_0900.tar                      4.10 GB    8d   sha256:missing
```

`-Verify` hashes every tar against its `.sha256` sidecar, after a line saying
how much it is about to read, because a multi-gigabyte tar takes minutes. Each
tar is `OK`, `MISS` (no sidecar) or `BAD` (a malformed sidecar, or a
checksum that does not match, with the expected and actual hashes printed
under it). Catching a truncated or bit-rotted export the day it happens beats
finding it at the restore.

`-MaxAgeDays N` adds `STALE <distro> newest backup is 12 day(s) old (limit 7)`
for every distro whose newest export is older than `N` days, by the file's
last-write time, the clock `prune-backups` uses. An empty or missing folder
prints `No dated .tar exports under <dir>` and exits `0`, unless
`-MaxAgeDays` is given: then there is by definition no recent backup, and it
exits `1`. A footer counts backups, total size, verified, bad, missing
sidecars and stale distros.

It only reads: it never deletes, renames or rewrites a tar or a sidecar,
needs no WSL and no elevation, and runs on a machine that only holds the
backups.

Exit codes: `0` nothing wrong, `1` a `BAD` or `MISS` tar under `-Verify`, or a
`STALE` distro. A `-Distro` with no backups is simply an empty list.

## Distro doctor

A WSL environment that has gone "weird" is usually one of a handful of known
things, each diagnosed by hand until now: the clock inside the distro drifted
while Windows slept, so TLS and cloud API signatures fail; a restored distro
boots as root; the root filesystem is at 98 percent; DNS died behind a VPN; a
distro was left on WSL1, where docker and kind cannot run. `doctor` checks
each running distro for all of them and prints the fix.

```powershell
.\wsl_manage.ps1 doctor
.\wsl_manage.ps1 doctor -Distro Ubuntu -ProbeHost registry.example.com
.\wsl_manage.ps1 doctor -Force          # also start stopped distros to check them
```

```text
== Ubuntu (Running, WSL2) ==
OK    version          WSL2
OK    default user     me
OK    init             systemd
WARN  root filesystem  91% used: free space inside the distro, then 'compact' gives it back to Windows ('df' shows how much)
WARN  clock            42 s behind the host: fix: wsl --shutdown, or sudo hwclock -s
OK    dns              resolves github.com

2 warning(s), 0 failure(s)
```

| Check | Finding |
| --- | --- |
| WSL version | `1` is a `FAIL`: no real kernel, so docker, kind and k3s will not run (`wsl --set-version <name> 2`) |
| Default user (`id -un`) | `root` is a `WARN`, typical after `wsl --import` or `restore`; see [Restoring](#restoring) |
| PID 1 (`/proc/1/comm`) | Not `systemd` is `INFO`: set `[boot] systemd=true` in `/etc/wsl.conf` for docker or k3s services |
| Root filesystem (`df -Pk /`) | `85`% or more is a `WARN`, `95`% or more a `FAIL` |
| Clock (`date +%s` against the host) | More than 5 seconds apart is a `WARN`, more than 300 a `FAIL` (`wsl --shutdown`, or `sudo hwclock -s`) |
| DNS (`getent hosts`) | `-ProbeHost` (default `github.com`) not resolving is a `WARN`: check the VPN, `dnsTunneling` in `.wslconfig`, `/etc/resolv.conf` |
| `PATH` | More than 10 entries under `/mnt/c` is `INFO`: `[interop] appendWindowsPath=false` speeds up completion |

Only running distros are checked: running a command in a stopped distro
starts it, the side effect `df` avoids too, so a stopped one is listed as
`SKIP` until you pass `-Force`. Docker Desktop's distros are skipped. Each
command has a 15-second limit, so a wedged distro cannot hang the report. It
only reads (`id`, `cat`, `df`, `date`, `getent`, `echo`), writes nothing
inside or outside the distro, and prints remedies rather than running them;
`-DryRun` is accepted and ignored.

Exit codes: `0` the report ran with no `FAIL`, `1` one or more `FAIL`, `2` WSL
is not installed or not operational, `3` `-Distro` names no registered distro
or `-ProbeHost` is not a host name.

## .wslconfig audit

The usual reason the `vmmem` process holds most of the RAM while Docker, k3s or
a build runs is `%USERPROFILE%\.wslconfig`: missing, without a memory cap, or
with keys WSL reads past without a word. WSL starts happily with a key in the
wrong section or a misspelt name and simply ignores it, so the cap you wrote is
not the cap you have. `wslconfig` reads the file and says what WSL will make of
it. It never edits it, never calls `wsl.exe`, and runs where WSL is absent.

```text
[wsl2]
processors=4
# the cap
memry=8GB
swap=2GB
autoMemoryReclaim=gradual
```

```powershell
.\wsl_manage.ps1 wslconfig
```

```text
Checking C:\Users\me\.wslconfig

WARN  [wsl2] memry (line 4)                        unrecognised key (typo, or newer than this table)
WARN  [wsl2] autoMemoryReclaim (line 6)            belongs in [experimental]; ignored here
OK    [wsl2] swap (line 5)                         2GB
OK    [wsl2] processors (line 2)                   4
WARN  [wsl2] memory                                no memory cap: the VM can grow to about half of RAM (set memory=8GB, say)
INFO  [experimental] autoMemoryReclaim             consider autoMemoryReclaim=gradual: freed memory goes back to Windows
INFO  [experimental] sparseVhd                     consider sparseVhd=true (or wsl_manage.ps1 sparse for an existing distro)

3 warning(s). WSL reads this file when the VM starts: 'wsl --shutdown' after editing it.
```

| Finding | Level |
| --- | --- |
| No `.wslconfig` at the default path; WSL sizes the VM itself | `INFO` |
| A key before any `[section]`, or a line that is not `key=value` | `WARN` |
| A section `.wslconfig` does not read: `[wsl]`, `[wsl2 ]`, or a `/etc/wsl.conf` section such as `[boot]`; only `[general]`, `[wsl2]` and `[experimental]` are read | `WARN` |
| A key under the wrong one of `[general]`, `[wsl2]` and `[experimental]` (an `[experimental]` key under `[wsl2]`, say) | `WARN` |
| A key the table does not know: a typo, or a setting newer than the table | `WARN` |
| `memory` or `swap` that is not a size (`8GB`, `512MB`; a bare number is bytes, so `swap=0` is fine), `processors` that is not a positive whole number | `WARN` |
| `memory` above the installed RAM, `processors` above the logical processors (Windows only; skipped with an `INFO` line elsewhere) | `WARN` |
| A true/false key (`sparseVhd`, `firewall`, `dnsTunneling`, `localhostForwarding` and the like) set to anything but `true` or `false`, in any case | `WARN` |
| A single backslash in `kernel` or `swapFile`: write `C:\\Users\\me\\...` or use forward slashes | `WARN` |
| `autoMemoryReclaim` set to anything but `disabled`, `gradual` or `dropCache`, in any case | `WARN` |
| No `memory` cap | `WARN` |
| No `autoMemoryReclaim` or `sparseVhd` under `[experimental]` | `INFO` |
| `localhostForwarding` with `networkingMode=mirrored`, where it has no effect | `INFO` |

The known-key table is taken from Microsoft's *Advanced settings configuration
in WSL* page and is best effort, which is why an unknown key is a warning and
never a failure. The recommended values are suggestions printed as `INFO`;
nothing is changed.

`-ConfigFile PATH` audits another file, for example a profile you keep in a
repository. `-Strict` turns any `WARN` into exit `1`, for a login script or a
scheduled check; without it the report always exits `0`. `-Template` prints a
commented starter (`memory=8GB`, `processors=4`, `swap=2GB`,
`autoMemoryReclaim=gradual`, `sparseVhd=true`) to stdout and writes nothing;
redirect it yourself, review it, and run `wsl --shutdown` so WSL reads it.

Exit codes: `0` the report ran (warnings alone do not change it), `1` with
`-Strict`, one or more warnings, `3` a `-ConfigFile` that does not exist or
cannot be read. A missing file at the default path is not an error.

## Git Bash shortcuts

[`../git-bash/.aliases`](../git-bash/.aliases) defines (only when `wsl.exe`
exists): `wsls` (list -v), `wslsh` (shutdown), `wslup` (update),
`wslstatus`, and `wslr <cmd>` to run a single command in the default distro.

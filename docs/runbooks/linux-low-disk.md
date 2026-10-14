# A Linux host is low on disk space

<!-- markdownlint-disable MD033 -->

**When to use:** the root filesystem of a Linux host is nearly full and you
need space back now, without upgrading anything.

## Symptoms

- `linux/status.sh` warns that less than 20G is free on `/`, or
  `linux/system_doctor.sh` warns that `/` is nearly full.
- Writes fail with "No space left on device", or a service stops logging.
- Creating files fails although `df -h` shows free space. That points at
  inodes, not bytes; the doctor report checks inode use too.

## Before you start

- A shell on the host. The read-only reports need no `sudo`. The cleanup
  steps that touch the journal, the package cache or core dumps may need
  root, and the script uses `sudo` for them unless you pass `--no-sudo`.
- The scripts. Work from a clone of the repository, or copy
  `linux/status.sh`, `linux/system_doctor.sh` and `linux/disk_cleanup.sh`
  onto the host; each works on its own. See
  [Installation and usage](../getting-started/usage.md).
- Bash 3.2+ on a Debian/Ubuntu, Fedora/RHEL or Arch host. More on the
  scripts, their requirements and caveats is on the [Linux page](../platforms/linux.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    Both scripts only read state. Run them first and note the numbers.

Get the one-screen verdict for the disk, then the long report with its hint
for finding what is using the space:

```{ .bash .rpt-report title="Report" }
./linux/status.sh --only disk
./linux/system_doctor.sh
```

When `/` is below the free-space threshold, `system_doctor.sh` prints a
`du` command that lists the largest directories. Run it to see where the
weight is. If a different mount (for example `/var`) is the full one, the
report lists other real filesystems as well.

Decide from what you find. If the space is held by your own data, logs you
need, or application files, this runbook will not help: `disk_cleanup.sh`
removes only temp files, caches and other data that is safe to lose, and
never touches documents or downloads.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "Nothing is deleted"
    `--dry-run` deletes nothing. It lists the individual files it would
    remove, and for some groups it only prints the command it would run.

Start with the defaults, which are user-owned temp files older than seven
days and thumbnail caches:

```{ .bash .rpt-preview title="Preview" }
./linux/disk_cleanup.sh --dry-run
```

For temp files, thumbnails, trash, core dumps and the pip, yarn and Go cache
directories under `~/.cache`, the dry run lists each candidate path, with a
size for each file. These groups run a command instead, so the dry run prints
only the command, or a skip notice when the tool is missing or root is
unavailable, and lists nothing: the journal vacuum, the package cache clean,
the `pip3`, `npm`, `yarn` and `go` cache purges, and the Docker and Podman
prune. Their sizes are not in the "would free at least" total.

The run ends with a `df -h /` view and that total. If that is not enough,
add the opt-in groups one at a time and preview again:

```{ .bash .rpt-preview title="Preview more" }
./linux/disk_cleanup.sh --dry-run --include-trash --include-dev-caches
./linux/disk_cleanup.sh --dry-run --include-journal --include-pkg-cache
./linux/disk_cleanup.sh --dry-run --include-docker --include-coredumps
```

What each group does:

| Flag | Effect |
| --- | --- |
| `--include-trash` | Empties `~/.local/share/Trash`. |
| `--include-dev-caches` | Clears the pip, npm, yarn and Go module caches. Lists files for the `~/.cache` pip, yarn and go-build directories; the `pip3`, `npm`, `yarn` and `go` purges are command only. |
| `--include-journal` | Runs `journalctl --vacuum-time=<days>d` with `--days` (needs root). Command only in the dry run. |
| `--include-pkg-cache` | Cleans the apt, dnf or pacman package cache (needs root). Command only in the dry run. |
| `--include-docker` | Runs `system prune -f` for Docker and Podman. It removes all stopped containers (and anything written inside them), unused networks, dangling images and build cache. Volumes are left alone. The dry run only prints the command and does not list what would go; check first with `docker ps -a` and `docker system df`. |
| `--include-coredumps` (may need root) | Removes age-filtered core dumps from the systemd-coredump and apport directories. |

The age filter (`--days`, default 7) applies only to temp files and core
dumps. Thumbnails, trash, dev caches, the package cache and the container
prune remove everything regardless of age. The journal vacuum uses `--days`
as its age limit, so it keeps recent entries.

`--days 0` drops the age filter for temp files and core dumps: a real run
then deletes every temp file you own in `/tmp` and `$TMPDIR`, including
files that running programs are using right now. With `--include-journal`
it passes `--vacuum-time=0d` to `journalctl`. The script prints a warning
that this "removes the entire journal", but that overstates what the command
does. The script does not run `journalctl --rotate`, and `journalctl`
vacuuming acts only on archived journal files, never on the active ones. Its
documentation treats a value of 0 as no limit, so this may free little or
nothing. Do not count on it to
free space, and do not rely on it to empty the journal. Look at the size
first with `journalctl --disk-usage`. Rotating the journal (`journalctl
--rotate`) archives the active files; that is a separate manual step the
script does not take. Keep the journal until you have found the cause.

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "Deletions are permanent"
    A real run requires `--yes` and deletes files. Apply exactly the flags
    you previewed.

```{ .bash .rpt-apply title="Apply" }
./linux/disk_cleanup.sh --yes
```

Or, with the groups you chose in the preview:

```{ .bash .rpt-apply title="Apply with opt-in groups" }
./linux/disk_cleanup.sh --yes --include-trash --include-dev-caches
```

Add `--no-sudo` to skip every step that needs root. Exit codes: `0` success,
`1` one or more deletions failed, `2` preflight failed (not Linux, or
`$HOME` unset), `3` bad arguments (including a real run without `--yes`).
A failed pip, npm, yarn or Go cache purge only prints a warning and still
exits `0`, so check the output as well as the exit code.

## Verify

<span class="stage stage-report">read-only</span>

The cleanup run ends with a `df -h /` view and a "freed at least" total.
Confirm with the same reports you started with:

```{ .bash .rpt-report title="Verify" }
./linux/status.sh --only disk
./linux/system_doctor.sh --quiet
```

`--quiet` prints only warnings, so no disk warning means the check passed. If `/` is still full, go back to the Report step and look
at the largest directories again: the space is held by something this script
does not remove.

## Roll back

Deleting is not reversible. `disk_cleanup.sh` has no backup and no `--revert`.
What it removes is meant to be regenerable:

- Thumbnails, package caches and dev caches are rebuilt by the tools that
  use them. Temp files are disposable, not rebuilt: any that a running
  program still needed are lost.
- Trash, journal entries, core dumps and stopped containers (with anything
  written inside them) are gone for good once removed and cannot be
  recovered. `--include-docker` does not remove volumes.

The only safeguard is the preview. If a deletion looks wrong there, do not
apply it.

## Related

- [Linux platform page](../platforms/linux.md)
- [Philosophy](../getting-started/philosophy.md): why every change starts
  with a report and a preview
- [`linux/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/linux/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 -->

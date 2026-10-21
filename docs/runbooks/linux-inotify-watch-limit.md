# An IDE or file watcher hits the inotify limit

<!-- markdownlint-disable MD033 -->

**When to use:** an editor, a dev server or a build tool on a Linux machine
says it cannot watch any more files, and you want to raise the inotify
limits in a way you can undo.

## Symptoms

- `ENOSPC: System limit for number of file watchers reached`, or an IDE
  warning that it cannot watch the project for changes.
- A dev server or test watcher stops noticing edits in a large tree.
- `tail -f` or another watcher reports that inotify resources are exhausted.

## Before you start

- A shell on a Linux machine. The script is exit `2` anywhere else.
- Root for `--apply` and for a real `--revert`. Without it they exit `2`.
  The report and every `--dry-run` preview run without root, except a revert
  preview of a backup only root can read.
- The script. Work from a clone of the repository, or copy
  `linux/sysctl_defaults.sh` onto the machine; it works on its own. See
  [Installation and usage](../getting-started/usage.md).
- More on the Linux scripts and their caveats is on the
  [Linux page](../platforms/linux.md).

## Report

<span class="stage stage-report">read-only</span>

!!! report "Nothing changes in this step"
    With no flags, `sysctl_defaults.sh` only reads the current values. It is
    the default mode.

```{ .bash .rpt-report title="Report" }
./linux/sysctl_defaults.sh --list-groups
./linux/sysctl_defaults.sh --only inotify
```

Each key prints as `[ ok ] key = value` when it already has the value the
script wants, or as `[info] key = current  (desired X)  reason` when it does
not. A key the kernel does not expose prints `[skip] key unreadable`.

The script manages four keys in two groups:

| Group | Key | Value it sets | Why |
| --- | --- | --- | --- |
| `inotify` | `fs.inotify.max_user_watches` | `524288` | File-watcher ceiling for IDEs and recursive watches. |
| `inotify` | `fs.inotify.max_user_instances` | `1024` | Concurrent inotify instances per user. |
| `inotify` | `fs.inotify.max_queued_events` | `16384` | Event queue before events are dropped. |
| `vm` | `vm.swappiness` | `10` | Prefer RAM over swap on a workstation. |

For the watcher problem you only need the `inotify` group. `vm.swappiness 10`
is a workstation preference that is wrong for many servers, so leave `vm`
out unless you want that too. Every command below passes `--only inotify`.

## Preview

<span class="stage stage-preview">dry run</span>

!!! preview "Nothing is written"
    `--apply --dry-run` prints the drop-in it would write and each live
    change, and needs no root.

```{ .bash .rpt-preview title="Preview" }
./linux/sysctl_defaults.sh --apply --only inotify --dry-run
```

It shows `would write /etc/sysctl.d/99-ops-toolbox.conf` with the file's
body, then one `sysctl -w key=value (now X)` line per key, and ends with
`dry-run complete; no changes written`.

## Apply

<span class="stage stage-apply">changes things</span>

!!! apply "sysctl changes are live"
    `--apply` changes the running kernel at once and writes a drop-in that
    applies the same values at every boot.

```{ .bash .rpt-apply title="Apply" }
sudo ./linux/sysctl_defaults.sh --apply --only inotify --backup-file /root/sysctl.before
```

In order, it:

1. writes the current values of the selected keys to the backup file,
2. writes `/etc/sysctl.d/99-ops-toolbox.conf`,
3. sets each value live.

Pass `--backup-file`. Without it the backup is
`sysctl_defaults-backup-<timestamp>.txt` under `$TMPDIR`, or `/tmp` when
that is unset, which may not survive a reboot. A file you name stays where
you put it. `--backup-file` refuses to overwrite a file that already exists
and is not empty: `refusing to overwrite FILE`, exit `3`, before the drop-in
is written.

!!! warning "--only rewrites the whole drop-in"
    The drop-in is written from scratch with only the groups `--only`
    names. If an earlier `--apply` put `vm` in it, applying `--only inotify`
    drops `vm` from the file. The live value does not change now, but it
    reverts at the next boot. The script warns about this when the file
    already exists. The backup holds only the groups you named, so it
    cannot put the dropped ones back either.

Exit codes: `0` success, `1` one or more settings failed to apply, `2` not
Linux or not root, `3` bad arguments (including a non-empty
`--backup-file`).

## Verify

<span class="stage stage-report">read-only</span>

```{ .bash .rpt-report title="Verify" }
./linux/sysctl_defaults.sh --only inotify
```

Every key should now print `[ ok ]`. Then restart the editor, dev server or
watcher that failed and confirm the error is gone; programs that already
hit the limit may need a restart to pick up the new one.

## Roll back

Preview first. `/root` is normally readable only by root, so for a backup
there the preview needs `sudo` too:

```{ .bash .rpt-preview title="Preview the revert" }
sudo ./linux/sysctl_defaults.sh --revert --revert-from /root/sysctl.before --dry-run
```

It prints `would restore from /root/sysctl.before`,
`would remove /etc/sysctl.d/99-ops-toolbox.conf` and the values in the
backup, then `dry-run complete; no changes written`.

```{ .bash .rpt-apply title="Revert" }
sudo ./linux/sysctl_defaults.sh --revert --revert-from /root/sysctl.before
```

`--revert-from` only names the file; `--revert` is what selects the mode.
Without `--revert`, the command just prints the report.

What a revert does and does not do:

- It sets each key in the backup back to its recorded value, live, and
  removes the drop-in. The whole drop-in goes, including any group an
  earlier apply had put there.
- It restores only keys this script manages; any other line in a backup is
  skipped with a warning.
- A key the script could not read before the apply was not written to the
  backup, so it is not restored.
- Without `--revert-from` it uses the newest trustworthy
  `sysctl_defaults-backup-*.txt` under `$TMPDIR` (or `/tmp`). A backup you
  wrote elsewhere with `--backup-file` is not found that way, so always
  pass `--revert-from` for it.
- A backup is refused (exit `3`) unless it is owned by root or by you and
  writable by nobody else. The script prints the `chown` and `chmod`
  command that fixes it.

## Related

- [Linux platform page](../platforms/linux.md)
- `linux/system_doctor.sh` for the wider health report of the machine.
- [`linux/` folder README](https://github.com/greenblacked/ops-toolbox/blob/master/linux/README.md)
- [Scripts overview](../scripts/index.md)

<!-- markdownlint-enable MD033 -->

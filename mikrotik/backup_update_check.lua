# Update check with a pre-upgrade backup, in the plain style: a fixed wait, a
# message on every run ("update is required" / "not required"), and when an
# update is available a backup-<identity>-<date>-<installed version>-pre-upgrade
# .backup/.rsc pair taken first, older backup-* files pruned only after the new
# pair is written. The sibling update_check.lua is the more careful design;
# this one exists because it runs where that one does not.
#
# No :global here carries an underscore in its name, and that is the point.
# RouterOS 7.24 refuses to execute a script that declares one - "expected end
# of command" at the underscore, from the scheduler, from :parse and from
# /system script run alike - and it was seen on hardware, not only on the CHR
# the suite boots. update_check.lua declares six. This script was run end to
# end on a 7.24.1 CHR: it found a real newer release, wrote the pair, pruned a
# seeded older generation and delivered the message.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

# --- settings ----------------------------------------------------------------
# The Telegram helper to call. Not the package's tg_send: that one declares
# TG_BOT_TOKEN and TG_CHAT_ID, so on 7.24 it fails the same way update_check
# does, and a script that runs calling a helper that cannot is a message that
# never arrives. tg_send_new is the operator's own copy that does run there;
# point this at whatever helper the router actually has.
:local TgSendScript "tg_send_new"

# Forced to this channel on every run, which is what the script this came from
# did and what a fleet that is meant to sit on one train wants: a router
# somebody switched by hand is put back before it is checked. Set it to "" to
# leave the channel exactly as the router has it and only report it, which is
# the stance update_check.lua takes - a check script reports state, it does
# not decide policy.
:local updChannel "stable"

:local TakeBackup true
:local RemovePrevious true

# Optional password for the binary backup. Set it from a :global at boot, the
# way the rest of the package does, so it never sits in a tracked file:
#
#     /system script add name=startup source={:global RouterBackupPassword "s3cret";}
#     /system scheduler add name=startup on-event=startup start-time=startup
#
# The global's name has no underscore for the reason in the header.
:local BackupPassword ""
:global RouterBackupPassword
:if ([:len $RouterBackupPassword] > 0) do={ :set BackupPassword $RouterBackupPassword }

# -----------------------------------------------------------------------------
:local DeviceName [/system identity get name]

:if ([:len $updChannel] > 0) do={
    /system package update set channel=$updChannel
}
:local Channel "unknown"
:do {
    :set Channel [/system package update get channel]
} on-error={
    :set Channel "unknown"
}

/system package update check-for-updates

:delay 15s

:local InstalledVersion "unknown"
:local LatestVersion "unknown"

:do {
    :set InstalledVersion [/system package update get installed-version]
} on-error={
    :set InstalledVersion "unknown"
}

:do {
    :set LatestVersion [/system package update get latest-version]
} on-error={
    :set LatestVersion "unknown"
}

:local BoardName "unknown"
:local Architecture "unknown"
:local Uptime "unknown"
:local CpuLoad "unknown"
:local FreeMemory "unknown"
:local TotalMemory "unknown"
:local FreeHdd "unknown"
:local TotalHdd "unknown"

:do {
    :set BoardName [/system resource get board-name]
} on-error={
    :set BoardName "unknown"
}

:do {
    :set Architecture [/system resource get architecture-name]
} on-error={
    :set Architecture "unknown"
}

:do {
    :set Uptime [/system resource get uptime]
} on-error={
    :set Uptime "unknown"
}

:do {
    :set CpuLoad [/system resource get cpu-load]
} on-error={
    :set CpuLoad "unknown"
}

# In MiB: the raw byte counts are unreadable, and free storage is the figure
# that decides whether an upgrade can proceed at all.
:do {
    :set FreeMemory ([/system resource get free-memory] / 1048576)
} on-error={
    :set FreeMemory "unknown"
}

:do {
    :set TotalMemory ([/system resource get total-memory] / 1048576)
} on-error={
    :set TotalMemory "unknown"
}

:do {
    :set FreeHdd ([/system resource get free-hdd-space] / 1048576)
} on-error={
    :set FreeHdd "unknown"
}

:do {
    :set TotalHdd ([/system resource get total-hdd-space] / 1048576)
} on-error={
    :set TotalHdd "unknown"
}

# RouterBOARD firmware: a RouterOS upgrade is usually followed by
# /system routerboard upgrade and a reboot, so say whether one is waiting.
# CHR and x86 have no routerboard - the line is simply omitted there.
:local FirmwareLine ""
:do {
    :local FwCurrent [/system routerboard get current-firmware]
    :local FwUpgrade [/system routerboard get upgrade-firmware]
    :set FirmwareLine ("\0AFirmware: <code>" . $FwCurrent . "</code>")
    :if ($FwCurrent != $FwUpgrade) do={
        :set FirmwareLine ($FirmwareLine . " -> <code>" . $FwUpgrade . "</code> (upgrade available)")
    }
} on-error={
    :set FirmwareLine ""
}

# Resolved once, wrapped: a missing helper must not kill the run before the
# backup below, and the router log has to say what went wrong.
:local SendTelegramMessage ""
:do {
    :set SendTelegramMessage [:parse [/system script get $TgSendScript source]]
} on-error={
    :log error ("backup_update_check: Telegram helper '" . $TgSendScript . "' not found - messages will not be sent")
}

# "unknown" != installed would also be true when the check itself failed, and
# that must not take a backup and prune the previous one on a false alarm.
:if (($InstalledVersion != $LatestVersion) and ($LatestVersion != "unknown")) do={

    # --- pre-upgrade backup ---------------------------------------------------
    :local BackupLine ""
    :if ($TakeBackup) do={
        :local rawDate [/system clock get date]
        :local Time [/system clock get time]

        # Never let '/' into the filename: a non-ISO date format (mdy/dmy)
        # would turn it into subdirectories instead of a file.
        :local Date ""
        :for i from=0 to=([:len $rawDate] - 1) do={
            :local ch [:pick $rawDate $i ($i + 1)]
            :if ($ch = "/") do={ :set ch "-" }
            :set Date ($Date . $ch)
        }

        # The installed version is the one still running - the one this file
        # restores you to. The backup- prefix is what pull_router_backups.sh
        # collects and backup_file_cleanup.lua ages out.
        :local BackupFile ("backup-" . $DeviceName . "-" . $Date . "-" . $InstalledVersion . "-pre-upgrade")

        :local BackupOk false
        :do {
            :if ([:len $BackupPassword] > 0) do={
                /system backup save name=$BackupFile password=$BackupPassword
            } else={
                /system backup save name=$BackupFile dont-encrypt=yes
            }
            /export file=$BackupFile
            :set BackupOk true
            :log info ("backup_update_check: pre-upgrade backup created: $BackupFile")
            :set BackupLine ("\0ABackup: <code>" . $BackupFile . "</code>")
        } on-error={
            :log error ("backup_update_check: pre-upgrade backup FAILED on $DeviceName at $Date $Time")
            :set BackupLine "\0ABackup: <code>FAILED - nothing to roll back to</code>"
        }

        # Only after the new pair is written, so a failed backup can never be
        # the run that deletes the last good one. Keeps everything that starts
        # with the new base name - /export writes through a .rsc.in_progress
        # temporary and returns before it is finished, and an exact-name test
        # would delete that half-written export.
        :if ($BackupOk and $RemovePrevious) do={
            :local Keep [:len $BackupFile]
            :local Removed 0
            :do {
                :foreach f in=[/file find where name~"^backup-"] do={
                    :do {
                        :local nm [/file get $f name]
                        :if ([:pick $nm 0 $Keep] != $BackupFile) do={
                            /file remove $f
                            :log info ("backup_update_check: removed previous backup $nm")
                            :set Removed ($Removed + 1)
                        }
                    } on-error={
                        :log warning "backup_update_check: could not remove a previous backup file"
                    }
                }
            } on-error={
                :log warning "backup_update_check: could not list files to prune previous backups"
            }
            :if ($Removed > 0) do={
                :set BackupLine ($BackupLine . "\0ARemoved: <code>" . $Removed . " older file(s)</code>")
            }
        }
    }

    :log info ("backup_update_check: $InstalledVersion -> $LatestVersion on channel $Channel")
    :local MessageText ("<b>" . $DeviceName . ":</b> RouterOS update is required." . \
    "\0A\0A<b>Update info</b>" . \
    "\0AChannel: <code>" . $Channel . "</code>" . \
    "\0AInstalled: <code>" . $InstalledVersion . "</code>" . \
    "\0ALatest: <code>" . $LatestVersion . "</code>" . \
    $FirmwareLine . \
    $BackupLine . \
    "\0A\0A<b>Device info</b>" . \
    "\0ABoard: <code>" . $BoardName . "</code>" . \
    "\0AArchitecture: <code>" . $Architecture . "</code>" . \
    "\0AUptime: <code>" . $Uptime . "</code>" . \
    "\0A\0A<b>Resources</b>" . \
    "\0ACPU load: <code>" . $CpuLoad . "%</code>" . \
    "\0AFree memory: <code>" . $FreeMemory . " MiB</code> / <code>" . $TotalMemory . " MiB</code>" . \
    "\0AFree storage: <code>" . $FreeHdd . " MiB</code> / <code>" . $TotalHdd . " MiB</code>")

    :do {
        $SendTelegramMessage MessageText=$MessageText
    } on-error={
        :log error "backup_update_check: could not send the update notification"
    }

} else={

    :log info ("backup_update_check: nothing to install ($InstalledVersion, latest $LatestVersion) on channel $Channel")
    # The daily one. Shorter on purpose: it is a heartbeat, and what it has to
    # answer is "is anything pending" and "is there room" - not repeat the
    # board and architecture every morning.
    :local MessageText ("<b>" . $DeviceName . ":</b> RouterOS update is not required." . \
    "\0A\0AChannel: <code>" . $Channel . "</code>" . \
    "\0AInstalled: <code>" . $InstalledVersion . "</code>" . \
    "\0ALatest: <code>" . $LatestVersion . "</code>" . \
    $FirmwareLine . \
    "\0AUptime: <code>" . $Uptime . "</code>" . \
    "\0AFree storage: <code>" . $FreeHdd . " MiB</code> / <code>" . $TotalHdd . " MiB</code>")

    :do {
        $SendTelegramMessage MessageText=$MessageText
    } on-error={
        :log error "backup_update_check: could not send the status message"
    }
}

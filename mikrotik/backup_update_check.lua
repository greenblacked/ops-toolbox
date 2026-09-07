# Update check with a pre-upgrade backup, in the plain style: a fixed wait, a
# message on every run, and when an update is available a
# backup-<identity>-<date>-<installed version>-pre-upgrade .backup/.rsc pair
# taken first, older backup-* files pruned only after the new pair is written.
# The sibling update_check.lua is the more careful design; this one exists
# because it runs where that one does not.
#
# Three outcomes, three messages. "Update is required" carries the backup, the
# firmware state, the package list and the resources an upgrade depends on.
# "Not required" is the daily heartbeat. "Check FAILED" is the one the plain
# design used to hide: a router that cannot reach the upgrade server has no
# latest version to compare, and reporting that as "not required" every
# morning is how a fleet quietly stops being checked. RouterOS's own status
# line - "ERROR: could not resolve dns name", "New version is available",
# "System is already up to date" - is in every message, because it is the one
# field that says what the check actually did.
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

# Free storage floor in MiB. RouterOS downloads the package to storage before
# it installs, so a router under this floor fails the download, not the check.
# The message says so next to the figure instead of leaving it to be noticed.
# 16 MiB is the same floor stay_fresh.lua refuses to install under.
:local MinFreeStorageMiB 16

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

# Read once, before anything slow: the same date names the backup file and
# stamps the message, so the two cannot disagree across midnight.
:local rawDate [/system clock get date]
:local Time [/system clock get time]

:if ([:len $updChannel] > 0) do={
    /system package update set channel=$updChannel
}
:local Channel "unknown"
:do { :set Channel [/system package update get channel]; } on-error={}

/system package update check-for-updates

:delay 15s

:local InstalledVersion "unknown"
:local LatestVersion "unknown"
:local Status "unknown"

:do { :set InstalledVersion [/system package update get installed-version]; } on-error={}

:do { :set LatestVersion [/system package update get latest-version]; } on-error={}

# RouterOS's own verdict on the check it just ran. This is the field that
# distinguishes "nothing newer" from "could not ask", and it names the cause
# when the check failed.
:do { :set Status [/system package update get status]; } on-error={}

# The check succeeded when RouterOS filled in latest-version. An empty or
# unknown value means it did not, and installed != latest would be true on
# that failure too - which must not take a backup, prune the previous one,
# or claim the router is current.
:local CheckOk (($LatestVersion != "unknown") and ([:len $LatestVersion] > 0))

:local BoardName "unknown"
:local Architecture "unknown"
:local Uptime "unknown"
:local CpuLoad "unknown"
:local FreeMemory "unknown"
:local TotalMemory "unknown"
:local FreeHdd "unknown"
:local TotalHdd "unknown"
:local BadBlocks "unknown"

:do { :set BoardName [/system resource get board-name]; } on-error={}

:do { :set Architecture [/system resource get architecture-name]; } on-error={}

:do { :set Uptime [/system resource get uptime]; } on-error={}

:do { :set CpuLoad [/system resource get cpu-load]; } on-error={}

# In MiB: the raw byte counts are unreadable, and free storage is the figure
# that decides whether an upgrade can proceed at all.
:do { :set FreeMemory ([/system resource get free-memory] / 1048576); } on-error={}

:do { :set TotalMemory ([/system resource get total-memory] / 1048576); } on-error={}

:do { :set FreeHdd ([/system resource get free-hdd-space] / 1048576); } on-error={}

:do { :set TotalHdd ([/system resource get total-hdd-space] / 1048576); } on-error={}

# Flash wear, as the percentage RouterOS reports. An upgrade is a large write
# to that flash, so a non-zero figure is worth seeing before one.
:do { :set BadBlocks [/system resource get bad-blocks]; } on-error={}

# The storage line carries its own warning, so the number and what it means
# arrive together in every message that shows it.
:local StorageLine ("\0AFree storage: <code>" . $FreeHdd . " MiB</code> / <code>" . $TotalHdd . " MiB</code>")
:if (([:typeof $FreeHdd] = "num") and ($FreeHdd < $MinFreeStorageMiB)) do={
    :set StorageLine ($StorageLine . "\0A<b>Low storage:</b> under " . $MinFreeStorageMiB . " MiB - the package download will likely fail; free space before upgrading")
}

:local BadBlocksLine ""
:if (([:typeof $BadBlocks] = "num") and ($BadBlocks > 0)) do={
    :set BadBlocksLine ("\0A<b>Bad blocks:</b> <code>" . $BadBlocks . " percent</code> - flash is wearing; keep the backup off the router before upgrading")
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
} on-error={}

# Temperature, voltage and whatever else the board reports. CHR and most x86
# report nothing, and the line is omitted there. A reading that will not
# resolve is skipped on its own rather than taking the others with it.
:local HealthLine ""
:do {
    :local Health ""
    :foreach h in=[/system health find] do={
        :do {
            :local hn [/system health get $h name]
            :local hv [/system health get $h value]
            :local ht ""
            :do { :set ht [/system health get $h type]; } on-error={}
            :if ([:len $Health] > 0) do={ :set Health ($Health . ", ") }
            :set Health ($Health . $hn . "=" . $hv . $ht)
        } on-error={}
    }
    :if ([:len $Health] > 0) do={ :set HealthLine ("\0AHealth: <code>" . $Health . "</code>") }
} on-error={}

# Enabled packages with their versions: what the upgrade will replace, and
# where a package that lags the rest - one installed by hand, or one the last
# upgrade skipped - shows up before the next one is attempted.
:local PackagesLine ""
:do {
    :local Packages ""
    :foreach p in=[/system package find] do={
        :do {
            :local pd false
            :do { :set pd [/system package get $p disabled]; } on-error={}
            :if (!$pd) do={
                :local pn [/system package get $p name]
                :local pv [/system package get $p version]
                :if ([:len $Packages] > 0) do={ :set Packages ($Packages . ", ") }
                :set Packages ($Packages . $pn . " " . $pv)
            }
        } on-error={}
    }
    :if ([:len $Packages] > 0) do={ :set PackagesLine ("\0APackages: <code>" . $Packages . "</code>") }
} on-error={}

:local CheckedLine ("\0AChecked: <code>" . $rawDate . " " . $Time . "</code>")

# Resolved once, wrapped: a missing helper must not kill the run before the
# backup below, and the router log has to say what went wrong.
:local SendTelegramMessage ""
:do {
    :set SendTelegramMessage [:parse [/system script get $TgSendScript source]]
} on-error={
    :log error ("backup_update_check: Telegram helper '" . $TgSendScript . "' not found - messages will not be sent")
}

:if (!$CheckOk) do={

    # --- the check itself failed ---------------------------------------------
    # No backup, no prune, and not "not required": say what RouterOS said.
    :log warning ("backup_update_check: update check failed on channel $Channel - status: $Status")
    :local MessageText ("<b>" . $DeviceName . ":</b> RouterOS update check FAILED." . \
    "\0A\0AStatus: <code>" . $Status . "</code>" . \
    "\0AChannel: <code>" . $Channel . "</code>" . \
    "\0AInstalled: <code>" . $InstalledVersion . "</code>" . \
    $CheckedLine . \
    "\0A\0AThe router could not get a latest version from the upgrade server. Check DNS and outbound HTTPS from the router, then run the check by hand: <code>/system package update check-for-updates</code>")

    :do {
        $SendTelegramMessage MessageText=$MessageText
    } on-error={
        :log error "backup_update_check: could not send the failed-check notification"
    }

} else={
:if ($InstalledVersion != $LatestVersion) do={

    # --- pre-upgrade backup ---------------------------------------------------
    :local BackupLine ""
    :if ($TakeBackup) do={
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
    "\0AStatus: <code>" . $Status . "</code>" . \
    $FirmwareLine . \
    $BackupLine . \
    "\0AChangelog: https://mikrotik.com/download/changelogs" . \
    "\0A\0A<b>Device info</b>" . \
    "\0ABoard: <code>" . $BoardName . "</code>" . \
    "\0AArchitecture: <code>" . $Architecture . "</code>" . \
    "\0AUptime: <code>" . $Uptime . "</code>" . \
    $HealthLine . \
    $PackagesLine . \
    "\0A\0A<b>Resources</b>" . \
    "\0ACPU load: <code>" . $CpuLoad . " percent</code>" . \
    "\0AFree memory: <code>" . $FreeMemory . " MiB</code> / <code>" . $TotalMemory . " MiB</code>" . \
    $StorageLine . \
    $BadBlocksLine . \
    $CheckedLine)

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
    "\0AStatus: <code>" . $Status . "</code>" . \
    $FirmwareLine . \
    "\0AUptime: <code>" . $Uptime . "</code>" . \
    $StorageLine . \
    $BadBlocksLine . \
    $CheckedLine)

    :do {
        $SendTelegramMessage MessageText=$MessageText
    } on-error={
        :log error "backup_update_check: could not send the status message"
    }
}
}

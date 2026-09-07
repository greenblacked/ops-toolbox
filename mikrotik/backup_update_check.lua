# Update check with a pre-upgrade backup, in the plain style: a message on
# every run, and when an update is offered a
# backup-<identity>-<date>-<installed version>-pre-upgrade .backup/.rsc pair
# taken first, older backup-* files pruned only after the new pair is written.
# The sibling update_check.lua is the more careful design; this one exists
# because it runs where that one does not.
#
# Three outcomes, three messages. "Update is required" carries the backup, the
# firmware state, the package list and the resources an upgrade depends on.
# "Not required" is the daily heartbeat. "Check FAILED" is the one the plain
# design used to hide. It used to wait a fixed 15 seconds and compare
# installed-version with latest-version. Measured on a 7.24.2 CHR: issuing the
# check clears latest-version at once, a good check refills it in about a
# second, and a failed check leaves it empty with an ERROR line in status. The
# old comparison sent that empty field down the "not required" branch, so a
# router whose DNS or outbound HTTPS broke reported "update is not required"
# with a blank Latest every morning - the outcome that looks like up to date
# and means the opposite. So the verdict is RouterOS's own status line, read
# until it settles: "finding out latest version..." while the check runs, then
# "System is already up to date", "New version is available", or an ERROR that
# names the cause - on the CHR with the update hosts unreachable, "ERROR: IPv4:
# server is not responding / IPv6: no internet connection". That line is in
# every message, because it is the one field that says what the check did.
#
# No :global here carries an underscore in its name, and that is the point.
# RouterOS 7.24 refuses to execute a script that declares one - "expected end
# of command" at the underscore, from the scheduler, from :parse and from
# /system script run alike - and it was seen on hardware, not only on the CHR
# the suite boots. update_check.lua declares six. The suite runs this script
# end to end on the 7.24.2 CHR (test_backup_update_check_runs_end_to_end), and
# the hand run on a 7.24.1 CHR that first proved the backup and the prune
# against a real newer release is recorded in the CHANGELOG.

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

# How long to wait for the check's verdict: attempts of 5 seconds each, after
# a 5 second settle. Twelve is a minute, which is generous - the CHR settles in
# about two seconds - and bounded, so a router that never hears back still
# sends its message. Not a :global on purpose; the plain design has no knobs
# outside this file.
:local MaxWait 12

# Free storage floor in MiB, 0 to disable the warning. The message always shows
# free storage next to the size of the installed packages, which is roughly
# what the upgrade has to download; below the floor it adds a warning. 16 MiB
# is the floor stay_fresh.lua refuses to install under, and it suits routers
# with 128 MiB of flash or more. A 16 MB flash router normally sits at 2 to
# 4 MiB free and upgrades anyway - RouterOS stages the download differently
# there - so on those set the floor to 0, or the heartbeat warns every day.
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
# The message is Telegram HTML, and Telegram rejects the whole message on one
# unbalanced '<'. Anything that did not originate in this script - the status
# line, a log entry, the identity - goes through this first. A bare percent
# sign is a truncated escape to a helper that posts form-encoded text, so it
# is spelled out too.
:local HtmlEscape do={
    :local out ""
    :if ([:len $1] > 0) do={
        :for i from=0 to=([:len $1] - 1) do={
            :local ch [:pick $1 $i ($i + 1)]
            :if ($ch = "&") do={ :set ch "&amp;" }
            :if ($ch = "<") do={ :set ch "&lt;" }
            :if ($ch = ">") do={ :set ch "&gt;" }
            :if ($ch = "%") do={ :set ch " pct" }
            :set out ($out . $ch)
        }
    }
    :return $out
}

:local DeviceName [/system identity get name]
:local DeviceLabel [$HtmlEscape $DeviceName]

# Read once, before anything slow: the same date names the backup file and
# stamps the message, so the two cannot disagree across midnight.
:local rawDate [/system clock get date]
:local Time [/system clock get time]

:if ([:len $updChannel] > 0) do={
    /system package update set channel=$updChannel
}
:local Channel "unknown"
:do { :set Channel [/system package update get channel]; } on-error={}

# `once` returns at once - 0.1s measured - and the check runs behind it.
/system package update check-for-updates once

# Wait for the verdict, not for a fixed time. status is the field that moves:
# it may hold the previous verdict for a moment, reads "finding out latest
# version..." while the check runs, and settles on "System is already up to
# date", "New version is available", or an ERROR line. latest-version is not
# a signal on its own: on 7.24.2 it is cleared the instant the check is issued
# and stays empty when the check fails, so it is empty both mid-check and
# after a failure, and only status tells the two apart.
:delay 5s

:local Settled false
:local Errored false
:local Attempt 0
:local Status ""
:while ((!$Settled) and ($Attempt < $MaxWait)) do={
    :do { :set Status [/system package update get status]; } on-error={}
    :if (([:typeof [:find $Status "ERROR"]] != "nil") \
      or ([:typeof [:find $Status "error"]] != "nil")) do={
        :set Errored true
        :set Settled true
    } else={
        :if (([:typeof [:find $Status "New version is available"]] != "nil") \
          or ([:typeof [:find $Status "up to date"]] != "nil")) do={
            :set Settled true
        } else={
            :delay 5s
            :set Attempt ($Attempt + 1)
        }
    }
}

:local InstalledVersion "unknown"
:local LatestVersion "unknown"

:do { :set InstalledVersion [/system package update get installed-version]; } on-error={}

:do { :set LatestVersion [/system package update get latest-version]; } on-error={}

# The check is good when it settled on a verdict that is not an error and
# RouterOS reported a version. Anything else is the failed-check outcome, and
# the most specific reason wins. A failed check must not take a backup, prune
# the previous one, or claim the router is current.
:local Reason ""
:if (!$Settled) do={ :set Reason "timed out waiting for a verdict" }
:if ([:len $LatestVersion] = 0) do={ :set Reason "no latest-version reported" }
:if ($Errored) do={ :set Reason "the update server reported an error" }
:local CheckOk ([:len $Reason] = 0)
:local UpdateOffered ([:typeof [:find $Status "New version is available"]] != "nil")
:local StatusText [$HtmlEscape $Status]

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

# Installed packages with their versions: what the upgrade will replace, and
# where a package that lags the rest - one installed by hand, or one the last
# upgrade skipped - shows up before the next one is attempted. On 7.13 and
# later the list also carries packages that are merely available to install,
# with an empty version; those are not installed and are left out. A disabled
# package is installed and is upgraded with the rest, so it stays, marked.
# The sizes add up to roughly what the upgrade has to download.
:local PackagesLine ""
:local PkgMiB 0
:do {
    :local Packages ""
    :foreach p in=[/system package find] do={
        :do {
            :local pv [/system package get $p version]
            :if ([:len $pv] > 0) do={
                :local pn [/system package get $p name]
                :local pd false
                :do { :set pd [/system package get $p disabled]; } on-error={}
                :do { :set PkgMiB ($PkgMiB + ([/system package get $p size] / 1048576)); } on-error={}
                :if ([:len $Packages] > 0) do={ :set Packages ($Packages . ", ") }
                :set Packages ($Packages . $pn . " " . $pv)
                :if ($pd) do={ :set Packages ($Packages . " (disabled)") }
            }
        } on-error={}
    }
    :if ([:len $Packages] > 0) do={ :set PackagesLine ("\0APackages: <code>" . $Packages . "</code>") }
} on-error={}

# The storage line carries its own context and warning, so the number, what
# the upgrade needs and what it means arrive together.
:local StorageLine ("\0AFree storage: <code>" . $FreeHdd . " MiB</code> / <code>" . $TotalHdd . " MiB</code>")
:if ($PkgMiB > 0) do={
    :set StorageLine ($StorageLine . " (installed packages <code>" . $PkgMiB . " MiB</code>)")
}
:if (([:typeof $FreeHdd] = "num") and ($MinFreeStorageMiB > 0) and ($FreeHdd < $MinFreeStorageMiB)) do={
    :set StorageLine ($StorageLine . "\0A<b>Low storage:</b> under the " . $MinFreeStorageMiB . " MiB floor - check there is room for the download before upgrading, or lower MinFreeStorageMiB if this router always runs this close")
}

:local BadBlocksLine ""
:if (([:typeof $BadBlocks] = "num") and ($BadBlocks > 0)) do={
    :set BadBlocksLine ("\0A<b>Bad blocks:</b> <code>" . $BadBlocks . " percent</code> - flash is wearing; keep the backup off the router before upgrading")
}

:local LicenseLine ""
:do { :set LicenseLine ("\0ALicense: <code>" . [/system license get level] . "</code>"); } on-error={}

# --- what the reboot would interrupt -----------------------------------------
# The upgrade ends in a reboot. These say who is on the router right now, so
# the operator picks the moment rather than discovering the answer from the
# complaints. Each is wrapped on its own: a router without the wireguard or
# ppp feature errors on the find, and that drops the one line.
:local ImpactLine ""
:do {
    :local IfTotal [:len [/interface find]]
    :local IfRunning [:len [/interface find where running=yes]]
    :set ImpactLine ($ImpactLine . "\0AInterfaces running: <code>" . $IfRunning . " of " . $IfTotal . "</code>")
} on-error={}
:do {
    :local Leases [:len [/ip dhcp-server lease find where status="bound"]]
    :set ImpactLine ($ImpactLine . "\0ADHCP leases bound: <code>" . $Leases . "</code>")
} on-error={}
:do {
    :local Ppp [:len [/ppp active find]]
    :set ImpactLine ($ImpactLine . "\0APPP sessions active: <code>" . $Ppp . "</code>")
} on-error={}
:do {
    :local WgPeers [:len [/interface wireguard peers find]]
    :set ImpactLine ($ImpactLine . "\0AWireGuard peers: <code>" . $WgPeers . "</code>")
} on-error={}

# --- what says the router is not well ----------------------------------------
# A supout file is a crash dump RouterOS wrote after a kernel failure, and a
# critical log entry is the router's own alarm. Both are worth knowing before
# an upgrade rides on top of them, and both are silent when there are none.
:local RiskLine ""
:do {
    :local Crashes [:len [/file find where name~"supout"]]
    :if ($Crashes > 0) do={
        :set RiskLine ($RiskLine . "\0A<b>Crash dumps:</b> <code>" . $Crashes . " supout file(s)</code> on the router - a kernel failure preceded this check")
    }
} on-error={}
:do {
    :local Critical [/log find where topics~"critical"]
    :local Count [:len $Critical]
    :if ($Count > 0) do={
        :local LastMsg [/log get ($Critical->($Count - 1)) message]
        :if ([:len $LastMsg] > 120) do={ :set LastMsg ([:pick $LastMsg 0 120] . "...") }
        :set RiskLine ($RiskLine . "\0A<b>Critical log entries:</b> <code>" . $Count . "</code> in the buffer, last: <code>" . [$HtmlEscape $LastMsg] . "</code>")
    }
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
    # No backup, no prune, and not "not required": say what RouterOS said, and
    # the three things the check depends on. The CHR reports mode=https with
    # check-certificate=yes, so a clock far enough off breaks the TLS handshake
    # - hence the NTP state - and the DNS servers are where "could not resolve"
    # is answered.
    :local UpdateMode "unknown"
    :do { :set UpdateMode [/system package update get mode]; } on-error={}
    :local NtpLine ""
    :do {
        :local NtpEnabled [/system ntp client get enabled]
        :local NtpStatus [/system ntp client get status]
        :set NtpLine ("\0ANTP client: <code>enabled=" . $NtpEnabled . " status=" . $NtpStatus . "</code>")
    } on-error={}
    :local DnsLine ""
    :do {
        :local DnsStatic [/ip dns get servers]
        :local DnsDynamic [/ip dns get dynamic-servers]
        :set DnsLine ("\0ADNS servers: <code>" . $DnsStatic . "</code> dynamic: <code>" . $DnsDynamic . "</code>")
    } on-error={}

    # A failed check leaves latest-version empty on 7.24.2; say so rather than
    # print an empty field.
    :local LatestText $LatestVersion
    :if ([:len $LatestText] = 0) do={ :set LatestText "none - cleared by the failed check" }

    :log warning ("backup_update_check: update check failed on channel $Channel - $Reason (status: $Status)")
    :local MessageText ("<b>" . $DeviceLabel . ":</b> RouterOS update check FAILED." . \
    "\0A\0AReason: <code>" . $Reason . "</code>" . \
    "\0AStatus: <code>" . $StatusText . "</code>" . \
    "\0AChannel: <code>" . $Channel . "</code> mode: <code>" . $UpdateMode . "</code>" . \
    "\0AInstalled: <code>" . $InstalledVersion . "</code>" . \
    "\0ALatest: <code>" . $LatestText . "</code>" . \
    $NtpLine . \
    $DnsLine . \
    $CheckedLine . \
    "\0A\0ANothing was backed up or pruned. Check DNS, the clock and outbound HTTPS from the router, then run the check by hand: <code>/system package update check-for-updates once</code>")

    :do {
        $SendTelegramMessage MessageText=$MessageText
    } on-error={
        :log error "backup_update_check: could not send the failed-check notification"
    }

} else={
# The verdict decides. Differing versions without "New version is available"
# is the channel-switch case - a router moved to a train whose current release
# is older than what it runs - and that is a log line, never a backup and a
# prune.
:if ($UpdateOffered) do={

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
    :local MessageText ("<b>" . $DeviceLabel . ":</b> RouterOS update is required." . \
    "\0A\0A<b>Update info</b>" . \
    "\0AChannel: <code>" . $Channel . "</code>" . \
    "\0AInstalled: <code>" . $InstalledVersion . "</code>" . \
    "\0ALatest: <code>" . $LatestVersion . "</code>" . \
    "\0AStatus: <code>" . $StatusText . "</code>" . \
    $FirmwareLine . \
    $BackupLine . \
    "\0AChangelog: https://mikrotik.com/download/changelogs" . \
    "\0A\0A<b>Device info</b>" . \
    "\0ABoard: <code>" . $BoardName . "</code>" . \
    "\0AArchitecture: <code>" . $Architecture . "</code>" . \
    $LicenseLine . \
    "\0AUptime: <code>" . $Uptime . "</code>" . \
    $HealthLine . \
    $PackagesLine . \
    "\0A\0A<b>Resources</b>" . \
    "\0ACPU load: <code>" . $CpuLoad . " percent</code>" . \
    "\0AFree memory: <code>" . $FreeMemory . " MiB</code> / <code>" . $TotalMemory . " MiB</code>" . \
    $StorageLine . \
    $BadBlocksLine . \
    "\0A\0A<b>Reboot impact</b>" . \
    $ImpactLine . \
    $RiskLine . \
    $CheckedLine)

    :do {
        $SendTelegramMessage MessageText=$MessageText
    } on-error={
        :log error "backup_update_check: could not send the update notification"
    }

} else={

    :if ($InstalledVersion != $LatestVersion) do={
        :log info ("backup_update_check: $InstalledVersion vs $LatestVersion on channel $Channel - no upgrade offered ($Status)")
    } else={
        :log info ("backup_update_check: nothing to install ($InstalledVersion, latest $LatestVersion) on channel $Channel")
    }
    # The daily one. Shorter on purpose: it is a heartbeat, and what it has to
    # answer is "is anything pending" and "is there room" - not repeat the
    # board and architecture every morning.
    :local MessageText ("<b>" . $DeviceLabel . ":</b> RouterOS update is not required." . \
    "\0A\0AChannel: <code>" . $Channel . "</code>" . \
    "\0AInstalled: <code>" . $InstalledVersion . "</code>" . \
    "\0ALatest: <code>" . $LatestVersion . "</code>" . \
    "\0AStatus: <code>" . $StatusText . "</code>" . \
    $FirmwareLine . \
    "\0AUptime: <code>" . $Uptime . "</code>" . \
    $StorageLine . \
    $BadBlocksLine . \
    $RiskLine . \
    $CheckedLine)

    :do {
        $SendTelegramMessage MessageText=$MessageText
    } on-error={
        :log error "backup_update_check: could not send the status message"
    }
}
}

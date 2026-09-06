# Keep a RouterOS device up to date, unattended: check the update server, and
# when RouterOS itself says a newer release is available on the channel, take a
# backup-<identity>-<date>-<installed version>-pre-upgrade .backup/.rsc pair,
# prune the older backup-* generations, install the release and let the router
# reboot. On the run after that, when the RouterBOARD firmware is behind the
# RouterOS it now runs, upgrade the firmware and reboot once more. Every run
# ends in a Telegram message saying what it did or why it did nothing.
#
# This is the RouterOS counterpart of the macOS and Linux stay_fresh.sh: the
# update check scripts beside it (update_check.lua, backup_update_check.lua)
# tell you an upgrade is waiting and leave the install to you. This one does
# the install. Run one of the three per router, not several, or the router
# reports every update more than once.
#
# What stops it from rebooting a router it should not:
#   - a maintenance window (WindowStart..WindowEnd, local hours): outside it
#     the run checks, reports "deferred", and changes nothing;
#   - the verdict is RouterOS's own status text, never installed != latest,
#     so a channel switch that makes latest *older* never installs anything;
#   - a check that errors or never completes installs nothing and says so;
#   - the install is refused when the pre-upgrade backup did not get written,
#     because an upgrade with nothing to roll back to is the one to skip;
#   - a free-storage floor, because a package download onto a full flash
#     fails halfway and the router is the thing that notices;
#   - no resolvable Telegram helper means no install and no reboot, because a
#     router that reboots without saying so is the failure this exists to avoid;
#   - StayFreshDryRun true does the check and the report and nothing else.
#
# No :global here carries an underscore in its name. RouterOS 7.24 refuses to
# execute a script that declares one - "expected end of command" at the
# underscore, from the scheduler, from :parse and from /system script run
# alike (see backup_update_check.lua) - and the router this is for runs 7.24.
#
# Schedule: 1d, at a time inside the window (print_schedulers.sh puts it at
# 04:20:00, the slot update_check would have had).

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

# --- settings ----------------------------------------------------------------
# Every one can be overridden from a :global set at boot, so a fleet is tuned
# from one startup script and the tracked file is never edited per router:
#
#     /system script add name=startup source={
#         :global StayFreshDryRun false;
#         :global StayFreshWindowStart 3;
#         :global StayFreshWindowEnd 6;
#         :global RouterBackupPassword "s3cret";
#     }
#     /system scheduler add name=startup on-event=startup start-time=startup

# Check and report only: no backup, no prune, no install, no reboot. Run the
# first scheduled tick with this on and read the message before letting it
# act. A :global at boot keeps a whole fleet in report-only mode.
:local DryRun false;
:global StayFreshDryRun;
:if ([:typeof $StayFreshDryRun] = "bool") do={ :set DryRun $StayFreshDryRun; }

# Local hours, start inclusive, end exclusive. 3 and 6 means 03:00 to 05:59.
# Start greater than end wraps past midnight (22 and 4 is 22:00 to 03:59); the
# two equal means always. The scheduler already picks the time, but a
# scheduler entry created by hand at 19:40 with interval=1d runs at 19:40, and
# a manual "/system script run stay_fresh" at noon should not reboot the
# office either. The window is the floor under both.
:local WindowStart 3;
:local WindowEnd 6;
:global StayFreshWindowStart;
:global StayFreshWindowEnd;
:if ([:typeof $StayFreshWindowStart] = "num") do={ :set WindowStart $StayFreshWindowStart; }
:if ([:typeof $StayFreshWindowEnd] = "num") do={ :set WindowEnd $StayFreshWindowEnd; }

# Install the RouterOS release when one is offered. Off, this script is an
# update check with a backup - the same job as backup_update_check.lua.
:local InstallUpdates true;
:global StayFreshInstall;
:if ([:typeof $StayFreshInstall] = "bool") do={ :set InstallUpdates $StayFreshInstall; }

# Upgrade the RouterBOARD firmware when it is behind, and reboot to apply it.
# Only on a run where no RouterOS release is pending, so one run does one
# thing and the firmware step follows the RouterOS step a day later, which is
# the order MikroTik documents. Hardware with no RouterBOARD (CHR, x86) has no
# firmware and the step is skipped.
:local UpgradeFirmware true;
:global StayFreshFirmware;
:if ([:typeof $StayFreshFirmware] = "bool") do={ :set UpgradeFirmware $StayFreshFirmware; }

# Refuse to install without a freshly written pre-upgrade backup. Off, a
# failed backup is reported and the install goes ahead anyway.
:local RequireBackup true;
:global StayFreshRequireBackup;
:if ([:typeof $StayFreshRequireBackup] = "bool") do={ :set RequireBackup $StayFreshRequireBackup; }

# Free storage the install needs to find, in MiB, checked before the download
# starts. A floor to tune rather than a RouterOS requirement: the package for
# an arm router is a few MiB and the download lands on flash before it is
# applied. 0 disables the check.
:local MinFreeStorageMiB 16;
:global StayFreshMinFreeMiB;
:if ([:typeof $StayFreshMinFreeMiB] = "num") do={ :set MinFreeStorageMiB $StayFreshMinFreeMiB; }

# Delete the older backup-* files once the new pre-upgrade pair is written,
# leaving one generation on the router. Same caveat as backup.lua: one
# generation means a corrupt backup is the only backup, so pull the files off
# with pull_router_backups.sh and keep generations there.
:local RemovePrevious true;
:global StayFreshRemovePrevious;
:if ([:typeof $StayFreshRemovePrevious] = "bool") do={ :set RemovePrevious $StayFreshRemovePrevious; }

# How long to wait for the check to reach a verdict: 5s settle plus up to this
# many polls of 5s. 12 is about 65 seconds.
:local MaxWait 12;
:global StayFreshMaxWait;
:if ([:typeof $StayFreshMaxWait] = "num") do={ :set MaxWait $StayFreshMaxWait; }

# The Telegram helper. tg_send_new first - the operator's own copy, the one
# that runs on 7.24 - then the package's tg_send, so the same file works on a
# router that has either. Set the :global to name a different one.
:local TgSendScript "tg_send_new";
:global StayFreshTgSend;
:if ([:len $StayFreshTgSend] > 0) do={ :set TgSendScript $StayFreshTgSend; }

# Refuse to install or reboot when no Telegram helper could be resolved. A
# router that reboots without saying so is the failure this script exists to
# avoid; a router with no Telegram at all sets this false and reads /log.
:local RequireNotify true;
:global StayFreshRequireNotify;
:if ([:typeof $StayFreshRequireNotify] = "bool") do={ :set RequireNotify $StayFreshRequireNotify; }

# Optional password for the binary backup, the same :global
# backup_update_check.lua reads. Set it at boot; never in this file.
:local BackupPassword "";
:global RouterBackupPassword;
:if ([:len $RouterBackupPassword] > 0) do={ :set BackupPassword $RouterBackupPassword; }

# -----------------------------------------------------------------------------
:local rawName [/system identity get name];

# The message is HTML posted as a form body. An identity holding "&" ends the
# text field early and "<" opens a tag Telegram cannot close, so the three
# characters that matter are replaced before the name goes into a message.
# Replaced rather than entity-escaped, because an entity carries its own "&"
# and whether the helper encodes the body is the helper's business.
:local DeviceName "";
:for i from=0 to=([:len $rawName] - 1) do={
    :local ch [:pick $rawName $i ($i + 1)];
    :if (($ch = "&") or ($ch = "<") or ($ch = ">")) do={ :set ch "-"; }
    :set DeviceName ($DeviceName . $ch);
}

# Resolved once and wrapped: a missing helper must not kill the run before the
# check, and the log has to say which helper it looked for. The package's
# tg_send is the fallback for releases that run it; on 7.24 it fails to parse
# like every other underscored script, and this run then has no sender.
:local Send "";
:local HaveSend false;
:local UsingPackageSend false;
:do {
    :set Send [:parse [/system script get $TgSendScript source]];
    :set HaveSend true;
    :if ($TgSendScript = "tg_send") do={ :set UsingPackageSend true; }
} on-error={
    :do {
        :set Send [:parse [/system script get tg_send source]];
        :set HaveSend true;
        :set UsingPackageSend true;
        :log info ("stay_fresh: helper '" . $TgSendScript . "' not found, using tg_send");
    } on-error={
        :log error ("stay_fresh: no Telegram helper found ('" . $TgSendScript . "' or tg_send) - messages will not be sent");
    }
}

# The package's tg_send posts MessageText verbatim as a form-encoded body, so a
# line break has to travel as %0A there (update_check.lua does the same). The
# operator's helper takes a literal newline.
:local NL "\0A";
:if ($UsingPackageSend) do={ :set NL "%0A"; }

# Whether this run may install or reboot at all: with no sender and
# RequireNotify on, it still checks and logs, and does nothing else.
:local CanAct true;
:if ((!$HaveSend) and $RequireNotify) do={
    :set CanAct false;
    :log error "stay_fresh: no Telegram helper - install and reboot refused (StayFreshRequireNotify)";
}

# One place that sends, so every branch below logs and messages the same way.
:local Notify do={
    :global StayFreshSendRef;
    :if ([:typeof $StayFreshSendRef] != "nothing") do={
        :do {
            $StayFreshSendRef MessageText=$1;
        } on-error={
            :log warning "stay_fresh: could not send the Telegram message";
        }
    }
}
# A :local function cannot see the caller's locals, so the resolved helper is
# handed over through a global, set once here for the length of this run and
# overwritten by the next one. No underscore in the name, for the reason in
# the header.
:global StayFreshSendRef;
:if ($HaveSend) do={ :set StayFreshSendRef $Send; } else={ :set StayFreshSendRef; }

# --- the window ---------------------------------------------------------------
:local hour [:tonum [:pick [:tostr [/system clock get time]] 0 2]];
:local InWindow false;
:if ($WindowStart = $WindowEnd) do={
    :set InWindow true;
} else={
    :if ($WindowStart < $WindowEnd) do={
        :if (($hour >= $WindowStart) and ($hour < $WindowEnd)) do={ :set InWindow true; }
    } else={
        :if (($hour >= $WindowStart) or ($hour < $WindowEnd)) do={ :set InWindow true; }
    }
}

# --- the check ----------------------------------------------------------------
# Read, never written: a check script reports the channel, it does not decide
# which train a router sits on.
:local channel "unknown";
:do { :set channel [/system package update get channel]; } on-error={}

/system package update check-for-updates once;

# Wait for the check to finish rather than for a field to be non-empty:
# RouterOS keeps latest-version from the previous check, so it is populated
# the instant the command is issued. status is the field that moves, and it
# holds the previous verdict for a moment before "checking for updates...",
# hence the settle before the first read.
:delay 5s;

:local settled false;
:local errored false;
:local attempt 0;
:local status "";
:while ((!$settled) and ($attempt < $MaxWait)) do={
    :set status [/system package update get status];
    :if (([:typeof [:find $status "ERROR"]] != "nil") \
      or ([:typeof [:find $status "error"]] != "nil")) do={
        :set errored true;
        :set settled true;
    } else={
        :if (([:typeof [:find $status "New version is available"]] != "nil") \
          or ([:typeof [:find $status "up to date"]] != "nil")) do={
            :set settled true;
        } else={
            :delay 5s;
            :set attempt ($attempt + 1);
        }
    }
}

:local installed "unknown";
:local latest "unknown";
:do { :set installed [/system package update get installed-version]; } on-error={}
:do { :set latest [/system package update get latest-version]; } on-error={}

# In MiB: the raw byte count is unreadable, and free storage is the figure
# that decides whether the install can proceed.
:local FreeHdd 0;
:local TotalHdd 0;
:do {
    :set FreeHdd ([/system resource get free-hdd-space] / 1048576);
    :set TotalHdd ([/system resource get total-hdd-space] / 1048576);
} on-error={}
:local Uptime "unknown";
:do { :set Uptime [/system resource get uptime]; } on-error={}

# True when dotted version $1 is numerically newer than $2 ("7.24.1" > "7.9").
# A string compare ranks 7.9 above 7.10, and a plain != also fires when the
# running firmware is newer than the one bundled with this RouterOS - which is
# exactly the case that must not be "upgraded" down. Anything that does not
# parse as numbers compares as not newer, the safe direction.
:local VerNewer do={
    :local a $1; :local b $2;
    :while (([:len $a] > 0) or ([:len $b] > 0)) do={
        :local ai [:find $a "."]; :local bi [:find $b "."];
        :local ah $a; :local bh $b;
        :if ([:typeof $ai] != "nil") do={ :set ah [:pick $a 0 $ai]; :set a [:pick $a ($ai + 1) [:len $a]]; } else={ :set a ""; }
        :if ([:typeof $bi] != "nil") do={ :set bh [:pick $b 0 $bi]; :set b [:pick $b ($bi + 1) [:len $b]]; } else={ :set b ""; }
        :if ([:len $ah] = 0) do={ :set ah "0"; }
        :if ([:len $bh] = 0) do={ :set bh "0"; }
        :local an [:tonum $ah]; :local bn [:tonum $bh];
        :if (([:typeof $an] != "num") or ([:typeof $bn] != "num")) do={ :return false; }
        :if ($an > $bn) do={ :return true; }
        :if ($an < $bn) do={ :return false; }
    }
    :return false;
}

# RouterBOARD firmware, where there is a RouterBOARD. CHR and x86 have none
# and the line is simply omitted. "Behind" means the bundled firmware is
# newer than the running one, not merely different.
:local FwCurrent "";
:local FwUpgrade "";
:local FirmwareLine "";
:local FirmwareBehind false;
:do {
    :set FwCurrent [/system routerboard get current-firmware];
    :set FwUpgrade [/system routerboard get upgrade-firmware];
    :set FirmwareLine ($NL . "Firmware: <code>" . $FwCurrent . "</code>");
    :if ([$VerNewer $FwUpgrade $FwCurrent]) do={
        :set FirmwareBehind true;
        :set FirmwareLine ($FirmwareLine . " -> <code>" . $FwUpgrade . "</code> (upgrade available)");
    } else={
        :if (($FwCurrent != $FwUpgrade) and ([:len $FwUpgrade] > 0)) do={
            :set FirmwareLine ($FirmwareLine . " (bundled: <code>" . $FwUpgrade . "</code>, not newer, kept)");
        }
    }
} on-error={}

:local Head ("<b>" . $DeviceName . ":</b> ");
:local Detail ($NL . $NL . "Channel: <code>" . $channel . "</code>" . \
               $NL . "Installed: <code>" . $installed . "</code>" . \
               $NL . "Latest: <code>" . $latest . "</code>" . \
               $NL . "Status: <code>" . $status . "</code>" . \
               $FirmwareLine . \
               $NL . "Uptime: <code>" . $Uptime . "</code>" . \
               $NL . "Free storage: <code>" . $FreeHdd . " MiB</code> / <code>" . $TotalHdd . " MiB</code>");
:local Mode "";
:if ($DryRun) do={ :set Mode $NL . $NL . "<i>dry run: nothing was changed</i>"; }

# --- a check that did not complete ---------------------------------------------
# Named as such rather than falling through: latest-version survives from the
# previous check, so a run that ended in "ERROR: could not resolve" still has
# last week's version in the field and would otherwise read as "nothing to
# install" - the outcome that looks like up to date and means the opposite.
:local why "";
:if (!$settled) do={ :set why "timed out waiting for a verdict"; }
:if ([:len $latest] = 0) do={ :set why "no latest-version reported"; }
:if ($errored) do={ :set why "the update server reported an error"; }

:if ([:len $why] > 0) do={
    :log warning ("stay_fresh: check did not complete - $why (status: $status)");
    $Notify ("\E2\9A\A0\EF\B8\8F " . $Head . "RouterOS update check FAILED, nothing installed." . \
             $NL . "Reason: <code>" . $why . "</code>" . $Detail . $Mode);
    :return "";
}

# --- a RouterOS release is offered -----------------------------------------------
:if ([:typeof [:find $status "New version is available"]] != "nil") do={
    :log info ("stay_fresh: $installed -> $latest offered on channel $channel");

    :if (!$InstallUpdates) do={
        $Notify ("\F0\9F\9A\80 " . $Head . "RouterOS update available, install is off (StayFreshInstall)." . $Detail . $Mode);
        :return "";
    }
    :if (!$InWindow) do={
        :log info ("stay_fresh: outside the maintenance window (hour $hour, window $WindowStart-$WindowEnd) - deferred");
        $Notify ("\F0\9F\9A\80 " . $Head . "RouterOS update available, deferred to the maintenance window " . \
                 "(<code>" . $WindowStart . "</code>-<code>" . $WindowEnd . "</code> local)." . $Detail . $Mode);
        :return "";
    }
    :if (!$CanAct) do={
        :log error ("stay_fresh: RouterOS $latest offered but no Telegram helper - not installing");
        :return "";
    }
    :if ($DryRun) do={
        $Notify ("\F0\9F\9A\80 " . $Head . "RouterOS update available - would back up, prune and install " . \
                 "<code>" . $latest . "</code>, then reboot." . $Detail . $Mode);
        :return "";
    }
    :if (($MinFreeStorageMiB > 0) and ($FreeHdd < $MinFreeStorageMiB)) do={
        :log error ("stay_fresh: only $FreeHdd MiB free, floor is $MinFreeStorageMiB MiB - not installing");
        $Notify ("\E2\9A\A0\EF\B8\8F " . $Head . "RouterOS update available but NOT installed: " . \
                 "<code>" . $FreeHdd . " MiB</code> free is under the <code>" . $MinFreeStorageMiB . " MiB</code> floor. " . \
                 "Free space on the router first." . $Detail);
        :return "";
    }

    # --- pre-upgrade backup ------------------------------------------------------
    # Taken while the router still runs the version being replaced, which is
    # the version this file restores. The backup- prefix is what
    # pull_router_backups.sh collects and backup_file_cleanup.lua ages out.
    :local rawDate [/system clock get date];
    :local Date "";
    :for i from=0 to=([:len $rawDate] - 1) do={
        :local ch [:pick $rawDate $i ($i + 1)];
        :if ($ch = "/") do={ :set ch "-"; }
        :set Date ($Date . $ch);
    }
    :local BackupFile ("backup-" . $rawName . "-" . $Date . "-" . $installed . "-pre-upgrade");
    :local BackupLine "";
    :local BackupOk false;
    :do {
        :if ([:len $BackupPassword] > 0) do={
            /system backup save name=$BackupFile password=$BackupPassword;
        } else={
            /system backup save name=$BackupFile dont-encrypt=yes;
        }
        # The .rsc alongside the binary: a binary backup only restores onto
        # the same version, and the version is the thing about to change.
        /export file=$BackupFile;
        :set BackupOk true;
        :log info ("stay_fresh: pre-upgrade backup created: $BackupFile");
        :set BackupLine ($NL . "Backup: <code>" . $BackupFile . "</code>");
    } on-error={
        :log error ("stay_fresh: pre-upgrade backup FAILED on $rawName at $Date");
        :set BackupLine $NL . "Backup: <code>FAILED - nothing to roll back to</code>";
    }

    # Only after the new pair is written, so a failed save is never the run
    # that deletes the last good backup. Everything starting with the new base
    # name is kept, not just the two exact names: /export writes through a
    # .rsc.in_progress temporary and returns before it is finished, and an
    # exact-name test would delete that half-written export.
    :if ($BackupOk and $RemovePrevious) do={
        :local Keep [:len $BackupFile];
        :local Removed 0;
        :do {
            :foreach f in=[/file find where name~"^backup-"] do={
                :do {
                    :local nm [/file get $f name];
                    :if ([:pick $nm 0 $Keep] != $BackupFile) do={
                        /file remove $f;
                        :log info ("stay_fresh: removed previous backup $nm");
                        :set Removed ($Removed + 1);
                    }
                } on-error={
                    :log warning "stay_fresh: could not remove a previous backup file";
                }
            }
        } on-error={
            :log warning "stay_fresh: could not list files to prune previous backups";
        }
        :if ($Removed > 0) do={
            :set BackupLine ($BackupLine . $NL . "Removed: <code>" . $Removed . " older file(s)</code>");
        }
    }

    :if ((!$BackupOk) and $RequireBackup) do={
        :log error "stay_fresh: no pre-upgrade backup, install refused (StayFreshRequireBackup)";
        $Notify ("\E2\9A\A0\EF\B8\8F " . $Head . "RouterOS update available but NOT installed: the pre-upgrade backup failed " . \
                 "and there is nothing to roll back to." . $BackupLine . $Detail);
        :return "";
    }

    # --- install -------------------------------------------------------------------
    # Announced before it starts, because the install ends in a reboot and a
    # message sent after it never leaves the router. The delay lets the send
    # complete. The "back online" startup notifier (README, Reboot
    # notifications) reports the other side of the reboot.
    :log warning ("stay_fresh: installing RouterOS $latest and rebooting");
    $Notify ("\F0\9F\9A\80 " . $Head . "Installing RouterOS <code>" . $latest . "</code> and rebooting now." . \
             $BackupLine . $Detail);
    :delay 5s;
    :do {
        /system package update install;
    } on-error={
        :log error "stay_fresh: /system package update install failed";
        $Notify ("\E2\9A\A0\EF\B8\8F " . $Head . "RouterOS install FAILED: the router did not accept " . \
                 "<code>/system package update install</code>. Still on <code>" . $installed . "</code>.");
    }
    :return "";
}

# --- nothing to install: firmware, then the heartbeat ------------------------------
# Differing versions with no "new version available" verdict is the
# channel-switch case: worth a log line, never an install of an older release.
:if ($installed != $latest) do={
    :log info ("stay_fresh: $installed vs $latest on channel $channel - no upgrade offered ($status)");
} else={
    :log info ("stay_fresh: already on latest ($installed) on channel $channel");
}

:if ($FirmwareBehind and $UpgradeFirmware) do={
    :if (!$InWindow) do={
        :log info ("stay_fresh: firmware $FwCurrent -> $FwUpgrade waiting, outside the window - deferred");
        $Notify ("\F0\9F\94\A7 " . $Head . "RouterBOARD firmware upgrade waiting, deferred to the maintenance window." . $Detail . $Mode);
        :return "";
    }
    :if (!$CanAct) do={
        :log error ("stay_fresh: firmware $FwCurrent -> $FwUpgrade waiting but no Telegram helper - not rebooting");
        :return "";
    }
    :if ($DryRun) do={
        $Notify ("\F0\9F\94\A7 " . $Head . "Would upgrade RouterBOARD firmware to <code>" . $FwUpgrade . "</code> and reboot." . $Detail . $Mode);
        :return "";
    }
    :log warning ("stay_fresh: upgrading RouterBOARD firmware $FwCurrent -> $FwUpgrade and rebooting");
    :local FwOk false;
    :do {
        /system routerboard upgrade;
        :set FwOk true;
    } on-error={
        :log error "stay_fresh: /system routerboard upgrade failed";
    }
    :if ($FwOk) do={
        $Notify ("\F0\9F\94\A7 " . $Head . "Upgrading RouterBOARD firmware to <code>" . $FwUpgrade . "</code>, rebooting now to apply it." . $Detail);
        :delay 5s;
        /system reboot;
        :return "";
    }
    $Notify ("\E2\9A\A0\EF\B8\8F " . $Head . "RouterBOARD firmware upgrade FAILED, not rebooting." . $Detail);
    :return "";
}

# The daily heartbeat: a router that never speaks looks exactly like one whose
# scheduler quietly stopped, and for a script that reboots routers, "it ran
# and did nothing" is worth one short line a day.
$Notify ("\E2\9C\85 " . $Head . "RouterOS is fresh, nothing to install." . $Detail . $Mode);

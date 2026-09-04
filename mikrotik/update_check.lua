# Checks for RouterOS updates on the configured channel and sends a Telegram
# notification if a newer version is available, with the device and resource
# detail you want in front of you before deciding to upgrade. Does NOT install
# automatically, but does take a backup first when TakeBackup is on.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

# A pre-upgrade backup is the one worth having: it is a snapshot of a config
# the *running* version is known to accept, taken while the router still runs
# that version. Taking it here means it already exists by the time somebody
# reads the notification and starts the upgrade, instead of depending on them
# remembering - which is exactly the step that gets skipped at 23:00.
#
# backup.lua does the work and sends its own notification naming the file, so
# the version in that filename is the version you would be rolling back to.
:local TakeBackup true;
:global UPDATE_CHECK_BACKUP;
:if ([:typeof $UPDATE_CHECK_BACKUP] = "bool") do={ :set TakeBackup $UPDATE_CHECK_BACKUP; }

# A check that never completes is a router silently running an unpatched
# release, which is the failure this script exists to prevent - so it is worth
# a message rather than a log line nobody reads. It can only fire when the
# router still has a route to Telegram, which is the case that matters: DNS
# broken, the upgrade server refusing, a proxy in the way. A router that is
# fully offline cannot report anything, and no arrangement here changes that.
:local NotifyOnCheckFailure true;
:global UPDATE_CHECK_NOTIFY_FAILURE;
:if ([:typeof $UPDATE_CHECK_NOTIFY_FAILURE] = "bool") do={ :set NotifyOnCheckFailure $UPDATE_CHECK_NOTIFY_FAILURE; }

# 5s settle + up to 12 polls of 5s = 65s worst case.
:local MaxWait 12;

# tg_send posts the text as application/x-www-form-urlencoded and Telegram then
# parses it as HTML, so anything interpolated into the message has to survive
# both layers. A router identity is operator-supplied and can hold either
# hazard: "&" ends the text field early and silently truncates the rest of the
# message, "<" opens a tag Telegram cannot close and the send is rejected
# outright. Escaping for HTML and then percent-encoding the ampersand that
# escape introduces handles both in one pass. "%" is here for the same reason
# the CPU line below writes %25 - a bare percent is a malformed escape
# sequence in the body.
:local EscapeText do={
    :local out "";
    :for i from=0 to=([:len $1] - 1) do={
        :local ch [:pick $1 $i ($i + 1)];
        :local esc "";
        :if ($ch = "&") do={ :set esc "%26amp;" } else={
        :if ($ch = "<") do={ :set esc "%26lt;" } else={
        :if ($ch = ">") do={ :set esc "%26gt;" } else={
        :if ($ch = "%") do={ :set esc "%25" } else={ :set esc $ch }}}}
        :set out ($out . $esc);
    }
    :return $out;
}

:local rawName [/system identity get name];
:local DeviceName [$EscapeText $rawName];

# The channel is read, never written.
#
# Setting it here would be the script quietly overriding a deliberate choice:
# a router parked on long-term gets moved to stable on the next scheduler tick
# and is then correctly told an upgrade is available - to a release train
# somebody had specifically kept it off. A check script reports state; it does
# not decide policy.
:local channel "unknown";
:do { :set channel [/system package update get channel]; } on-error={}

/system package update check-for-updates once;

# Wait for the check to actually finish, rather than for a field to be
# non-empty.
#
# RouterOS keeps `latest-version` from the previous check, so on every run
# after the first it is already populated the instant the command is issued.
# Polling until it fills therefore exits immediately with last week's answer -
# a freshness guard that guarantees nothing. `status` is the field that
# actually moves, so poll that until it reaches a verdict.
#
# The 5s before the first read is the other half of the same problem: status
# holds the *previous* verdict until RouterOS replaces it with "checking for
# updates...", and reading in that window sees a terminal-looking value that
# is equally stale.
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

:local installed [/system package update get installed-version];
:local latest    [/system package update get latest-version];

# An errored check has to be named as one rather than fall through.
#
# `latest-version` survives from the previous check, so a run that ends in
# "ERROR: could not resolve..." still has last week's version sitting in the
# field. Left to the verdict test below, that reads as "no upgrade offered" and
# the router goes quiet - the one outcome that looks identical to being up to
# date while meaning the opposite. Each test overwrites the reason, so the most
# specific one wins.
:local why "";
:if (!$settled) do={ :set why "timed out waiting for a verdict"; }
:if ([:len $latest] = 0) do={ :set why "no latest-version reported"; }
:if ($errored) do={ :set why "the update server reported an error"; }

:if ([:len $why] > 0) do={
    :log warning ("update_check: check did not complete - $why (status: $status)");
    :if ($NotifyOnCheckFailure) do={
        :local FailText ("\E2\9A\A0\EF\B8\8F <b>" . $DeviceName . ":</b> RouterOS update check FAILED.%0A" . \
                         "<b>Reason:</b> <code>" . $why . "</code>%0A" . \
                         "<b>Status:</b> <code>" . $status . "</code>%0A" . \
                         "<b>Channel:</b> <code>" . $channel . "</code>%0A" . \
                         "<b>Installed:</b> <code>" . $installed . "</code>");
        :do {
            :local Send [:parse [/system script get tg_send source]];
            $Send MessageText=$FailText;
        } on-error={
            :log warning "update_check: could not send the check-failure notification (is tg_send installed?)";
        };
    }
    :return "";
}

# Gate on RouterOS's own verdict, not on the two strings differing.
#
# "$installed != $latest" only answers "are these different?", never "is latest
# newer?". Switch a router from the stable channel to long-term and latest
# becomes *older* than installed: the strings differ, so the old test fired and
# announced "update available: 7.23 -> 7.19.4". Acting on that downgrades
# across a major-minor boundary, which can invalidate configuration.
#
# Comparing versions properly is not an option here — RouterOS script has no
# tuple comparison, and a string compare ranks 7.9 above 7.10. The router has
# already done the comparison for us and reports it in `status`, so use that.
:if ([:typeof [:find $status "New version is available"]] != "nil") do={
    # Gathered only on the branch that sends, so the daily quiet run stays a
    # handful of reads. Every one is wrapped: /system routerboard does not
    # exist on CHR or x86, and a missing firmware line is better than a line
    # reading "unknown" that somebody has to go and disprove.
    :local FirmwareLine "";
    :do {
        :local FwCurrent [/system routerboard get current-firmware];
        :local FwUpgrade [/system routerboard get upgrade-firmware];
        :set FirmwareLine ("%0A<b>Firmware:</b> <code>" . $FwCurrent . "</code>");
        :if ($FwCurrent != $FwUpgrade) do={
            :set FirmwareLine ($FirmwareLine . " -> <code>" . $FwUpgrade . "</code> (upgrade available)");
        }
    } on-error={}

    :local DeviceLines "";
    :do {
        :set DeviceLines ("%0A%0A<b>Device</b>" . \
            "%0A<b>Board:</b> <code>" . [/system resource get board-name] . "</code>" . \
            "%0A<b>Architecture:</b> <code>" . [/system resource get architecture-name] . "</code>" . \
            "%0A<b>Uptime:</b> <code>" . [/system resource get uptime] . "</code>");
    } on-error={}

    # %25 rather than %, because the body is URL-encoded: a bare percent
    # followed by "<" is a malformed escape sequence, not a percent sign.
    :local ResourceLines "";
    :do {
        :local FreeMem  (([/system resource get free-memory] / 1048576));
        :local TotalMem (([/system resource get total-memory] / 1048576));
        :local FreeHdd  (([/system resource get free-hdd-space] / 1048576));
        :local TotalHdd (([/system resource get total-hdd-space] / 1048576));
        :set ResourceLines ("%0A%0A<b>Resources</b>" . \
            "%0A<b>CPU load:</b> <code>" . [/system resource get cpu-load] . "%25</code>" . \
            "%0A<b>Free memory:</b> <code>" . $FreeMem . " MiB</code> / <code>" . $TotalMem . " MiB</code>" . \
            "%0A<b>Free storage:</b> <code>" . $FreeHdd . " MiB</code> / <code>" . $TotalHdd . " MiB</code>");
    } on-error={}

    # Runs before the notification is sent so the message can report the
    # outcome. A failed backup is not a reason to stay quiet about the update -
    # it is a reason to say loudly that there is nothing to roll back to.
    :local BackupLine "";
    :if ($TakeBackup) do={
        :do {
            :local RunBackup [:parse [/system script get backup source]];
            $RunBackup;
            :set BackupLine "%0A<b>Backup:</b> <code>taken before upgrade</code>";
        } on-error={
            :log error "update_check: pre-upgrade backup failed (is the backup script installed?)";
            :set BackupLine "%0A<b>Backup:</b> <code>FAILED - nothing to roll back to</code>";
        }
    }

    :local MessageText ("\F0\9F\9A\80 <b>" . $DeviceName . ":</b> RouterOS update available.%0A" . \
                        "<b>Installed:</b> <code>" . $installed . "</code>%0A" . \
                        "<b>Latest:</b> <code>" . $latest . "</code>%0A" . \
                        "<b>Channel:</b> <code>" . $channel . "</code>%0A" . \
                        "<b>Status:</b> <code>" . $status . "</code>" . \
                        $FirmwareLine . $BackupLine . $DeviceLines . $ResourceLines);
    :log info ("update_check: $installed -> $latest");
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={
        :log warning "update_check: could not send notification (is tg_send installed?)";
    };
} else={
    # Differing versions with no "new version available" verdict is the
    # channel-switch case: worth a log line, never a notification telling
    # somebody to install an older release.
    :if ($installed != $latest) do={
        :log info ("update_check: $installed vs $latest on channel $channel - no upgrade offered ($status)");
    } else={
        :log info ("update_check: already on latest ($installed) on channel $channel");
    }
}

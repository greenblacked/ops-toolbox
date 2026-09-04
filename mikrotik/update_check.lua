# Checks for RouterOS updates on the configured channel and sends a Telegram
# notification if a newer version is available. Does NOT install automatically,
# but does take a backup first when TakeBackup is on.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];

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

/system package update check-for-updates once;
:delay 10s;

:local installed [/system package update get installed-version];
:local latest    [/system package update get latest-version];
:local status    [/system package update get status];

:if ([:len $latest] = 0) do={
    :log warning "update_check: latest-version unavailable (offline?)";
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
                        "<b>Status:</b> <code>" . $status . "</code>" . $BackupLine);
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
        :log info ("update_check: $installed vs $latest on this channel - no upgrade offered ($status)");
    } else={
        :log info ("update_check: already on latest ($installed)");
    }
}

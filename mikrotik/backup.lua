# Creates a binary backup (.backup) and a config export (.rsc), then sends a
# Telegram notification with the resulting filename. Requires the `tg_send`
# script in /system script.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];
:local rawDate    [/system clock get date];
:local Time       [/system clock get time];
:local Ver        [/system package update get installed-version];

# Sanitize the date so the filename never contains '/' (would create subdirs
# under non-iso date-format settings such as mdy).
:local Date "";
:local n [:len $rawDate];
:for i from=0 to=($n - 1) do={
    :local ch [:pick $rawDate $i ($i + 1)];
    :if ($ch = "/") do={ :set ch "-"; }
    :set Date ($Date . $ch);
}

:local Filename "backup-$DeviceName-$Date-$Ver";

# Optional password for the binary backup. Leave empty to disable encryption.
#
# Set it from a :global at boot rather than typing it here — this file is
# tracked, so a password written into it lands in the next commit. Same
# mechanism tg_send.lua and ddns_update.lua use:
#
#     /system script add name=startup source={:global BACKUP_PASSWORD "s3cret";}
#     /system scheduler add name=startup on-event=startup start-time=startup
:local BackupPassword "";
:global BACKUP_PASSWORD;
:if ([:len $BACKUP_PASSWORD] > 0) do={ :set BackupPassword $BACKUP_PASSWORD; }

:do {
    :if ([:len $BackupPassword] > 0) do={
        /system backup save name=$Filename password=$BackupPassword;
    } else={
        /system backup save name=$Filename dont-encrypt=yes;
    }
    /export file=$Filename;
    :log info ("Backup created on $DeviceName: $Filename");
} on-error={
    :log error ("Backup FAILED on $DeviceName at $Date $Time");
    :do {
        :local ErrText "\E2\9D\8C <b>$DeviceName:</b> backup FAILED at <code>$Date $Time</code>.";
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$ErrText;
    } on-error={
        # Without this the backup-failed alert can itself fail — no route
        # out, wrong token, tg_send not installed — and nothing anywhere
        # would record that the backup failed OR that the alert did.
        :log error "backup: could not send the failure notification (is tg_send installed?)";
    };
    :error "backup failed";
}

:local MessageText "\F0\9F\92\BE <b>$DeviceName:</b> backup created.%0A<b>File:</b> <code>$Filename</code>%0A<b>Version:</b> <code>$Ver</code>";
:do {
    :local Send [:parse [/system script get tg_send source]];
    $Send MessageText=$MessageText;
} on-error={
    :log warning "tg_send not available - skipping notification";
}

# Creates a binary backup (.backup) and a config export (.rsc), then sends a
# Telegram notification with the resulting filename. Requires the `tg_send`
# script in /system script.
#
# The filename carries the identity, the date and the installed RouterOS
# version, so a directory listing answers "which config, from when, on what
# version" without opening anything. With RemovePrevious left on, only the
# newest pair survives each run.

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

# Retention: after a successful save, delete every older backup-* file.
#
# Name-based rather than time-based, because the two files just written are
# known by name and everything else matching the prefix is older by
# definition. That matters: RouterOS script has no sort, so picking "the
# previous one" out of creation-time stamps means a hand-rolled pairwise
# scan to do what an exact-name exclusion does exactly.
#
# It leaves exactly one generation on the router, which is the point on a hEX
# or a hAP where flash is measured in tens of megabytes. It also means a
# corrupt backup is the only backup, so this is retention on the router, not a
# backup policy - pull the files off the device (pull_router_backups.sh) and
# keep generations there. Set the global to false to keep every generation and
# let backup_file_cleanup.lua age them out at 30 days instead.
:local RemovePrevious true;
:global BACKUP_REMOVE_PREVIOUS;
:if ([:typeof $BACKUP_REMOVE_PREVIOUS] = "bool") do={ :set RemovePrevious $BACKUP_REMOVE_PREVIOUS; }

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

# Only ever reached when the save above succeeded - the on-error handler ends
# in :error, so a failed backup never gets this far and never deletes the
# previous one. That ordering is the whole safety property here.
:local Removed 0;
:if ($RemovePrevious) do={
    :foreach f in=[/file find where name~"^backup-"] do={
        :do {
            :local nm [/file get $f name];
            :if (($nm != ($Filename . ".backup")) and ($nm != ($Filename . ".rsc"))) do={
                /file remove $f;
                :log info ("backup: removed previous $nm");
                :set Removed ($Removed + 1);
            }
        } on-error={
            :log warning "backup: could not remove a previous backup file";
        }
    }
}

:local RemovedLine "";
:if ($Removed > 0) do={
    :set RemovedLine ("%0A<b>Removed:</b> <code>" . $Removed . " older file(s)</code>");
}

:local MessageText ("\F0\9F\92\BE <b>$DeviceName:</b> backup created.%0A<b>File:</b> <code>$Filename</code>%0A<b>Version:</b> <code>$Ver</code>" . $RemovedLine);
:do {
    :local Send [:parse [/system script get tg_send source]];
    $Send MessageText=$MessageText;
} on-error={
    :log warning "tg_send not available - skipping notification";
}

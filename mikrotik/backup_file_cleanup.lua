# Removes backup export files older than RetentionDays from /file. Matches names
# prefixed with "backup-" (same pattern as backup.lua). Run weekly or after
# backup jobs so flash does not fill with stale .backup / .rsc pairs.
#
# Tune RetentionDays below. Does not send Telegram — check /log print.

:local RetentionDays 30;
:local cutoff ([/system clock get date] - 30d);

:log info ("backup_file_cleanup: removing backup-* files older than " . $RetentionDays . " days");

:local removed 0;

:foreach f in=[/file find where name~"backup-"] do={
    :do {
        :local ct [/file get $f creation-time];
        :if ($ct < $cutoff) do={
            :local nm [/file get $f name];
            :log info ("backup_file_cleanup: removing " . $nm . " (created " . $ct . ")");
            /file remove $f;
            :set removed ($removed + 1);
        }
    } on-error={
        :log warning "backup_file_cleanup: error processing a file entry";
    }
}

:if ($removed > 0) do={
    :log info ("backup_file_cleanup: removed " . $removed . " old backup file(s)");
} else={
    :log info "backup_file_cleanup: nothing to remove";
}

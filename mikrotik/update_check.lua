# Checks for RouterOS updates on the configured channel and sends a Telegram
# notification if a newer version is available. Does NOT install automatically.

:local DeviceName [/system identity get name];

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
    :local MessageText ("\F0\9F\9A\80 <b>" . $DeviceName . ":</b> RouterOS update available.%0A" . \
                        "<b>Installed:</b> <code>" . $installed . "</code>%0A" . \
                        "<b>Latest:</b> <code>" . $latest . "</code>%0A" . \
                        "<b>Status:</b> <code>" . $status . "</code>");
    :log info ("update_check: $installed -> $latest");
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={};
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

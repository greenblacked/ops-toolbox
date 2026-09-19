# Forces RouterOS to re-run WAN/LAN detection on every interface.
# Useful after ISP outages where the "internet" tag stays stuck on `unknown`.

:local DeviceName [/system identity get name];

:log info "detect-internet: clearing detect-interface-list";
/interface detect-internet set detect-interface-list=none;
:delay 2s;

:log info "detect-internet: re-enabling detection on all interfaces";
/interface detect-internet set detect-interface-list=all;

:do {
    :local MessageText "\F0\9F\94\8E <b>$DeviceName:</b> WAN detection refreshed.";
    :local Send [:parse [/system script get tg_send source]];
    $Send MessageText=$MessageText;
} on-error={
    :log warning "detect_internet: could not send notification (is tg_send installed?)";
};

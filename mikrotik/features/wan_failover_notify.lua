# Polls the WAN interface's built-in detect-internet state and notifies via
# Telegram only when it transitions (e.g. internet -> no-link, lan -> internet).
#
# Prerequisite: detect-internet must be enabled for this interface, e.g.
#     /interface detect-internet set detect-interface-list=all
# (see detect_internet.lua to toggle this).
#
# Schedule via /system scheduler with interval=1m.
#
# State is held in :global WAN_LAST_STATE so consecutive runs stay quiet while
# the WAN remains in the same state. The global is reset on reboot, which means
# the first run after boot sends a baseline notification - that is intentional.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName   [/system identity get name];
:local WanInterface "ether1";

:global WAN_LAST_STATE;

:local nowKey "";
:do {
    :set nowKey [/interface get [find name=$WanInterface] detect-internet-state];
} on-error={
    :log warning ("wan_failover: detect-internet-state unavailable for " . $WanInterface . \
                  " - is detect-internet enabled and is the interface name correct?");
    :return "";
}

:if ([:len $nowKey] = 0) do={
    :log warning "wan_failover: empty state - skipping";
    :return "";
}

:if ($nowKey = $WAN_LAST_STATE) do={
    :return "";
}

:local emoji "\F0\9F\94\B4";
:if ($nowKey = "internet") do={ :set emoji "\F0\9F\9F\A2"; }

:local prevDisplay $WAN_LAST_STATE;
:if ([:len $prevDisplay] = 0) do={ :set prevDisplay "unknown"; }

:local MessageText ("\F0\9F\8C\90 <b>" . $DeviceName . ":</b> WAN " . $emoji . \
                    "%0A<b>Iface:</b> <code>" . $WanInterface . "</code>" . \
                    "%0A<b>State:</b> <code>" . $prevDisplay . " -> " . $nowKey . "</code>");

:log warning ("wan_failover: " . $WanInterface . " state " . $prevDisplay . " -> " . $nowKey);
:do {
    :local Send [:parse [/system script get tg_send source]];
    $Send MessageText=$MessageText;
} on-error={
    :log error "wan_failover: tg_send unavailable";
}

:set WAN_LAST_STATE $nowKey;

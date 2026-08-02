# Telegram alert when the WAN interface link goes up or down (L1 / running),
# complementary to wan_failover_notify.lua which tracks detect-internet-state.
#
# Set WanInterface to your primary WAN (e.g. ether1 or pppoe-out1). Schedule
# with interval=1m. First run records baseline without messaging.

:local DeviceName   [/system identity get name];
:local WanInterface "ether1";

:global WAN_LINK_LAST;

:local running true;
:do {
    :set running [/interface get [find name=$WanInterface] running];
} on-error={
    :log warning ("wan_link_flap: interface " . $WanInterface . " not found");
    :return "";
}

:local nowLabel "up";
:if ($running = false) do={ :set nowLabel "down"; }

:if ([:len $WAN_LINK_LAST] = 0) do={
    :set WAN_LINK_LAST $nowLabel;
    :log info ("wan_link_flap: baseline " . $WanInterface . " = " . $nowLabel);
    :return "";
}

:if ($WAN_LINK_LAST = $nowLabel) do={
    :return "";
}

:local emoji "\F0\9F\94\B4";
:if ($nowLabel = "up") do={ :set emoji "\F0\9F\9F\A2"; }

:local MessageText ("\F0\9F\94\8C <b>" . $DeviceName . ":</b> WAN link " . $emoji . \
                    "%0A<b>Iface:</b> <code>" . $WanInterface . "</code>" . \
                    "%0A<b>Link:</b> <code>" . $WAN_LINK_LAST . " -> " . $nowLabel . "</code>");

:log warning ("wan_link_flap: " . $WanInterface . " " . $WAN_LINK_LAST . " -> " . $nowLabel);
:do {
    :local Send [:parse [/system script get tg_send source]];
    $Send MessageText=$MessageText;
} on-error={
    :log error "wan_link_flap: tg_send unavailable";
}

:set WAN_LINK_LAST $nowLabel;

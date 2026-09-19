# WireGuard health: Telegram when the tunnel is down or a peer handshake looks
# stale. Set Iface (e.g. wireguard1) and StaleSec. Uses :global WGHEALTHLAST
# ("ok", "down", "stale") to alert only on transitions; first unhealthy baseline
# sends one message.
#
# Schedule every 1–5m. last-handshake is elapsed time since the last successful
# handshake (MikroTik docs); empty means never. Compare that duration to the
# stale threshold — do not subtract from wall-clock time.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];
:local Iface "wireguard1";
# Handshake stale threshold (elapsed seconds). Tune StaleSec and the comparison.
:local StaleSec 300;

:global WGHEALTHLAST;

:local st "ok";

:if ([:len [/interface find name=$Iface]] = 0) do={
    :log info ("wireguard_watch: interface " . $Iface . " not found — skipping");
    :return "";
}

:local running true;
:do {
    :set running [/interface get [find name=$Iface] running];
} on-error={
    :log warning "wireguard_watch: could not read interface running";
    :return "";
}

:if ($running = false) do={
    :set st "down";
} else={
    :foreach p in=[/interface wireguard peers find where interface=$Iface and !disabled] do={
        :do {
            :local lh [/interface wireguard peers get $p last-handshake];
            :if ([:len $lh] = 0) do={
                :set st "stale";
            } else={
                :if ($lh > ($StaleSec * 1s)) do={
                    :set st "stale";
                }
            }
        } on-error={
            :log warning "wireguard_watch: handshake check skipped for a peer";
        }
    }
}

:if ([:len $WGHEALTHLAST] = 0) do={
    :set WGHEALTHLAST $st;
    :if ($st != "ok") do={
        :local MessageText ("\F0\9F\94\90 <b>" . $DeviceName . ":</b> WireGuard <code>" . $Iface . "</code> initial: <code>" . $st . "</code>");
        :do {
            :local Send [:parse [/system script get tg_send source]];
            $Send MessageText=$MessageText;
        } on-error={
            :log error "wireguard_watch: tg_send unavailable";
        }
    }
    :return "";
}

:if ($st = $WGHEALTHLAST) do={
    :return "";
}

:local emoji "\F0\9F\9F\A2";
:if ($st = "down") do={ :set emoji "\F0\9F\94\B4"; }
:if ($st = "stale") do={ :set emoji "\E2\8F\B1"; }

:local MessageText ($emoji . " <b>" . $DeviceName . ":</b> WireGuard <code>" . $Iface . "</code>%0A<b>State:</b> <code>" . $WGHEALTHLAST . " -> " . $st . "</code>");

:log warning ("wireguard_watch: " . $Iface . " " . $WGHEALTHLAST . " -> " . $st);
:do {
    :local Send [:parse [/system script get tg_send source]];
    $Send MessageText=$MessageText;
} on-error={
    :log error "wireguard_watch: tg_send unavailable";
}

:set WGHEALTHLAST $st;

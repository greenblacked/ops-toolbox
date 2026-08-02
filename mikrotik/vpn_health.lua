# VPN tunnel health monitor - checks IPSec, OVPN, and WireGuard tunnel states
# and alerts on transitions (up -> down and down -> up).
# Schedule via /system scheduler with interval=2m.
#
# Globals:
#   VPN_LAST_STATE   ";tunnel=state;..." signature from the previous run.
#                    Alerts only when a tunnel's state changes.
#
# Each check is best-effort and skipped silently when the package / path is
# absent (e.g. no IPSec package installed).

:local DeviceName [/system identity get name];

:global VPN_LAST_STATE;
:if ([:typeof $VPN_LAST_STATE] != "str") do={ :set VPN_LAST_STATE ""; }

:local currentSig "";
:local alerts "";

# --- IPSec active peers ---
:do {
    :local peers [/ip ipsec active-peers find];
    :local peerIds ";";
    :foreach pid in=$peers do={
        :local ph2 0;
        :do { :set ph2 [/ip ipsec active-peers get $pid ph2-total]; } on-error={};
        :local remote "";
        :do { :set remote [/ip ipsec active-peers get $pid remote-address]; } on-error={};
        :local state "up";
        :if ($ph2 = 0) do={ :set state "no-sa"; }
        :set currentSig ($currentSig . ";ipsec-" . $remote . "=" . $state);
    }
    # Also check configured peers to find ones with no active session.
    :foreach pid in=[/ip ipsec peer find] do={
        :local addr "";
        :do { :set addr [/ip ipsec peer get $pid address]; } on-error={};
        :local slash [:find $addr "/"];
        :if ($slash != nil) do={ :set addr [:pick $addr 0 $slash]; }
        :local key ("ipsec-" . $addr);
        :if ([:find $currentSig $key] = nil) do={
            :set currentSig ($currentSig . ";" . $key . "=down");
        }
    }
} on-error={};

# --- OVPN clients ---
:do {
    :foreach oid in=[/interface ovpn-client find] do={
        :local name "";
        :do { :set name [/interface ovpn-client get $oid name]; } on-error={};
        :local running false;
        :do { :set running [/interface ovpn-client get $oid running]; } on-error={};
        :local state "down";
        :if ($running) do={ :set state "up"; }
        :set currentSig ($currentSig . ";ovpn-" . $name . "=" . $state);
    }
} on-error={};

# --- WireGuard peers (RouterOS 7.x) ---
:do {
    :foreach wid in=[/interface wireguard peers find] do={
        :local iface "";
        :do { :set iface [/interface wireguard peers get $wid interface]; } on-error={};
        :local pub "";
        :do { :set pub [/interface wireguard peers get $wid public-key]; } on-error={};
        # Shorten key to 8 chars for readability.
        :if ([:len $pub] > 8) do={ :set pub [:pick $pub 0 8]; }
        :local lastHs "";
        :do { :set lastHs [/interface wireguard peers get $wid last-handshake]; } on-error={};
        :local state "down";
        :if ([:len $lastHs] > 0) do={ :set state "up"; }
        :set currentSig ($currentSig . ";wg-" . $iface . "-" . $pub . "=" . $state);
    }
} on-error={};

:if ([:len $currentSig] = 0) do={
    :log info "vpn_health: no VPN tunnels configured";
    :return "";
}

# Diff current vs previous signature.
:if ($currentSig != $VPN_LAST_STATE) do={
    # Find tunnels whose state changed.
    :local prev $VPN_LAST_STATE;
    :local cur  $currentSig;

    # Walk each segment in current sig and compare to previous.
    :local rest ($cur . ";END");
    :local segStart [:find $rest ";"];
    :while ($segStart != nil) do={
        :local afterSemi ($segStart + 1);
        :local segEnd [:find $rest ";" ($afterSemi + 1)];
        :if ($segEnd != nil) do={
            :local seg [:pick $rest $afterSemi $segEnd];
            :if ($seg != "END") do={
                :local eqIdx [:find $seg "="];
                :if ($eqIdx != nil) do={
                    :local tunnel [:pick $seg 0 $eqIdx];
                    :local state  [:pick $seg ($eqIdx + 1) [:len $seg]];
                    # Look for this tunnel in previous sig.
                    :local prevKey (";" . $tunnel . "=");
                    :local prevStart [:find $prev $prevKey];
                    :local prevState "";
                    :if ($prevStart != nil) do={
                        :local vsStart ($prevStart + [:len $prevKey]);
                        :local vsEnd   [:find $prev ";" ($vsStart + 1)];
                        :if ($vsEnd != nil) do={
                            :set prevState [:pick $prev $vsStart $vsEnd];
                        }
                    }
                    :if ($state != $prevState) do={
                        :local emoji "\F0\9F\94\B4";
                        :if ($state = "up") do={ :set emoji "\F0\9F\9F\A2"; }
                        :set alerts ($alerts . "%0A  " . $emoji . " <code>" . $tunnel . \
                                     "</code>: " . $prevState . " -> " . $state);
                    }
                }
            }
            :set rest [:pick $rest $segEnd [:len $rest]];
            :set segStart [:find $rest ";"];
        } else={
            :set segStart nil;
        }
    }

    :if ([:len $alerts] > 0) do={
        :local MessageText ("\F0\9F\94\92 <b>" . $DeviceName . ":</b> VPN state change" . $alerts);
        :log warning ("vpn_health: state change detected -" . $alerts);
        :do {
            :local Send [:parse [/system script get tg_send source]];
            $Send MessageText=$MessageText;
        } on-error={ :log error "vpn_health: tg_send unavailable"; }
    }

    :set VPN_LAST_STATE $currentSig;
} else={
    :log info ("vpn_health: all tunnels unchanged");
}

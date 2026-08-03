# Wireless client watch - alerts when a new device associates to any WiFi
# interface (both legacy /interface wireless and WiFiWave2 /interface wifi).
# Complements dhcp_lease_watch: catches devices that associate without
# requesting a DHCP lease or before the lease is granted.
# Schedule via /system scheduler with interval=1m.
#
# Globals:
#   WIFI_KNOWN_MACS  ";mac;mac;..." - MACs seen since last boot.
#                    First run after boot silently baselines the current clients.

:local DeviceName  [/system identity get name];

# Set to true to use the WiFiWave2 stack (/interface wifi).
# Set to false for legacy /interface wireless.
:local UseWifiWave2 false;

:global WIFI_KNOWN_MACS;

:local firstRun false;
:if ([:typeof $WIFI_KNOWN_MACS] != "str") do={
    :set WIFI_KNOWN_MACS ";";
    :set firstRun true;
}

:local newMacs "";
:local newCount 0;
:local newMacsToAppend ";";

:if (!$UseWifiWave2) do={
    # Legacy wireless registration table.
    :do {
        :foreach rid in=[/interface wireless registration-table find] do={
            :local mac "";
            :do { :set mac [/interface wireless registration-table get $rid mac-address]; } on-error={};
            :local iface "";
            :do { :set iface [/interface wireless registration-table get $rid interface]; } on-error={};
            :local signal 0;
            :do { :set signal [/interface wireless registration-table get $rid signal-strength]; } on-error={};
            :if ([:len $mac] > 0) do={
                :if ([:find $WIFI_KNOWN_MACS (";" . $mac . ";")] = nil) do={
                    :if ([:find $newMacsToAppend (";" . $mac . ";")] = nil) do={
                        :set newMacsToAppend ($newMacsToAppend . $mac . ";");
                        :set newCount ($newCount + 1);
                        :set newMacs ($newMacs . "%0A  <code>" . $mac . \
                                      "</code>  iface=" . $iface . " rssi=" . $signal . "dBm");
                    }
                }
            }
        }
    } on-error={
        :log warning "wireless_client_watch: /interface wireless not available";
    }
} else={
    # WiFiWave2 registration table.
    :do {
        :foreach rid in=[/interface wifi registration-table find] do={
            :local mac "";
            :do { :set mac [/interface wifi registration-table get $rid mac-address]; } on-error={};
            :local iface "";
            :do { :set iface [/interface wifi registration-table get $rid interface]; } on-error={};
            :local signal 0;
            :do { :set signal [/interface wifi registration-table get $rid signal-strength]; } on-error={};
            :if ([:len $mac] > 0) do={
                :if ([:find $WIFI_KNOWN_MACS (";" . $mac . ";")] = nil) do={
                    :if ([:find $newMacsToAppend (";" . $mac . ";")] = nil) do={
                        :set newMacsToAppend ($newMacsToAppend . $mac . ";");
                        :set newCount ($newCount + 1);
                        :set newMacs ($newMacs . "%0A  <code>" . $mac . \
                                      "</code>  iface=" . $iface . " rssi=" . $signal . "dBm");
                    }
                }
            }
        }
    } on-error={
        :log warning "wireless_client_watch: /interface wifi not available";
    }
}

# Update known MACs.
:if ($newCount > 0) do={
    :set WIFI_KNOWN_MACS ($WIFI_KNOWN_MACS . [:pick $newMacsToAppend 1 [:len $newMacsToAppend]]);
    # Cap to avoid unbounded growth on long-lived routers.
    :if ([:len $WIFI_KNOWN_MACS] > 16384) do={
        :set WIFI_KNOWN_MACS (";" . [:pick $WIFI_KNOWN_MACS 8192 [:len $WIFI_KNOWN_MACS]]);
    }
}

:if (!$firstRun and ($newCount > 0)) do={
    :local MessageText ("\F0\9F\93\B6 <b>" . $DeviceName . ":</b> new WiFi client(s)" . $newMacs);
    :log warning ("wireless_client_watch: " . $newCount . " new MAC(s) associated");
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={ :log error "wireless_client_watch: tg_send unavailable"; }
} else={
    :if ($firstRun) do={
        :log info ("wireless_client_watch: baseline established (" . $newCount . " clients)");
    }
}

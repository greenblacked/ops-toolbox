# Dynamic DNS updater - detects WAN IP changes and pushes the new IP to a
# Cloudflare DNS record via the Cloudflare API v4.
# Schedule via /system scheduler with interval=5m.
#
# Required configuration (set below or via :global on boot):
#   CF_API_TOKEN    Cloudflare API token with Zone:DNS:Edit permission
#   CF_ZONE_ID      Zone ID from the Cloudflare dashboard overview tab
#   CF_RECORD_ID    DNS record ID (get with: curl -H "Authorization: Bearer TOKEN"
#                   "https://api.cloudflare.com/client/v4/zones/ZONE/dns_records")
#   CF_RECORD_NAME  FQDN to update, e.g. "home.example.com"
#
# Globals:
#   DDNS_LAST_IP    last IP pushed to Cloudflare; skips the update when unchanged.

:local DeviceName  [/system identity get name];
:local WanInterface "ether1";

:local CfApiToken  "";
:local CfZoneId    "";
:local CfRecordId  "";
:local CfRecordName "";
:local CfTtl       60;

:global CF_API_TOKEN;
:global CF_ZONE_ID;
:global CF_RECORD_ID;
:global CF_RECORD_NAME;
:global DDNS_LAST_IP;

:if ([:len $CF_API_TOKEN]   > 0) do={ :set CfApiToken   $CF_API_TOKEN;   }
:if ([:len $CF_ZONE_ID]     > 0) do={ :set CfZoneId     $CF_ZONE_ID;     }
:if ([:len $CF_RECORD_ID]   > 0) do={ :set CfRecordId   $CF_RECORD_ID;   }
:if ([:len $CF_RECORD_NAME] > 0) do={ :set CfRecordName $CF_RECORD_NAME; }

:if ([:typeof $DDNS_LAST_IP] != "str") do={ :set DDNS_LAST_IP ""; }

:if (([:len $CfApiToken] = 0) or ([:len $CfZoneId] = 0) or \
     ([:len $CfRecordId] = 0) or ([:len $CfRecordName] = 0)) do={
    :log error "ddns_update: CF_API_TOKEN / CF_ZONE_ID / CF_RECORD_ID / CF_RECORD_NAME not set";
    :return "";
}

# Resolve current WAN IP from the interface address (strips the prefix length).
:local wanIp "";
:do {
    :local addr [/ip address get [find interface=$WanInterface !dynamic] address];
    :local slash [:find $addr "/"];
    :if ($slash != nil) do={ :set wanIp [:pick $addr 0 $slash]; } else={ :set wanIp $addr; }
} on-error={
    :log warning ("ddns_update: could not read address from " . $WanInterface);
    :return "";
}

:if ([:len $wanIp] = 0) do={
    :log warning "ddns_update: WAN IP is empty - skipping";
    :return "";
}

:if ($wanIp = $DDNS_LAST_IP) do={
    :return "";
}

# PATCH the A record via Cloudflare API v4.
:local apiUrl ("https://api.cloudflare.com/client/v4/zones/" . $CfZoneId . \
               "/dns_records/" . $CfRecordId);
:local body ("{\"type\":\"A\",\"name\":\"" . $CfRecordName . \
             "\",\"content\":\"" . $wanIp . "\",\"ttl\":" . $CfTtl . "}");

:local ok false;
:local attempt 0;
:while (($attempt < 3) and (!$ok)) do={
    :do {
        /tool fetch http-method=put url=$apiUrl \
            http-header-field=("Authorization: Bearer " . $CfApiToken . \
                               ",Content-Type: application/json") \
            http-data=$body keep-result=no;
        :set ok true;
    } on-error={
        :set attempt ($attempt + 1);
        :log warning ("ddns_update: attempt " . $attempt . " failed, retrying...");
        :delay 3s;
    }
}

:if ($ok) do={
    :local prev $DDNS_LAST_IP;
    :if ([:len $prev] = 0) do={ :set prev "unknown"; }
    :set DDNS_LAST_IP $wanIp;
    :log info ("ddns_update: updated " . $CfRecordName . " " . $prev . " -> " . $wanIp);
    :local MessageText ("\F0\9F\8C\8D <b>" . $DeviceName . ":</b> DDNS updated" . \
                        "%0A<b>Host:</b> <code>" . $CfRecordName . "</code>" . \
                        "%0A<b>IP:</b> <code>" . $prev . " -> " . $wanIp . "</code>");
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={ :log error "ddns_update: tg_send unavailable"; }
} else={
    :log error ("ddns_update: failed to push " . $wanIp . " to Cloudflare after 3 attempts");
}

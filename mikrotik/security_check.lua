# Read-only security posture scan. Walks the management plane (services,
# discovery, DNS, SNMP, UPnP, SOCKS, firewall input, IPv6 filter) and sends
# a Telegram report of what it found, with the command that would close each
# finding. Changes no router config; the only write is :global SecLastFp so
# the next run can say whether the posture moved.
#
# This is the RouterOS counterpart of linux/hardening_audit.sh and
# macos-initial-setup/hardening_audit.sh: report, never apply. A script that
# auto-hardened would be wrong often enough to be dangerous (a bastion that
# *should* listen on 0.0.0.0, a lab CHR with API on for the test suite).
#
# Schedule via /system scheduler with interval=1d at 05:20:00.
#
# No :local or :global here carries an underscore in its name. RouterOS 7.24
# refuses to execute a script that declares one, from the scheduler, from
# :parse and from /system script run alike. The rest of this folder mostly
# cannot run on 7.24; this one can, and the CHR suite executes it.
#
# Globals:
#   SecLastFp   signature of the last finding set. Empty on first run after
#               boot (globals die with the uptime), which is reported as an
#               initial scan rather than as a flood of "new" findings.
#   SecSendError why the Telegram report did not go out, or empty when it did.
#               A scan nobody receives is worse than no scan, because it looks
#               like a clean result; this is the value to alert on.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];

:local findings "";
:local fp "";
:local crit 0;
:local high 0;
:local med 0;

# --- IP services -----------------------------------------------------------
# Empty address (or 0.0.0.0/0) means the service is reachable on every IP the
# router has, including the WAN. A LAN-only address list is the closed state.
:do {
    :foreach sid in=[/ip service find] do={
        :local sn [/ip service get $sid name];
        :local sd [/ip service get $sid disabled];
        :local sa "";
        :do { :set sa [/ip service get $sid address]; } on-error={};
        :local openAddr false;
        :if (([:len $sa] = 0) or ($sa = "0.0.0.0/0")) do={ :set openAddr true; }
        :if ($sd != true) do={
            :if ($sn = "telnet") do={
                :set findings ($findings . "%0A\\F0\\9F\\94\\B4 telnet is enabled%0A  <code>/ip service disable telnet</code>");
                :set fp ($fp . "telnet;");
                :set crit ($crit + 1);
            }
            :if ($sn = "ftp") do={
                :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 ftp is enabled%0A  <code>/ip service disable ftp</code>");
                :set fp ($fp . "ftp;");
                :set high ($high + 1);
            }
            :if ($sn = "www") do={
                :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 www (HTTP) is enabled%0A  <code>/ip service disable www</code>");
                :set fp ($fp . "www;");
                :set high ($high + 1);
            }
            :if ($sn = "api") do={
                :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 unencrypted API is enabled%0A  <code>/ip service disable api</code>");
                :set fp ($fp . "api;");
                :set high ($high + 1);
            }
            :if (($sn = "winbox") and $openAddr) do={
                :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 winbox is reachable on all addresses%0A  <code>/ip service set winbox address=192.168.88.0/24</code>");
                :set fp ($fp . "winboxAll;");
                :set high ($high + 1);
            }
            :if (($sn = "ssh") and $openAddr) do={
                :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 ssh is reachable on all addresses%0A  <code>/ip service set ssh address=192.168.88.0/24</code>");
                :set fp ($fp . "sshAll;");
                :set med ($med + 1);
            }
            :if (($sn = "www-ssl") and $openAddr) do={
                :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 www-ssl is reachable on all addresses%0A  <code>/ip service set www-ssl address=192.168.88.0/24</code>");
                :set fp ($fp . "wwwsslAll;");
                :set med ($med + 1);
            }
            :if (($sn = "api-ssl") and $openAddr) do={
                :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 api-ssl is reachable on all addresses%0A  <code>/ip service set api-ssl address=192.168.88.0/24</code>");
                :set fp ($fp . "apisslAll;");
                :set med ($med + 1);
            }
        }
    }
} on-error={
    :log warning "security_check: could not enumerate /ip service";
}

# --- identity / users ------------------------------------------------------
:if ($DeviceName = "MikroTik") do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 identity is still the default MikroTik%0A  <code>/system identity set name=router1</code>");
    :set fp ($fp . "ident;");
    :set med ($med + 1);
}

:do {
    :if ([:len [/user find name=admin]] > 0) do={
        :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 user admin still exists%0A  <code>/user add name=you group=full; /user remove admin</code>");
        :set fp ($fp . "admin;");
        :set high ($high + 1);
    }
} on-error={}

# --- discovery / MAC server ------------------------------------------------
# "all" and "dynamic" leak neighbor info and MAC-Telnet onto the WAN. A
# LAN-only interface list is the closed state; any other name is left alone.
:local discList "";
:do { :set discList [/ip neighbor discovery-settings get discover-interface-list]; } on-error={};
:if (($discList = "all") or ($discList = "dynamic")) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 neighbor discovery is on " . $discList . " interfaces%0A  <code>/ip neighbor discovery-settings set discover-interface-list=LAN</code>");
    :set fp ($fp . "neigh;");
    :set high ($high + 1);
}

:local macList "";
:do { :set macList [/tool mac-server get allowed-interface-list]; } on-error={};
:if (($macList = "all") or ($macList = "dynamic")) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 MAC server is allowed on " . $macList . " interfaces%0A  <code>/tool mac-server set allowed-interface-list=LAN</code>");
    :set fp ($fp . "macsrv;");
    :set high ($high + 1);
}

:local macWbList "";
:do { :set macWbList [/tool mac-server mac-winbox get allowed-interface-list]; } on-error={};
:if (($macWbList = "all") or ($macWbList = "dynamic")) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 MAC Winbox is allowed on " . $macWbList . " interfaces%0A  <code>/tool mac-server mac-winbox set allowed-interface-list=LAN</code>");
    :set fp ($fp . "macwinbox;");
    :set high ($high + 1);
}

# --- historically abused extras --------------------------------------------
:local bwOn false;
:do { :set bwOn [/tool bandwidth-server get enabled]; } on-error={};
:if ($bwOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 bandwidth-server is enabled%0A  <code>/tool bandwidth-server set enabled=no</code>");
    :set fp ($fp . "bwserver;");
    :set high ($high + 1);
}

:local socksOn false;
:do { :set socksOn [/ip socks get enabled]; } on-error={};
:if ($socksOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\94\\B4 SOCKS proxy is enabled%0A  <code>/ip socks set enabled=no</code>");
    :set fp ($fp . "socks;");
    :set crit ($crit + 1);
}

:local upnpOn false;
:do { :set upnpOn [/ip upnp get enabled]; } on-error={};
:if ($upnpOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 UPnP is enabled%0A  <code>/ip upnp set enabled=no</code>");
    :set fp ($fp . "upnp;");
    :set high ($high + 1);
}

:local dnsOpen false;
:do { :set dnsOpen [/ip dns get allow-remote-requests]; } on-error={};
:if ($dnsOpen = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\94\\B4 DNS allow-remote-requests is on%0A  <code>/ip dns set allow-remote-requests=no</code>");
    :set fp ($fp . "dnsopen;");
    :set crit ($crit + 1);
}

:local snmpOn false;
:do { :set snmpOn [/snmp get enabled]; } on-error={};
:if ($snmpOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 SNMP is enabled%0A  <code>/snmp set enabled=no</code>");
    :set fp ($fp . "snmp;");
    :set high ($high + 1);
}
:do {
    :if ([:len [/snmp community find name=public]] > 0) do={
        :set findings ($findings . "%0A\\F0\\9F\\94\\B4 SNMP community public exists%0A  <code>/snmp community remove [find name=public]</code>");
        :set fp ($fp . "snmpPublic;");
        :set crit ($crit + 1);
    }
} on-error={}

:local romonOn false;
:do { :set romonOn [/tool romon get enabled]; } on-error={};
:if ($romonOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 RoMON is enabled%0A  <code>/tool romon set enabled=no</code>");
    :set fp ($fp . "romon;");
    :set med ($med + 1);
}

:local pptpOn false;
:do { :set pptpOn [/interface pptp-server server get enabled]; } on-error={};
:if ($pptpOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 PPTP server is enabled%0A  <code>/interface pptp-server server set enabled=no</code>");
    :set fp ($fp . "pptp;");
    :set high ($high + 1);
}

:local proxyOn false;
:do { :set proxyOn [/ip proxy get enabled]; } on-error={};
:if ($proxyOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 HTTP proxy is enabled%0A  <code>/ip proxy set enabled=no</code>");
    :set fp ($fp . "proxy;");
    :set high ($high + 1);
}

:local smbOn false;
:do { :set smbOn [/ip smb get enabled]; } on-error={};
:if ($smbOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 SMB is enabled%0A  <code>/ip smb set enabled=no</code>");
    :set fp ($fp . "smb;");
    :set high ($high + 1);
}

:local cloudOn false;
:do { :set cloudOn [/ip cloud get ddns-enabled]; } on-error={};
:if ($cloudOn = true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 IP cloud DDNS is enabled%0A  <code>/ip cloud set ddns-enabled=no</code>");
    :set fp ($fp . "cloud;");
    :set med ($med + 1);
}

:local ntpOn false;
:do { :set ntpOn [/system ntp client get enabled]; } on-error={};
:if ($ntpOn != true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 NTP client is not enabled%0A  <code>/system ntp client set enabled=yes</code>");
    :set fp ($fp . "ntp;");
    :set med ($med + 1);
}

# --- firewall --------------------------------------------------------------
# An input chain with no drop/reject is how a service you forgot about stays
# reachable. Missing established,related is a warning, not a failure: some
# routers accept by interface instead.
:local hasInputDrop false;
:local hasEstRel false;
:do {
    :foreach rid in=[/ip firewall filter find chain=input] do={
        :local act [/ip firewall filter get $rid action];
        :if (($act = "drop") or ($act = "reject")) do={ :set hasInputDrop true; }
        :local cs "";
        :do { :set cs [/ip firewall filter get $rid connection-state]; } on-error={};
        :if (($act = "accept") and ([:find $cs "established"] != nil)) do={
            :set hasEstRel true;
        }
    }
} on-error={}
:if ($hasInputDrop != true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 filter input has no drop/reject%0A  <code>/ip firewall filter add chain=input action=drop</code>");
    :set fp ($fp . "noInputDrop;");
    :set high ($high + 1);
}
:if ($hasEstRel != true) do={
    :set findings ($findings . "%0A\\F0\\9F\\9F\\A1 filter input has no established,related accept%0A  <code>/ip firewall filter add chain=input action=accept connection-state=established,related</code>");
    :set fp ($fp . "noEstRel;");
    :set med ($med + 1);
}

:local v6off false;
:do { :set v6off [/ipv6 settings get disable-ipv6]; } on-error={};
:if ($v6off != true) do={
    :local v6rules 0;
    :do { :set v6rules [:len [/ipv6 firewall filter find]]; } on-error={};
    :if ($v6rules = 0) do={
        :set findings ($findings . "%0A\\F0\\9F\\9F\\A0 IPv6 is enabled with no filter rules%0A  <code>/ipv6 firewall filter add chain=input action=drop</code>");
        :set fp ($fp . "v6empty;");
        :set high ($high + 1);
    }
}

# --- notify ----------------------------------------------------------------
:global SecLastFp;
:local prev "";
:if ([:typeof $SecLastFp] = "str") do={ :set prev $SecLastFp; }

:local posture "unchanged";
:if ([:len $prev] = 0) do={ :set posture "initial scan"; }
:if (($prev != "") and ($prev != $fp)) do={ :set posture "posture changed"; }

:local total ($crit + $high + $med);
:local counts ("" . $crit . " critical, " . $high . " high, " . $med . " medium");
:local MessageText "";
:if ($total = 0) do={
    :set MessageText ("\\F0\\9F\\9B\\A1\\EF\\B8\\8F <b>" . $DeviceName . ":</b> security scan clean%0A" . $posture);
} else={
    :set MessageText ("\\F0\\9F\\9B\\A1\\EF\\B8\\8F <b>" . $DeviceName . ":</b> security scan%0A" . \
                      $counts . " (" . $posture . ")" . $findings);
}

:log info ("security_check: " . $counts . " posture=" . $posture);

# The send mirrors backup_update_check.lua, the one Telegram path this
# repository proves end to end on a 7.24 CHR: the helper's name resolves
# through a variable, it is parsed once, and the parsed function is called with
# MessageText. The parse and the call are separate :do blocks on purpose. One
# block around both could only say "tg_send unavailable", which is the same
# sentence whether the script is missing, refuses to parse, or raises while
# sending - and an audit that goes quiet for an unknown reason is the failure
# mode this script exists to prevent. SecSendError names which half failed, and
# survives the run so a scheduler or a test can read it.
:local TgSendScript "tg_send";
:local SendTelegramMessage "";
:local SendError "";
:do {
    :set SendTelegramMessage [:parse [/system script get $TgSendScript source]];
} on-error={
    :set SendError ("cannot read or parse script '" . $TgSendScript . "'");
}
:if ([:len $SendError] = 0) do={
    :do {
        $SendTelegramMessage MessageText=$MessageText;
    } on-error={
        :set SendError ("'" . $TgSendScript . "' raised while sending the report");
    }
}
:global SecSendError;
:set SecSendError $SendError;
:if ([:len $SendError] > 0) do={
    :log error ("security_check: report NOT sent - " . $SendError);
}

:set SecLastFp $fp;

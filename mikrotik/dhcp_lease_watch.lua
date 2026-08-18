# DHCP lease watch - alerts on new MAC addresses, duplicate hostnames, and
# lease churn. Schedule via /system scheduler with interval=5m.
#
# Globals (kept across scheduler runs within an uptime session):
#   DHCP_KNOWN_MACS         delimited string of MACs already reported.
#   DHCP_PREV_LEASE_COUNT   lease count from the previous run (churn baseline).
#   DHCP_CHURN_FLAG         true while a churn alert is active (suppresses repeats).
#   DHCP_DUPS_FLAG          true while a duplicate-hostname alert is active.
#
# On the first run after boot, DHCP_KNOWN_MACS is empty - the script silently
# captures the current set of leases as the baseline and does NOT alert.
# Subsequent runs report deltas only.
#
# Action mode:
#   When Enforce is true, new MACs are also added to address-list dhcp-watch-new
#   with a timeout. This is purely informational and does NOT block traffic on
#   its own; pair with a documented filter rule (see mikrotik/README.md).

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];

:local Enforce        true;
:local ChurnThreshold 10;
:local ListName       "dhcp-watch-new";
:local ListTimeout    "1d";

:global DHCP_KNOWN_MACS;
:global DHCP_PREV_LEASE_COUNT;
:global DHCP_CHURN_FLAG;
:global DHCP_DUPS_FLAG;

:local firstRun false;
:if ([:typeof $DHCP_KNOWN_MACS] != "str") do={
    :set DHCP_KNOWN_MACS ";";
    :set firstRun true;
}
:if ([:typeof $DHCP_PREV_LEASE_COUNT] != "num") do={ :set DHCP_PREV_LEASE_COUNT 0; }
:if ([:typeof $DHCP_CHURN_FLAG] != "bool") do={ :set DHCP_CHURN_FLAG false; }
:if ([:typeof $DHCP_DUPS_FLAG] != "bool") do={ :set DHCP_DUPS_FLAG false; }

# Pass 1: enumerate leases, classify against DHCP_KNOWN_MACS, build a hostname
# accumulator string ";HOST@MAC;..." that pass 2 will scan for duplicates.
:local newMacInfo "";
:local newMacCount 0;
:local newMacsToAppend ";";
:local hostnameAccum ";";
:local leaseCount 0;

:do {
    :foreach lid in=[/ip dhcp-server lease find] do={
        :local mac [/ip dhcp-server lease get $lid mac-address];
        :local addr [/ip dhcp-server lease get $lid address];
        :local host "";
        :do { :set host [/ip dhcp-server lease get $lid host-name]; } on-error={};
        :set leaseCount ($leaseCount + 1);

        :local hostShown $host;
        :if ([:len $hostShown] = 0) do={ :set hostShown "?"; }

        :if ([:find $DHCP_KNOWN_MACS (";" . $mac . ";")] = nil) do={
            :if ([:find $newMacsToAppend (";" . $mac . ";")] = nil) do={
                :set newMacsToAppend ($newMacsToAppend . $mac . ";");
                :set newMacCount ($newMacCount + 1);
                :set newMacInfo ($newMacInfo . "%0A  <code>" . $mac . "</code>  ip=" . $addr . " host=" . $hostShown);
                :if ($Enforce and (!$firstRun)) do={
                    :do {
                        /ip firewall address-list add list=$ListName address=$addr timeout=$ListTimeout \
                            comment=("dhcp-watch new mac=" . $mac);
                    } on-error={
                        :log warning ("dhcp_lease_watch: address-list add failed for " . $addr);
                    }
                }
            }
        }

        :if ([:len $host] > 0) do={
            :set hostnameAccum ($hostnameAccum . $host . "@" . $mac . ";");
        }
    }
} on-error={
    :log error "dhcp_lease_watch: failed to iterate leases";
    :return "";
}

# Pass 2: detect hostnames that appear with more than one MAC.
:local dupSummary "";
:local dupCount 0;
:local checkedHosts ";";
:do {
    :foreach lid in=[/ip dhcp-server lease find] do={
        :local h "";
        :do { :set h [/ip dhcp-server lease get $lid host-name]; } on-error={};
        :if ([:len $h] > 0) do={
            :if ([:find $checkedHosts (";" . $h . ";")] = nil) do={
                :set checkedHosts ($checkedHosts . $h . ";");
                :local hostKey (";" . $h . "@");
                :local count 0;
                :local rest $hostnameAccum;
                :local idx [:find $rest $hostKey];
                :while ($idx != nil) do={
                    :set count ($count + 1);
                    :set rest [:pick $rest ($idx + [:len $hostKey]) [:len $rest]];
                    :set idx [:find $rest $hostKey];
                }
                :if ($count > 1) do={
                    :set dupCount ($dupCount + 1);
                    :set dupSummary ($dupSummary . "%0A  <code>" . $h . "</code> (" . $count . " entries)");
                }
            }
        }
    }
} on-error={};

# Churn relative to the previous run's lease count.
:local delta ($leaseCount - $DHCP_PREV_LEASE_COUNT);
:local absDelta $delta;
:if ($absDelta < 0) do={ :set absDelta (- $absDelta); }
:local churn false;
:if (($absDelta > $ChurnThreshold) and (!$firstRun)) do={ :set churn true; }

:local body "";
:if ($newMacCount > 0) do={
    :set body ($body . "%0A<b>New MACs (" . $newMacCount . "):</b>" . $newMacInfo);
}
:if ($dupCount > 0) do={
    :set body ($body . "%0A<b>Duplicate hostnames (" . $dupCount . "):</b>" . $dupSummary);
}
:if ($churn) do={
    :set body ($body . "%0A<b>Lease churn:</b> " . $DHCP_PREV_LEASE_COUNT . " -> " . $leaseCount . " (delta " . $delta . ")");
}

:local shouldAlert false;
:if (!$firstRun) do={
    :if ($newMacCount > 0) do={ :set shouldAlert true; }
    :if (($dupCount > 0) and (!$DHCP_DUPS_FLAG)) do={ :set shouldAlert true; }
    :if ($churn and (!$DHCP_CHURN_FLAG)) do={ :set shouldAlert true; }
}

:if ($shouldAlert) do={
    :local MessageText ("\F0\9F\93\A1 <b>" . $DeviceName . ":</b> DHCP lease watch alert" . $body);
    :log warning ("dhcp_lease_watch: alert newMACs=" . $newMacCount . " dupHosts=" . $dupCount . " churnDelta=" . $delta);
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={ :log error "dhcp_lease_watch: tg_send unavailable"; }
}

# Sticky flags so churn / dup-hostname conditions don't re-alert every run while
# the underlying problem persists. They clear automatically when the condition
# resolves, which on its own is logged but not telegrammed.
:if ($dupCount > 0) do={
    :set DHCP_DUPS_FLAG true;
} else={
    :if ($DHCP_DUPS_FLAG) do={ :log info "dhcp_lease_watch: duplicate-hostname condition cleared"; }
    :set DHCP_DUPS_FLAG false;
}
:if ($churn) do={
    :set DHCP_CHURN_FLAG true;
} else={
    :if ($DHCP_CHURN_FLAG) do={ :log info "dhcp_lease_watch: churn condition cleared"; }
    :set DHCP_CHURN_FLAG false;
}

# Append-only update of DHCP_KNOWN_MACS. Cap total length so a long-lived router
# with thousands of distinct devices doesn't grow the global without bound.
# On firstRun, every observed MAC is in newMacsToAppend already, so we just adopt
# it as the new baseline.
:if ($firstRun) do={
    :set DHCP_KNOWN_MACS $newMacsToAppend;
    :log info ("dhcp_lease_watch: baseline established (" . $leaseCount . " leases)");
} else={
    :if ([:len $newMacsToAppend] > 1) do={
        :set DHCP_KNOWN_MACS ($DHCP_KNOWN_MACS . [:pick $newMacsToAppend 1 [:len $newMacsToAppend]]);
    }
    :if ([:len $DHCP_KNOWN_MACS] > 16384) do={
        :set DHCP_KNOWN_MACS (";" . [:pick $DHCP_KNOWN_MACS 8192 [:len $DHCP_KNOWN_MACS]]);
    }
}

:set DHCP_PREV_LEASE_COUNT $leaseCount;

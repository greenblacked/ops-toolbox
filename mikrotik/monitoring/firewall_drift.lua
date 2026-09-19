# Firewall drift detector. Snapshots /ip firewall filter and /ip firewall nat
# rule signatures into :global FW_BASELINE and alerts via Telegram when later
# runs see additions, removals, or order changes. Schedule via /system
# scheduler with interval=15m.
#
# Globals:
#   FW_BASELINE   delimited string of rule signatures from the last accepted state.
#
# A rule signature is "filter|chain|action|src-address|dst-port|protocol|comment"
# (and similarly "nat|...") joined with the marker "%%RULE%%". The leading table
# prefix means the same logical rule moved between filter and nat shows up as both
# an add and a remove, which is intentional.
#
# Order changes are NOT diffed by default - signature equality is set-based. To
# catch reordering of a critical rule, give it a comment containing "#critical"
# and the script flags it when its position relative to other critical rules
# changes between baseline and current.
#
# Action mode:
#   On drift, the script adds a marker entry to address-list fw-drift-events
#   (address 127.0.0.1, with a descriptive comment + timeout). The address-list
#   serves as a router-side audit trail; remove the entries after acknowledging.
#
# Re-baseline after intentional changes by running firewall_drift_baseline.lua.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];

:local MarkerListName "fw-drift-events";
:local MarkerListTtl  "1h";
:local Sep            "%%RULE%%";
:local SepLen         8;

:global FW_BASELINE;

:local buildSig do={
    :local out "";
    :local critOrder "";
    :foreach rid in=[/ip firewall filter find] do={
        :local chain  [/ip firewall filter get $rid chain];
        :local action [/ip firewall filter get $rid action];
        :local proto "";
        :do { :set proto [/ip firewall filter get $rid protocol]; } on-error={};
        :local src "";
        :do { :set src [/ip firewall filter get $rid src-address]; } on-error={};
        :local dport "";
        :do { :set dport [/ip firewall filter get $rid dst-port]; } on-error={};
        :local cmt "";
        :do { :set cmt [/ip firewall filter get $rid comment]; } on-error={};
        :set out ($out . "filter|" . $chain . "|" . $action . "|" . $src . "|" . $dport . "|" . $proto . "|" . $cmt . "%%RULE%%");
        :if ([:find $cmt "#critical"] != nil) do={
            :set critOrder ($critOrder . $cmt . "%%CRIT%%");
        }
    }
    :foreach rid in=[/ip firewall nat find] do={
        :local chain  [/ip firewall nat get $rid chain];
        :local action [/ip firewall nat get $rid action];
        :local proto "";
        :do { :set proto [/ip firewall nat get $rid protocol]; } on-error={};
        :local src "";
        :do { :set src [/ip firewall nat get $rid src-address]; } on-error={};
        :local dport "";
        :do { :set dport [/ip firewall nat get $rid dst-port]; } on-error={};
        :local cmt "";
        :do { :set cmt [/ip firewall nat get $rid comment]; } on-error={};
        :set out ($out . "nat|" . $chain . "|" . $action . "|" . $src . "|" . $dport . "|" . $proto . "|" . $cmt . "%%RULE%%");
    }
    :return ($out . "%%CRITORDER%%" . $critOrder);
}

:local current "";
:do {
    :set current [$buildSig];
} on-error={
    :log error "firewall_drift: failed to enumerate firewall rules";
    :return "";
}

:local firstRun false;
:if (([:typeof $FW_BASELINE] != "str") or ([:len $FW_BASELINE] = 0)) do={
    :set firstRun true;
}

:if ($firstRun) do={
    :set FW_BASELINE $current;
    :log info "firewall_drift: baseline established";
    :return "";
}

:if ($current = $FW_BASELINE) do={
    :return "";
}

# Split each side on %%CRITORDER%% to separate the rule set from the critical-
# rule order signature.
:local splitCrit "%%CRITORDER%%";
:local splitCritLen 13;

:local curSet $current;
:local curCrit "";
:local sIdx [:find $current $splitCrit];
:if ($sIdx != nil) do={
    :set curSet [:pick $current 0 $sIdx];
    :set curCrit [:pick $current ($sIdx + $splitCritLen) [:len $current]];
}

:local baseSet $FW_BASELINE;
:local baseCrit "";
:set sIdx [:find $FW_BASELINE $splitCrit];
:if ($sIdx != nil) do={
    :set baseSet [:pick $FW_BASELINE 0 $sIdx];
    :set baseCrit [:pick $FW_BASELINE ($sIdx + $splitCritLen) [:len $FW_BASELINE]];
}

:local added "";
:local addedCount 0;
:local removed "";
:local removedCount 0;

:local rest $curSet;
:while ([:len $rest] > 0) do={
    :local idx [:find $rest $Sep];
    :if ($idx = nil) do={ :set rest ""; } else={
        :local sig [:pick $rest 0 ($idx + $SepLen)];
        :local body [:pick $rest 0 $idx];
        :if ([:find $baseSet $sig] = nil) do={
            :set added ($added . "%0A  + <code>" . $body . "</code>");
            :set addedCount ($addedCount + 1);
        }
        :set rest [:pick $rest ($idx + $SepLen) [:len $rest]];
    }
}

:set rest $baseSet;
:while ([:len $rest] > 0) do={
    :local idx [:find $rest $Sep];
    :if ($idx = nil) do={ :set rest ""; } else={
        :local sig [:pick $rest 0 ($idx + $SepLen)];
        :local body [:pick $rest 0 $idx];
        :if ([:find $curSet $sig] = nil) do={
            :set removed ($removed . "%0A  - <code>" . $body . "</code>");
            :set removedCount ($removedCount + 1);
        }
        :set rest [:pick $rest ($idx + $SepLen) [:len $rest]];
    }
}

:local critReorder false;
:if (($curCrit != $baseCrit) and ([:len $curCrit] > 0) and ([:len $baseCrit] > 0)) do={
    :set critReorder true;
}

:local body "";
:if ($addedCount > 0) do={ :set body ($body . "%0A<b>Added (" . $addedCount . "):</b>" . $added); }
:if ($removedCount > 0) do={ :set body ($body . "%0A<b>Removed (" . $removedCount . "):</b>" . $removed); }
:if ($critReorder) do={ :set body ($body . "%0A<b>Critical-rule order changed.</b>"); }

:if ([:len $body] > 0) do={
    :local MessageText ("\F0\9F\9B\A1\EF\B8\8F <b>" . $DeviceName . ":</b> firewall drift detected" . $body);
    :log warning ("firewall_drift: drift added=" . $addedCount . " removed=" . $removedCount . " critReorder=" . $critReorder);

    :do {
        /ip firewall address-list add list=$MarkerListName address=127.0.0.1 timeout=$MarkerListTtl \
            comment=("fw-drift +" . $addedCount . " -" . $removedCount . " critReorder=" . $critReorder);
    } on-error={};

    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={ :log error "firewall_drift: tg_send unavailable"; }
}

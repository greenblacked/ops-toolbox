# Latency monitor - pings a list of targets and alerts on packet loss or high RTT.
# Schedule via /system scheduler with interval=5m.
#
# Globals:
#   LATENCY_LAST_FLAG   signature of last alert; suppresses repeats while
#                       the same set of targets stays degraded.
#
# Tune Targets, LossThreshold (%), and RttThreshold (ms) below.

:local DeviceName [/system identity get name];

:local Targets       {"8.8.8.8";"1.1.1.1";"9.9.9.9"};
:local Count         5;
:local LossThreshold 40;
:local RttThreshold  150;

:global LATENCY_LAST_FLAG;
:if ([:typeof $LATENCY_LAST_FLAG] != "str") do={ :set LATENCY_LAST_FLAG ""; }

:local alerts "";
:local alertSig ";";

:foreach target in=$Targets do={
    :local sent     0;
    :local received 0;
    :local rttSum   0;
    :local rttMin   99999;
    :local rttMax   0;

    :local i 0;
    :while ($i < $Count) do={
        :local rtt 0;
        :local ok false;
        :do {
            :set rtt [/ping address=$target count=1 as-value];
            :set ok true;
        } on-error={};

        :set sent ($sent + 1);
        :if ($ok) do={
            :local r 0;
            :do { :set r ($rtt->"avg-rtt"); } on-error={};
            :set received ($received + 1);
            :set rttSum ($rttSum + $r);
            :if ($r < $rttMin) do={ :set rttMin $r; }
            :if ($r > $rttMax) do={ :set rttMax $r; }
        }
        :set i ($i + 1);
    }

    :local loss 0;
    :if ($sent > 0) do={
        :set loss (($sent - $received) * 100 / $sent);
    }
    :local rttAvg 0;
    :if ($received > 0) do={
        :set rttAvg ($rttSum / $received);
    }

    :local bad false;
    :if ($loss >= $LossThreshold) do={ :set bad true; }
    :if (($received > 0) and ($rttAvg > $RttThreshold)) do={ :set bad true; }

    :if ($bad) do={
        :local line ("%0A  <code>" . $target . "</code>  loss=" . $loss . \
                     "%  rtt=" . $rttAvg . "ms  (min=" . $rttMin . " max=" . $rttMax . ")");
        :set alerts ($alerts . $line);
        :set alertSig ($alertSig . $target . "=" . $loss . "%;");
    }
}

:if ([:len $alerts] > 0) do={
    :if ($alertSig != $LATENCY_LAST_FLAG) do={
        :local MessageText ("\F0\9F\93\A1 <b>" . $DeviceName . ":</b> latency alert" . $alerts);
        :log warning ("latency_monitor: degraded targets - " . $alertSig);
        :do {
            :local Send [:parse [/system script get tg_send source]];
            $Send MessageText=$MessageText;
        } on-error={ :log error "latency_monitor: tg_send unavailable"; }
        :set LATENCY_LAST_FLAG $alertSig;
    }
} else={
    :if ([:len $LATENCY_LAST_FLAG] > 0) do={
        :log info "latency_monitor: all targets OK - cleared";
        :set LATENCY_LAST_FLAG "";
    }
}

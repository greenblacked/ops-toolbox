# Monthly traffic quota tracker - accumulates WAN RX+TX across reboots and
# alerts when usage crosses configured thresholds.
# Schedule via /system scheduler with interval=1h.
#
# The script stores a running total in :global so it survives scheduler runs
# within one uptime session. To persist across reboots it writes a tiny file
# /quota-state.txt containing "MONTH RX TX" and reads it back on the first
# run after boot.
#
# Globals:
#   QUOTA_MONTH      current month string (YYYY-MM); resets accumulators on change.
#   QUOTA_RX         accumulated RX bytes this month.
#   QUOTA_TX         accumulated TX bytes this month.
#   QUOTA_PREV_RX    raw interface RX counter from the previous run.
#   QUOTA_PREV_TX    raw interface TX counter from the previous run.
#   QUOTA_ALERTED    ";80;100;" - which thresholds have already been notified.

:local DeviceName   [/system identity get name];
:local WanInterface "ether1";

# Monthly quota in GB. Set 0 to disable alerting (still tracks / logs).
:local QuotaGB 1000;

# Alert at these percentages of QuotaGB.
:local AlertPcts {80; 95; 100};

:local StateFile "/quota-state.txt";

:global QUOTA_MONTH;
:global QUOTA_RX;
:global QUOTA_TX;
:global QUOTA_PREV_RX;
:global QUOTA_PREV_TX;
:global QUOTA_ALERTED;

:local firstRun false;
:if ([:typeof $QUOTA_MONTH] != "str") do={ :set firstRun true; }
:if ([:typeof $QUOTA_RX]       != "num") do={ :set QUOTA_RX 0; }
:if ([:typeof $QUOTA_TX]       != "num") do={ :set QUOTA_TX 0; }
:if ([:typeof $QUOTA_PREV_RX]  != "num") do={ :set QUOTA_PREV_RX 0; }
:if ([:typeof $QUOTA_PREV_TX]  != "num") do={ :set QUOTA_PREV_TX 0; }
:if ([:typeof $QUOTA_ALERTED]  != "str") do={ :set QUOTA_ALERTED ";"; }

# Read current month as YYYY-MM using /system clock.
:local now [/system clock get date];
:local nowYear  [:pick $now 7 11];
:local nowMonth [:pick $now 0 3];
:local monthStr ($nowYear . "-" . $nowMonth);

# On first run after boot, try to restore accumulators from the state file.
:if ($firstRun) do={
    :do {
        :local content [/file get [find name=$StateFile] contents];
        # Format: "YYYY-MMM RX TX ALERTED"
        :local sp1 [:find $content " "];
        :if ($sp1 != nil) do={
            :local savedMonth [:pick $content 0 $sp1];
            :local rest [:pick $content ($sp1 + 1) [:len $content]];
            :local sp2 [:find $rest " "];
            :if ($sp2 != nil) do={
                :local savedRx [:tonum [:pick $rest 0 $sp2]];
                :local rest2 [:pick $rest ($sp2 + 1) [:len $rest]];
                :local sp3 [:find $rest2 " "];
                :local savedTx 0;
                :local savedAlerted ";";
                :if ($sp3 != nil) do={
                    :set savedTx [:tonum [:pick $rest2 0 $sp3]];
                    :set savedAlerted [:pick $rest2 ($sp3 + 1) [:len $rest2]];
                } else={
                    :set savedTx [:tonum $rest2];
                }
                :if ($savedMonth = $monthStr) do={
                    :set QUOTA_RX $savedRx;
                    :set QUOTA_TX $savedTx;
                    :set QUOTA_ALERTED $savedAlerted;
                    :log info ("traffic_quota: restored from file - month=" . $savedMonth . \
                               " rx=" . ($savedRx / 1073741824) . "GB tx=" . ($savedTx / 1073741824) . "GB");
                }
            }
        }
    } on-error={
        :log info "traffic_quota: no state file found, starting fresh";
    }
    :set QUOTA_MONTH $monthStr;
}

# Reset accumulators on month rollover.
:if ($monthStr != $QUOTA_MONTH) do={
    :log info ("traffic_quota: month changed " . $QUOTA_MONTH . " -> " . $monthStr . "; resetting");
    :set QUOTA_RX 0;
    :set QUOTA_TX 0;
    :set QUOTA_PREV_RX 0;
    :set QUOTA_PREV_TX 0;
    :set QUOTA_ALERTED ";";
    :set QUOTA_MONTH $monthStr;
}

# Read current interface counters.
:local rawRx 0;
:local rawTx 0;
:do {
    :set rawRx [/interface get [find name=$WanInterface] rx-byte];
    :set rawTx [/interface get [find name=$WanInterface] tx-byte];
} on-error={
    :log error ("traffic_quota: interface not found: " . $WanInterface);
    :return "";
}

# Accumulate delta (skip negative deltas from counter resets on reboot).
:local deltaRx ($rawRx - $QUOTA_PREV_RX);
:local deltaTx ($rawTx - $QUOTA_PREV_TX);
:if ($deltaRx > 0) do={ :set QUOTA_RX ($QUOTA_RX + $deltaRx); }
:if ($deltaTx > 0) do={ :set QUOTA_TX ($QUOTA_TX + $deltaTx); }
:set QUOTA_PREV_RX $rawRx;
:set QUOTA_PREV_TX $rawTx;

:local totalBytes ($QUOTA_RX + $QUOTA_TX);
:local rxGB ($QUOTA_RX / 1073741824);
:local txGB ($QUOTA_TX / 1073741824);
:local totalGB ($totalBytes / 1073741824);

:log info ("traffic_quota: " . $monthStr . " rx=" . $rxGB . "GB tx=" . $txGB . "GB total=" . $totalGB . "GB");

# Write state file so the next boot can restore the accumulator.
:do {
    :local stateContent ($monthStr . " " . $QUOTA_RX . " " . $QUOTA_TX . " " . $QUOTA_ALERTED);
    :do { /file remove [find name=$StateFile]; } on-error={};
    /tool fetch url=("file:" . $StateFile) http-method=put \
        http-data=$stateContent keep-result=no;
} on-error={
    # Fallback: just log; loss of persistence is non-fatal.
    :log warning "traffic_quota: could not write state file";
}

# Check thresholds and alert.
:if ($QuotaGB > 0) do={
    :local quotaBytes ($QuotaGB * 1073741824);
    :foreach pct in=$AlertPcts do={
        :local threshold ($quotaBytes * $pct / 100);
        :local pctKey (";" . $pct . ";");
        :if (($totalBytes >= $threshold) and ([:find $QUOTA_ALERTED $pctKey] = nil)) do={
            :set QUOTA_ALERTED ($QUOTA_ALERTED . $pct . ";");
            :local MessageText ("\F0\9F\93\B6 <b>" . $DeviceName . ":</b> traffic quota " . \
                                $pct . "% reached" . \
                                "%0A<b>Month:</b> " . $monthStr . \
                                "%0A<b>Used:</b> " . $totalGB . " GB / " . $QuotaGB . " GB" . \
                                "%0A<b>RX:</b> " . $rxGB . " GB  <b>TX:</b> " . $txGB . " GB");
            :log warning ("traffic_quota: " . $pct . "% threshold reached - " . $totalGB . "GB used");
            :do {
                :local Send [:parse [/system script get tg_send source]];
                $Send MessageText=$MessageText;
            } on-error={ :log error "traffic_quota: tg_send unavailable"; }
        }
    }
}

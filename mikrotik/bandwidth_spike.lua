# Bandwidth spike monitor - alerts when per-interface traffic in the last
# interval exceeds a configured threshold.
# Schedule via /system scheduler with interval=5m.
#
# The script samples cumulative TX/RX byte counters and computes a delta.
# Counter resets (reboot, interface flap) are detected and skipped silently.
#
# Globals:
#   BW_PREV_RX   ";iface=bytes;..." - previous RX counters per interface.
#   BW_PREV_TX   ";iface=bytes;..." - previous TX counters per interface.
#   BW_LAST_FLAG signature of last alert; suppresses repeats.
#
# Tune Interfaces and ThresholdMB below.

:local DeviceName  [/system identity get name];

# Interfaces to monitor. Leave empty to monitor all ethernet/vlan interfaces.
:local Interfaces  {"ether1";"ether2"};

# Alert when TX or RX in one interval exceeds this many MB.
:local ThresholdMB 200;

:global BW_PREV_RX;
:global BW_PREV_TX;
:global BW_LAST_FLAG;

:if ([:typeof $BW_PREV_RX]   != "str") do={ :set BW_PREV_RX ";"; }
:if ([:typeof $BW_PREV_TX]   != "str") do={ :set BW_PREV_TX ";"; }
:if ([:typeof $BW_LAST_FLAG] != "str") do={ :set BW_LAST_FLAG ""; }

:local ThresholdBytes ($ThresholdMB * 1048576);

:local alerts "";
:local alertSig ";";
:local newRx ";";
:local newTx ";";

:foreach iface in=$Interfaces do={
    :local rx 0;
    :local tx 0;
    :do {
        :set rx [/interface get [find name=$iface] rx-byte];
        :set tx [/interface get [find name=$iface] tx-byte];
    } on-error={
        :log warning ("bandwidth_spike: interface not found: " . $iface);
    }

    :set newRx ($newRx . $iface . "=" . $rx . ";");
    :set newTx ($newTx . $iface . "=" . $tx . ";");

    # Look up previous value.
    :local keyStart [:find $BW_PREV_RX (";" . $iface . "=")];
    :if ($keyStart != nil) do={
        :local valStart ($keyStart + [:len $iface] + 2);
        :local valEnd   [:find $BW_PREV_RX ";" ($valStart + 1)];
        :if ($valEnd != nil) do={
            :local prevRx [:tonum [:pick $BW_PREV_RX $valStart $valEnd]];

            :local keyStartTx [:find $BW_PREV_TX (";" . $iface . "=")];
            :local valStartTx ($keyStartTx + [:len $iface] + 2);
            :local valEndTx   [:find $BW_PREV_TX ";" ($valStartTx + 1)];
            :local prevTx [:tonum [:pick $BW_PREV_TX $valStartTx $valEndTx]];

            :local deltaRx ($rx - $prevRx);
            :local deltaTx ($tx - $prevTx);

            # Skip if counters reset (reboot / flap).
            :if (($deltaRx >= 0) and ($deltaTx >= 0)) do={
                :local rxMB ($deltaRx / 1048576);
                :local txMB ($deltaTx / 1048576);
                :if (($deltaRx > $ThresholdBytes) or ($deltaTx > $ThresholdBytes)) do={
                    :set alerts ($alerts . "%0A  <code>" . $iface . \
                                 "</code>  rx=" . $rxMB . "MB  tx=" . $txMB . "MB");
                    :set alertSig ($alertSig . $iface . "r=" . $rxMB . "t=" . $txMB . ";");
                }
            }
        }
    }
}

:set BW_PREV_RX $newRx;
:set BW_PREV_TX $newTx;

:if ([:len $alerts] > 0) do={
    :if ($alertSig != $BW_LAST_FLAG) do={
        :local MessageText ("\F0\9F\93\88 <b>" . $DeviceName . ":</b> bandwidth spike" . $alerts);
        :log warning ("bandwidth_spike: threshold exceeded -" . $alerts);
        :do {
            :local Send [:parse [/system script get tg_send source]];
            $Send MessageText=$MessageText;
        } on-error={ :log error "bandwidth_spike: tg_send unavailable"; }
        :set BW_LAST_FLAG $alertSig;
    }
} else={
    :if ([:len $BW_LAST_FLAG] > 0) do={
        :log info "bandwidth_spike: all interfaces within threshold - cleared";
        :set BW_LAST_FLAG "";
    }
}

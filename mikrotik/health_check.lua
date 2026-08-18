# Periodic health check - alerts via Telegram on threshold violations.
# Schedule via /system scheduler with interval=5m.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:local DeviceName [/system identity get name];

# Thresholds (percent / celsius). Tune to your hardware.
:local CpuThreshold  85;
:local MemThreshold  85;
:local DiskThreshold 90;
:local TempThreshold 75;

:local cpu  [/system resource get cpu-load];
:local totalMem [/system resource get total-memory];
:local freeMem  [/system resource get free-memory];
:local totalHdd [/system resource get total-hdd-space];
:local freeHdd  [/system resource get free-hdd-space];

:local memUsed (($totalMem - $freeMem) * 100 / $totalMem);
:local hddUsed (($totalHdd - $freeHdd) * 100 / $totalHdd);

# Iterate /system health entries and grab the first temperature-like reading.
# Supported entry names vary by hardware: temperature, cpu-temperature, board-temperature.
:local temp 0;
:do {
    :foreach hi in=[/system health find] do={
        :local hn [/system health get $hi name];
        :if (($hn = "temperature") or ($hn = "cpu-temperature") or ($hn = "board-temperature")) do={
            :set temp [/system health get $hi value];
        }
    }
} on-error={};

:local alerts "";
:if ($cpu > $CpuThreshold) do={
    :set alerts ($alerts . "%0A\E2\9A\A0\EF\B8\8F CPU: " . $cpu . "%");
}
:if ($memUsed > $MemThreshold) do={
    :set alerts ($alerts . "%0A\E2\9A\A0\EF\B8\8F Memory: " . $memUsed . "%");
}
:if ($hddUsed > $DiskThreshold) do={
    :set alerts ($alerts . "%0A\E2\9A\A0\EF\B8\8F Disk: " . $hddUsed . "%");
}
:if (($temp > 0) and ($temp > $TempThreshold)) do={
    :set alerts ($alerts . "%0A\E2\9A\A0\EF\B8\8F Temp: " . $temp . "C");
}

:if ([:len $alerts] > 0) do={
    :local MessageText ("\F0\9F\9A\A8 <b>" . $DeviceName . ":</b> health alert" . $alerts);
    :log warning ("health_check: thresholds exceeded - $alerts");
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={
        :log error "health_check: tg_send unavailable";
    }
} else={
    :log info ("health_check OK: cpu=" . $cpu . "% mem=" . $memUsed . "% hdd=" . $hddUsed . "% temp=" . $temp);
}

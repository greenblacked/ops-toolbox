# Connection-tracking watch: Telegram when the conntrack table nears its maximum, and when it recovers.
#
# A full connection-tracking table is how a router goes up-but-nothing-works:
# a scan, a flood, a torrent client or one leaking device fills it, and new
# connections are dropped while every interface still looks fine. Nothing
# else here watches it; health_check covers CPU, memory, disk and temperature.
#
# Schedule every 5m. Each run reads two numbers the router already keeps,
# total-entries and max-entries under /ip firewall connection tracking, and
# alerts only on a change of state: ok to high when the table is at or above
# the threshold, high to ok when it falls back. The first run after boot
# records a healthy table silently and reports one that is already high.
#
# Optional globals:
#   ConntrackWarnPercent   whole number 0-100, default 80
#   ConntrackSendScript    Telegram helper; default tg_send_new, then tg_send
#
# State:
#   ConntrackLast            ok or high, as of the last run
#   ConntrackDeliveredState  the last state Telegram acknowledged
#   ConntrackSendError       why the last send failed; empty after a good one
#
# Read-only: it writes only its own globals. It never flushes, removes or
# changes a connection or a tracking setting. No :global or :local name here
# has an underscore, so it runs on RouterOS 7.24.

# Fleet-wide maintenance switch; router_doctor.py reports when it is active.
:global OpsToolboxPaused;
:if (([:typeof $OpsToolboxPaused] = "bool") and $OpsToolboxPaused) do={ :return ""; }

:global ConntrackWarnPercent;
:global ConntrackSendScript;
:global ConntrackLast;
:global ConntrackDeliveredState;
:global ConntrackSendError;

:local DeviceName [/system identity get name];

# The threshold. Anything that is not a whole number from 0 to 100 is logged
# and replaced by the default rather than silently turning the alert off.
:local WarnPercent 80;
:if ([:len [:tostr $ConntrackWarnPercent]] > 0) do={
    :local wanted "";
    :do {
        :set wanted [:tonum $ConntrackWarnPercent];
    } on-error={
        :set wanted "";
    }
    :if (([:typeof $wanted] = "num") and ($wanted >= 0) and ($wanted <= 100)) do={
        :set WarnPercent $wanted;
    } else={
        :log warning ("conntrack_watch: ConntrackWarnPercent must be a whole number from 0 to 100 - using " . $WarnPercent);
    }
}

# Tracking switched off has nothing to fill. An unreadable setting is treated
# as on, and the reads below decide.
:local trackingState "";
:do {
    :set trackingState [:tostr [/ip firewall connection tracking get enabled]];
} on-error={
    :set trackingState "";
}
:if (($trackingState = "no") or ($trackingState = "false")) do={
    :log info "conntrack_watch: connection tracking is disabled - nothing to watch";
    :return "";
}

# Fail-safe floor: without a maximum there is no percentage, and dividing by
# zero would end the run with no log line at all.
:local maxEntries 0;
:do {
    :set maxEntries [:tonum [/ip firewall connection tracking get max-entries]];
} on-error={
    :set maxEntries 0;
}
:if (([:typeof $maxEntries] != "num") or ($maxEntries <= 0)) do={
    :log warning "conntrack_watch: max-entries unavailable - skipping";
    :return "";
}

# total-entries is the cheap read. Counting the table is the fallback, and on
# a busy router it is the expensive one, so it only runs when the first fails.
:local totalEntries -1;
:do {
    :set totalEntries [:tonum [/ip firewall connection tracking get total-entries]];
} on-error={
    :set totalEntries -1;
}
:if (([:typeof $totalEntries] != "num") or ($totalEntries < 0)) do={
    :do {
        :set totalEntries [:len [/ip firewall connection find]];
    } on-error={
        :log warning "conntrack_watch: total-entries unavailable - skipping";
        :return "";
    }
}

:local pct ($totalEntries * 100 / $maxEntries);
:local state "ok";
:if ($pct >= $WarnPercent) do={ :set state "high"; }
:set ConntrackLast $state;

# Alert on transitions, measured against what Telegram last acknowledged
# rather than what the previous run saw: a send that failed leaves the two
# apart, so the next run tries again instead of the alert being lost.
:local delivered [:tostr $ConntrackDeliveredState];
:if ([:len $delivered] = 0) do={
    # First run since boot. A healthy table is the baseline, not news.
    :if ($state = "ok") do={
        :set ConntrackDeliveredState "ok";
        :return "";
    }
}
:if ($state = $delivered) do={
    # Back where Telegram last heard it: an earlier failed send is moot.
    :set ConntrackSendError "";
    :return "";
}

# Plain text, and "percent" rather than the sign: a helper that form-encodes
# its body reads a bare percent sign as the start of an escape.
:local figures ([:tostr $pct] . " percent full, " . [:tostr $totalEntries] . " of ");
:set figures ($figures . [:tostr $maxEntries] . " entries, warning at " . [:tostr $WarnPercent] . " percent");
:local MessageText "";
:if ($state = "high") do={
    :set MessageText ($DeviceName . ": connection tracking table " . $figures);
    :log warning ("conntrack_watch: table " . $figures);
} else={
    :set MessageText ($DeviceName . ": connection tracking table recovered, " . $figures);
    :log info ("conntrack_watch: recovered, " . $figures);
}

# The operator's helper first, as backup_update_check, security_check and
# stay_fresh do, then the package's tg_send. A missing helper is a log line,
# never an error that ends the run.
:local helper "tg_send_new";
:if ([:len [:tostr $ConntrackSendScript]] > 0) do={ :set helper $ConntrackSendScript; }
:local Send "";
:local HaveSend false;
:do {
    :set Send [:parse [/system script get $helper source]];
    :set HaveSend true;
} on-error={
    :do {
        :set Send [:parse [/system script get tg_send source]];
        :set HaveSend true;
        :log info ("conntrack_watch: helper '" . $helper . "' not found, using tg_send");
    } on-error={
        :log error ("conntrack_watch: no Telegram helper found ('" . $helper . "' or tg_send) - alert not sent");
    }
}

:set ConntrackSendError "";
:if (!$HaveSend) do={
    :set ConntrackSendError "no Telegram helper; will retry next run";
    :return "";
}
:do {
    :local sent [$Send MessageText=$MessageText MessagePlainText=true];
    :if (([:typeof $sent] = "bool") and (!$sent)) do={
        :error "helper returned false";
    }
    :set ConntrackDeliveredState $state;
} on-error={
    :set ConntrackSendError "helper missing, unparseable, returned false, or raised while sending; will retry next run";
    :log error ("conntrack_watch: " . $ConntrackSendError);
}

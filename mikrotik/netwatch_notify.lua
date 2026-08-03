# Summarize /tool netwatch host status and Telegram when the snapshot changes.
# First run records baseline without messaging. Configure hosts in Tools → Netwatch.
# Schedule every 1–5m.

:local DeviceName [/system identity get name];

:global NETWATCHSNAP;

:local snap "";

:foreach i in=[/tool netwatch find] do={
    :local hst [/tool netwatch get $i host];
    :local st [/tool netwatch get $i status];
    :set snap ($snap . $hst . ":" . $st . "|");
}

:if ([:len $snap] = 0) do={
    :log info "netwatch_notify: no netwatch entries";
    :return "";
}

:if ($snap = $NETWATCHSNAP) do={
    :return "";
}

:if ([:len $NETWATCHSNAP] > 0) do={
    :local MessageText ("\F0\9F\93\A1 <b>" . $DeviceName . ":</b> netwatch change%0A<code>" . $snap . "</code>");
    :log warning ("netwatch_notify: state change -> " . $snap);
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={
        :log error "netwatch_notify: tg_send unavailable";
    }
} else={
    :log info ("netwatch_notify: baseline " . $snap);
}

:set NETWATCHSNAP $snap;

# Alerts when any non-disabled certificate is expired or expires within WarnDays.
# RouterOS date arithmetic is used for the upcoming-expiry window. Schedule at
# most once per day to avoid duplicate Telegram noise.
#
# Tune the expiry window by changing + 30d below (e.g. + 14d).

:local DeviceName [/system identity get name];

:local expMsg "";

:foreach i in=[/certificate find where !disabled] do={
    :local nm [/certificate get $i name];
    :do {
        :if ([/certificate get $i expired] = true) do={
            :set expMsg ($expMsg . "%0A\E2\9D\8C <code>" . $nm . "</code> EXPIRED");
        } else={
            :local ia [/certificate get $i invalid-after];
            :if ([:len $ia] > 0) do={
                :if ($ia <= ([/system clock get date] + 30d)) do={
                    :set expMsg ($expMsg . "%0A\E2\9A\A0 <code>" . $nm . "</code> expires <code>" . \
                                $ia . "</code>");
                }
            }
        }
    } on-error={
        :log warning ("cert_expiry_watch: could not inspect cert " . $nm);
    }
}

:if ([:len $expMsg] > 0) do={
    :local MessageText ("\F0\9F\94\90 <b>" . $DeviceName . ":</b> certificate watch" . $expMsg);
    :log warning ("cert_expiry_watch: issues found - $expMsg");
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={
        :log error "cert_expiry_watch: tg_send unavailable";
    }
} else={
    :log info "cert_expiry_watch: no expired or soon-expiring certs in window";
}

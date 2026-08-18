# Rotates the WPA2 PSK on 2.4GHz and 5GHz security profiles and notifies via Telegram.
# Works on legacy `wireless` package. For RouterOS 7.13+ `wifi` (WiFiWave2),
# set UseWifiWave2 to true and adjust profile names below.

:local ProfileName2  "Mikro-World-2";
:local ProfileName5  "Mikro-World-5";
:local UseWifiWave2  false;
:local DeviceName    [/system identity get name];

# Length of the generated passwords. Increase for stronger keys (8..63 valid for WPA2).
:local Pw2Length 15;
:local Pw5Length 20;

# Generate two random passwords. The certificate-OTP trick produces a printable string;
# fall back to /random if certificate package is missing.
:local genPw do={
    :local out "";
    :do {
        :set out ([:pick ([/certificate scep-server otp generate minutes-valid=0 as-value]->"password") 0 $len]);
    } on-error={
        :local chars "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        :for i from=1 to=$len do={
            :set out ($out . [:pick $chars [:rndnum from=0 to=([:len $chars] - 1)]]);
        }
    }
    :return $out;
}

:local PW2 [$genPw len=$Pw2Length];
:local PW5 [$genPw len=$Pw5Length];

:do {
    :if ($UseWifiWave2) do={
        /interface wifi security set [find name=$ProfileName2] passphrase=$PW2;
        /interface wifi security set [find name=$ProfileName5] passphrase=$PW5;
    } else={
        /interface wireless security-profiles set [find name=$ProfileName2] wpa2-pre-shared-key=$PW2;
        /interface wireless security-profiles set [find name=$ProfileName5] wpa2-pre-shared-key=$PW5;
    }
    :log info ("WiFi passwords rotated on $DeviceName");
} on-error={
    :log error "WiFi password rotation FAILED - check profile names and wifi package";
    :error "wifi rotation failed";
}

:local MessageText "\F0\9F\94\91 <b>$DeviceName:</b> WiFi passwords rotated.%0A<b>$ProfileName2:</b> <code>$PW2</code>%0A<b>$ProfileName5:</b> <code>$PW5</code>";
:do {
    :local Send [:parse [/system script get tg_send_WIFI source]];
    $Send MessageText=$MessageText;
} on-error={
    # Fall back to the generic tg_send if a dedicated WiFi-channel script is missing.
    :do {
        :local Send [:parse [/system script get tg_send source]];
        $Send MessageText=$MessageText;
    } on-error={
        :log warning "Neither tg_send_WIFI nor tg_send found - new password only in log";
    }
}

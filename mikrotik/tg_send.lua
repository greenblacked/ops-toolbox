# Telegram text-message helper. Call with:
#     :local Send [:parse [/system script get tg_send source]];
#     $Send MessageText="...";
#
# Secrets:
#   - Either replace BotToken / ChatID below with real values, or
#   - Define globals once on boot, e.g. in /system scripts script "startup":
#         :global TgBotToken "123:abc";
#         :global TgChatId   "12345";
#     and add a scheduler entry "on event=startup" pointing to that script.
#
# No :global here carries an underscore in its name. RouterOS 7.24 refuses
# to execute a script that declares one, which is why the old TG_BOT_TOKEN /
# TG_CHAT_ID pair is gone.
#
# Migrating: on a router already on 7.24 the old values are not recoverable.
# Globals are runtime state repopulated at boot, and the startup script that
# set them declares an underscored name, so it does not run and
# /system script environment has nothing to copy. Re-enter the token and
# rewrite that startup script to the new names. On 7.23, migrate first - the
# snippet in mikrotik/README.md copies the values for the current uptime, but
# the startup script still has to be edited or the next reboot undoes it.
# router_doctor.py reports "TgBotToken is not set" until that is done.

:local BotToken "token";
:local ChatID   "ID";
:local ParseMode "html";
:local DisableWebPagePreview "true";

:global TgBotToken;
:global TgChatId;
:if ([:len $TgBotToken] > 0) do={ :set BotToken $TgBotToken; }
:if ([:len $TgChatId]   > 0) do={ :set ChatID   $TgChatId;   }

:if ([:len $MessageText] = 0) do={
    :log warning "tg_send: empty MessageText - nothing to send";
    :return "";
}

# Telegram's hard limit is 4096 chars. Truncate to keep the request well below.
:if ([:len $MessageText] > 4000) do={
    :set MessageText ([:pick $MessageText 0 4000] . "...");
}

:local tgUrl "https://api.telegram.org/bot$BotToken/sendMessage";
:local body  ("chat_id=" . $ChatID . \
              "&parse_mode=" . $ParseMode . \
              "&disable_web_page_preview=" . $DisableWebPagePreview . \
              "&text=" . $MessageText);

:local attempt 0;
:local sent false;
:while (($attempt < 3) and (!$sent)) do={
    :do {
        # check-certificate defaults to no on /tool fetch; leaving it off would
        # send the bot token to any MITM that presents a cert.
        /tool fetch http-method=post url=$tgUrl http-data=$body \
            http-header-field="Content-Type: application/x-www-form-urlencoded" \
            check-certificate=yes keep-result=no;
        :set sent true;
    } on-error={
        :set attempt ($attempt + 1);
        :log warning ("tg_send: attempt $attempt failed, retrying...");
        :delay 2s;
    }
}

:if (!$sent) do={
    :log error "tg_send: giving up after 3 attempts";
}

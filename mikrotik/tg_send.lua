# Telegram text-message helper. Call with:
#     :local Send [:parse [/system script get tg_send source]];
#     $Send MessageText="...";
#
# Secrets:
#   - Either replace BotToken / ChatID below with real values, or
#   - Define globals once on boot, e.g. in /system scripts script "startup":
#         :global TG_BOT_TOKEN "123:abc";
#         :global TG_CHAT_ID   "12345";
#     and add a scheduler entry "on event=startup" pointing to that script.

:local BotToken "token";
:local ChatID   "ID";
:local ParseMode "html";
:local DisableWebPagePreview "true";

:global TG_BOT_TOKEN;
:global TG_CHAT_ID;
:if ([:len $TG_BOT_TOKEN] > 0) do={ :set BotToken $TG_BOT_TOKEN; }
:if ([:len $TG_CHAT_ID]   > 0) do={ :set ChatID   $TG_CHAT_ID;   }

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
        /tool fetch http-method=post url=$tgUrl http-data=$body \
            http-header-field="Content-Type: application/x-www-form-urlencoded" \
            keep-result=no;
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

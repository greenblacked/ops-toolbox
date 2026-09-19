# Telegram text-message helper.
#
# Legacy callers can keep passing URL-encoded HTML in MessageText.
# New callers should pass MessagePlainText=true and ordinary text with \n.
#
# Secrets:
#   :global TgBotToken "123:abc";
#   :global TgChatId   "12345";
#
# Success means Telegram returned JSON with ok=true. Failed delivery raises
# after retries, allowing callers to keep their alert pending instead of
# silently advancing a deduplication fingerprint.

:local BotToken "token";
:local ChatID "ID";

:global TgBotToken;
:global TgChatId;

:if ([:len $TgBotToken] > 0) do={ :set BotToken $TgBotToken; }
:if ([:len $TgChatId] > 0) do={ :set ChatID $TgChatId; }

:if (($BotToken = "token") or ($ChatID = "ID")) do={
    :error "tg_send: credentials not configured";
}

:if ([:len $MessageText] = 0) do={
    :error "tg_send: empty message";
}

# Stay below Telegram's 4096-character text limit. New reporting scripts split
# findings before calling this helper; legacy callers should do the same.
:if ([:len $MessageText] > 4000) do={
    :error "tg_send: message exceeds safe length";
}

:local tgUrl ("https://api.telegram.org/bot" . $BotToken . "/sendMessage");
:local contentType "Content-Type: application/x-www-form-urlencoded";
:local body ("chat_id=" . $ChatID .     "&parse_mode=html&disable_web_page_preview=true&text=" . $MessageText);

:if ($MessagePlainText = true) do={
    :local payload {
        "chat_id"=$ChatID;
        "text"=$MessageText;
        "disable_web_page_preview"=true
    };
    :set body [:serialize to=json value=$payload options=json.no-string-conversion];
    :set contentType "Content-Type: application/json";
}

:local attempt 0;
:local sent false;

:while (($attempt < 3) and (!$sent)) do={
    :set attempt ($attempt + 1);

    :do {
        :local result [/tool fetch             http-method=post             url=$tgUrl             http-data=$body             http-header-field=$contentType             check-certificate=yes             duration=20s             output=user             as-value];

        :if (($result->"status") != "finished") do={
            :error "request incomplete";
        }

        :local reply [:deserialize from=json value=($result->"data")];
        :if (($reply->"ok") != true) do={
            :error "Telegram did not acknowledge delivery";
        }

        :set sent true;
    } on-error={
        :log warning ("tg_send: delivery attempt " . $attempt . " failed");
        :if ($attempt < 3) do={ :delay 2s; }
    }
}

:if (!$sent) do={
    :error "tg_send: delivery failed after 3 attempts";
}

:return true;

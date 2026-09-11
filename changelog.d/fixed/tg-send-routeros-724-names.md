- `mikrotik/tg_send.lua` reads `:global TgBotToken` / `TgChatId` instead
  of `TG_BOT_TOKEN` / `TG_CHAT_ID`. RouterOS 7.24 refuses underscore
  names, so the package helper now runs there. Copy the old Environment
  values by hand; 7.24 cannot re-declare the old names even to migrate.

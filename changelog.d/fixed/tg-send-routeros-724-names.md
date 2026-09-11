- `mikrotik/tg_send.lua` reads `:global TgBotToken` / `TgChatId` instead of
  `TG_BOT_TOKEN` / `TG_CHAT_ID`, so it runs on RouterOS 7.24, which refuses to
  execute a script declaring an underscored name. This is a breaking change for
  a router already sending notifications, and the old values are not
  recoverable on 7.24: globals are runtime state repopulated at boot, and the
  startup script that set them cannot run there, so `/system script
  environment` has nothing to copy. Re-enter the token and rewrite the startup
  script. Migrating on 7.23 first is easier, but the snippet alone lasts only
  until the next reboot — the startup script has to change too.
  `router_doctor.py` reports `TgBotToken is not set` until it does. Note the
  scope: `tg_send` now runs on 7.24 for the three scripts that also run there;
  the sixteen other notifying callers still declare underscored globals.

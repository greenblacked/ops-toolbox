- `mikrotik/README.md` told users to set `TG_BOT_TOKEN` / `TG_CHAT_ID`, which
  nothing has read since the RouterOS 7.24 rename, and credited
  `router_doctor.py` with checking those same two names when it checks
  `TgBotToken` / `TgChatId`. Following the requirements table produced a
  router that stays silent. Both now name what the code reads.
- The scripts overview says which of the 27 run on RouterOS 7.24 and which do
  not. Sixteen die in the parser on that release over an underscored `:global`
  or `:local`, logging nothing, so a scheduled script that never runs looks
  exactly like one with nothing to report — and the README offered no way to
  tell the two groups apart. Both lists and the headline count are derived from
  the scripts and compared in `test_lua_conventions.sh`, so a script that
  changes sides fails the suite rather than quietly making the note wrong.
